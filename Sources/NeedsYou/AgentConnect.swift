import AppKit
import Foundation
import NeedsYouShared

/// Settings > Agents > "Reach by voice" (HM-1364): adds the Needs You MCP server
/// to Claude Code and Codex, only when he clicks Connect. Claude Code's own
/// `claude mcp add` writes its config (it owns ~/.claude.json); Codex gets a
/// marked block at the end of ~/.codex/config.toml.
@MainActor
final class AgentConnect: ObservableObject {
    static let shared = AgentConnect()

    enum Agent: String, CaseIterable, Identifiable {
        case claude, codex, cursor, claudeApp
        var id: String { rawValue }
        /// The app whose icon stands for it (nil: a terminal agent).
        var appBundle: String? {
            switch self {
            case .claude: return nil
            case .codex: return "com.openai.codex"
            case .cursor: return "com.todesktop.230313mzl4w4u92"
            case .claudeApp: return Router.desktopBundleID
            }
        }
        var name: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex (also Codex in the ChatGPT app)"
            case .cursor: return "Cursor (agent chat)"
            case .claudeApp: return "Claude app"
            }
        }
    }

    @Published private(set) var connected: [Agent: Bool] = [:]
    @Published private(set) var installed: [Agent: Bool] = [:]
    @Published var lastError: String?

    /// The CLI agents start: the ~/.local/bin link when install.sh made one, else the app's own copy.
    var cli: String {
        let link = NSHomeDirectory() + "/.local/bin/needs-you"
        if FileManager.default.fileExists(atPath: link) { return link }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/needs-you").path
    }

    var codexDir: URL {
        if let d = ProcessInfo.processInfo.environment["NEEDS_YOU_CODEX_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    var codexConfig: URL { codexDir.appendingPathComponent("config.toml") }

    /// ~/.cursor (HM-1374): mcp.json and hooks.json.
    var cursorDir: URL {
        if let d = ProcessInfo.processInfo.environment["NEEDS_YOU_CURSOR_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
    }

    /// The Claude app's MCP config (HM-1385). Its chats answer out loud once it has our server.
    var claudeAppConfig: URL {
        if let d = ProcessInfo.processInfo.environment["NEEDS_YOU_CLAUDE_APP_DIR"], !d.isEmpty { return URL(fileURLWithPath: d).appendingPathComponent("claude_desktop_config.json") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// Set after connecting or disconnecting the Claude app while it runs: it reads its config only at launch.
    @Published var claudeAppNeedsRestart = false

    /// The ChatGPT app on this Mac (com.openai.codex is the ChatGPT app with Codex built in).
    var chatGPTApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat")
    }

    var claudeBinary: String? {
        let home = NSHomeDirectory()
        return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() {
        installed[.claude] = claudeBinary != nil
        installed[.codex] = FileManager.default.fileExists(atPath: codexDir.path)
        connected[.claude] = claudeHasServer()
        connected[.codex] = (try? String(contentsOf: codexConfig, encoding: .utf8)).map(AgentSetup.hasBlock) ?? false
        installed[.cursor] = FileManager.default.fileExists(atPath: cursorDir.path) || FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
        connected[.cursor] = (readJSON(cursorDir.appendingPathComponent("mcp.json"))?["mcpServers"] as? [String: Any])?["needs-you"] != nil
        installed[.claudeApp] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Router.desktopBundleID) != nil
        connected[.claudeApp] = (readJSON(claudeAppConfig)?["mcpServers"] as? [String: Any])?["needs-you"] != nil
    }

    /// Quits the Claude app and opens it again, so it loads the new config.
    func restartClaudeApp() {
        claudeAppNeedsRestart = false
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Router.desktopBundleID).first,
              let url = app.bundleURL else { return }
        app.terminate()
        Task {
            for _ in 0..<100 where !app.isTerminated { try? await Task.sleep(nanoseconds: 100_000_000) }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Reads ~/.claude.json (never writes it).
    private func claudeHasServer() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let d = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return false }
        return servers["needs-you"] != nil
    }

    func set(_ agent: Agent, connected on: Bool) {
        lastError = nil
        guard !Prefs.readOnly else { return }
        do {
            switch agent {
            case .claude:
                guard let claude = claudeBinary else { throw Fail.msg("Claude Code is not installed.") }
                if on {
                    if !claudeHasServer() { try run([claude, "mcp", "add", "--scope", "user", "needs-you", "--", cli, "mcp"]) }
                } else if claudeHasServer() {
                    try run([claude, "mcp", "remove", "--scope", "user", "needs-you"])
                }
                try editHooks(AgentInstructions.targetDir().appendingPathComponent("settings.json"), on: on, agent: "claude", events: HookSetup.claudeEvents)
            case .codex:
                let text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
                let new = on ? AgentSetup.withBlock(text, block: AgentSetup.codexBlock(cli: cli)) : AgentSetup.without(text)
                if new != text {
                    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
                    let backup = codexDir.appendingPathComponent("config.toml.needs-you-backup")
                    if !text.isEmpty && !FileManager.default.fileExists(atPath: backup.path) { try text.write(to: backup, atomically: true, encoding: .utf8) }
                    try new.write(to: codexConfig, atomically: true, encoding: .utf8)
                }
                try editHooks(codexDir.appendingPathComponent("hooks.json"), on: on, agent: "codex", events: HookSetup.codexEvents)
            case .cursor:
                // Cursor's agent chat: our MCP server in mcp.json, our hooks in hooks.json (its flat format).
                try editJSON(cursorDir.appendingPathComponent("mcp.json")) { AgentSetup.cursorMCPEdit($0, cli: cli, on: on) }
                try editJSON(cursorDir.appendingPathComponent("hooks.json")) { on ? HookSetup.installCursor($0, cli: cli) : HookSetup.removeCursor($0) }
            case .claudeApp:
                // The Claude app has no hooks: only our MCP server in claude_desktop_config.json.
                let before = connected[.claudeApp] ?? false
                try editJSON(claudeAppConfig) { HookSetup.mcpServerEdit($0, cli: cli, agent: "claude-app", on: on) }
                if before != on, !NSRunningApplication.runningApplications(withBundleIdentifier: Router.desktopBundleID).isEmpty {
                    claudeAppNeedsRestart = true
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// On launch: Claude Code hooks from another version are brought to this version's events
    /// (added or removed). Only when they are on; nothing else in the file changes.
    func refreshClaudeHooks() {
        guard !Prefs.readOnly else { return }
        let url = AgentInstructions.targetDir().appendingPathComponent("settings.json")
        guard let d = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              HookSetup.isInstalled(root) else { return }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let ours = Set(hooks.keys.filter { e in
            ((hooks[e] as? [[String: Any]]) ?? []).contains { g in
                ((g["hooks"] as? [[String: Any]]) ?? []).contains { HookSetup.isOurs(($0["command"] as? String) ?? "") }
            }
        })
        if ours != Set(HookSetup.claudeEvents) { try? editHooks(url, on: true, agent: "claude", events: HookSetup.claudeEvents) }
    }

    /// Adds or removes Needs You's hook entries; every other hook stays. One backup per file.
    private func editHooks(_ url: URL, on: Bool, agent: String, events: [String]) throws {
        let fm = FileManager.default
        let data = try? Data(contentsOf: url)
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let r = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Fail.msg("\(url.lastPathComponent) is not a JSON object; nothing changed.")
            }
            root = r
        }
        let new = on ? HookSetup.install(root, cli: cli, agent: agent, events: events) : HookSetup.remove(root)
        guard on || HookSetup.isInstalled(root) else { return }
        let out = try JSONSerialization.data(withJSONObject: new, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("needs-you-backup")
        if let data, !fm.fileExists(atPath: backup.path) { try data.write(to: backup) }
        try out.write(to: url, options: .atomic)
    }

    func readJSON(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url), !d.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// Rewrites a JSON object file through `change`; one backup per file, nothing written when nothing changes.
    private func editJSON(_ url: URL, _ change: ([String: Any]) -> [String: Any]) throws {
        let fm = FileManager.default
        let data = try? Data(contentsOf: url)
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let r = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Fail.msg("\(url.lastPathComponent) is not a JSON object; nothing changed.")
            }
            root = r
        }
        let new = change(root)
        if NSDictionary(dictionary: new).isEqual(to: root) { return }
        let out = try JSONSerialization.data(withJSONObject: new, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("needs-you-backup")
        if let data, !fm.fileExists(atPath: backup.path) { try data.write(to: backup) }
        try out.write(to: url, options: .atomic)
    }

    enum Fail: LocalizedError {
        case msg(String)
        var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
    }

    private func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + NSHomeDirectory() + "/.local/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Fail.msg("\(URL(fileURLWithPath: args[0]).lastPathComponent) \(args[1]) failed: \(out.prefix(200))")
        }
    }
}
