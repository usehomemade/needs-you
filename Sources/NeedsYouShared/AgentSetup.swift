import Foundation

/// Text edits that connect an agent to Needs You (HM-1364). Every edit sits in a
/// block marked as Needs You's own, so removing it leaves the rest untouched.
public enum AgentSetup {
    public static let begin = "# >>> needs-you (managed by Needs You, remove in Settings > Agents) >>>"
    public static let end = "# <<< needs-you <<<"

    /// TOML string with escapes.
    static func toml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Codex `config.toml` block for the MCP server.
    public static func codexBlock(cli: String) -> String {
        """
        \(begin)
        [mcp_servers.needs-you]
        command = \(toml(cli))
        args = ["mcp"]
        env = { NEEDS_YOU_AGENT = "codex" }
        tool_timeout_sec = 900
        \(end)
        """
    }

    public static func blockRange(in text: String) -> Range<String.Index>? {
        guard let b = text.range(of: begin), let e = text.range(of: end, range: b.upperBound..<text.endIndex) else { return nil }
        var upper = e.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        return b.lowerBound..<upper
    }

    /// Adds or replaces the block. A TOML table must not be followed by root keys
    /// that belong elsewhere, so the block always goes at the end of the file.
    public static func withBlock(_ text: String, block: String) -> String {
        var out = without(text)
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty && !out.hasSuffix("\n\n") { out += "\n" }
        return out + block + "\n"
    }

    public static func without(_ text: String) -> String {
        guard let r = blockRange(in: text) else { return text }
        var out = text
        out.removeSubrange(r)
        while out.hasSuffix("\n\n\n") { out.removeLast() }
        return out
    }

    public static func hasBlock(_ text: String) -> Bool { blockRange(in: text) != nil }

    public static func cursorMCPEdit(_ root: [String: Any], cli: String, on: Bool) -> [String: Any] { HookSetup.cursorMCPEdit(root, cli: cli, on: on) }
}

/// Hook entries in an agent's JSON settings (Claude Code `settings.json`, Codex
/// `hooks.json`; same shape). Needs You's entries are the ones whose command
/// runs `needs-you hook`, so they can be found and removed without touching others.
public enum HookSetup {
    /// A command is ours when it runs the needs-you CLI's `hook` subcommand (the path may be quoted).
    public static func isOurs(_ command: String) -> Bool {
        command.range(of: #"needs-you'? hook "#, options: .regularExpression) != nil
    }

    /// Claude Code: PostToolUse lets a message reach a chat while it works.
    public static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "Notification", "SessionEnd"]
    public static let codexEvents = ["SessionStart", "UserPromptSubmit", "Stop"]
    /// Cursor (~/.cursor/hooks.json, `{"version":1,"hooks":{"stop":[{"command":…}]}}`):
    /// its event name -> the event Needs You understands.
    public static let cursorEvents: [(cursor: String, event: String)] = [("beforeSubmitPrompt", "UserPromptSubmit"), ("stop", "Stop"), ("afterAgentResponse", "AgentResponse")]

    /// Cursor's flat hooks file: adds (or refreshes) our entries, keeps every other hook.
    public static func installCursor(_ root: [String: Any], cli: String) -> [String: Any] {
        var root = removeCursor(root)
        root["version"] = root["version"] ?? 1
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (c, e) in cursorEvents {
            var list = hooks[c] as? [[String: Any]] ?? []
            list.append(["command": command(cli: cli, event: e, agent: "cursor")])
            hooks[c] = list
        }
        root["hooks"] = hooks
        return root
    }

    public static func removeCursor(_ root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let left = list.filter { !isOurs(($0["command"] as? String) ?? "") }
            hooks[event] = left.isEmpty ? nil : left
        }
        root["hooks"] = hooks
        return root
    }

    public static func isInstalledCursor(_ root: [String: Any]) -> Bool {
        ((root["hooks"] as? [String: Any]) ?? [:]).values.contains { v in
            ((v as? [[String: Any]]) ?? []).contains { isOurs(($0["command"] as? String) ?? "") }
        }
    }

    /// Cursor's ~/.cursor/mcp.json: our server entry (other servers stay).
    public static func cursorMCPEdit(_ root: [String: Any], cli: String, on: Bool) -> [String: Any] {
        mcpServerEdit(root, cli: cli, agent: "cursor", on: on)
    }

    /// An `mcpServers` JSON file (Cursor, the Claude app): adds or removes only our entry;
    /// every other server and key stays. An empty `mcpServers` we leave behind is dropped.
    public static func mcpServerEdit(_ root: [String: Any], cli: String, agent: String, on: Bool) -> [String: Any] {
        var root = root
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["needs-you"] = on ? ["command": cli, "args": ["mcp"], "env": ["NEEDS_YOU_AGENT": agent]] as [String: Any] : nil
        root["mcpServers"] = servers.isEmpty ? nil : servers
        return root
    }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func command(cli: String, event: String, agent: String) -> String {
        "\(q(cli)) hook \(event) --agent \(agent)"
    }

    /// Adds (or refreshes) one Needs You entry per event, keeping every other hook.
    public static func install(_ root: [String: Any], cli: String, agent: String, events: [String]) -> [String: Any] {
        var root = remove(root)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for e in events {
            var list = hooks[e] as? [[String: Any]] ?? []
            let entry: [String: Any] = ["type": "command", "command": command(cli: cli, event: e, agent: agent), "timeout": 10]
            let group: [String: Any] = ["hooks": [entry] as [[String: Any]]]
            list.append(group)
            hooks[e] = list
        }
        root["hooks"] = hooks
        return root
    }

    /// Takes out every Needs You hook; drops groups and events left empty.
    public static func remove(_ root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var g in groups {
                if let hs = g["hooks"] as? [[String: Any]] {
                    let left = hs.filter { !isOurs(($0["command"] as? String) ?? "") }
                    if left.isEmpty { continue }
                    g["hooks"] = left
                }
                kept.append(g)
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return root
    }

    public static func isInstalled(_ root: [String: Any]) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { v in
            ((v as? [[String: Any]]) ?? []).contains { g in
                ((g["hooks"] as? [[String: Any]]) ?? []).contains { isOurs(($0["command"] as? String) ?? "") }
            }
        }
    }

    /// What a hook prints so the agent gets the user's waiting messages (nil: nothing to say).
    public static func output(event: String, messages: [String], agent: String = "") -> [String: Any]? {
        if agent == "cursor" {
            // Cursor: a stop hook's followup_message becomes the next prompt; beforeSubmitPrompt must allow the prompt.
            if event == "UserPromptSubmit" { return ["continue": true] }
            guard !messages.isEmpty, event == "Stop" else { return nil }
            return ["followup_message": messages.joined(separator: "\n\n")]
        }
        guard !messages.isEmpty else { return nil }
        let text = messages.joined(separator: "\n\n")
        switch event {
        case "Stop":
            // Claude Code and Codex: the reason becomes the next prompt.
            return ["decision": "block", "reason": text]
        case "UserPromptSubmit", "PostToolUse", "SessionStart":
            return ["hookSpecificOutput": ["hookEventName": event, "additionalContext": text]]
        default:
            return nil
        }
    }

    /// A hook that runs inside a subagent (Claude Code sends agent_id then; its
    /// transcript lives under subagents/).
    public static func isSubagent(_ input: [String: Any]) -> Bool {
        if let id = input["agent_id"] as? String, !id.isEmpty { return true }
        if let p = input["transcript_path"] as? String, p.contains("/subagents/") { return true }
        return false
    }

    /// Events where a hook can hand messages over.
    public static func delivers(_ event: String) -> Bool {
        ["Stop", "UserPromptSubmit", "PostToolUse", "SessionStart"].contains(event)
    }
}
