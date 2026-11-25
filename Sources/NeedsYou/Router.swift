import AppKit
import ApplicationServices
import Foundation
import NeedsYouShared

/// Where a spoken message can go: connected chats (MCP registrations), else the
/// old herdr scan and the Claude desktop app. Typing always goes through
/// `AXDelivery` (HM-1374), the one generic Accessibility path.
struct ChatTarget: Hashable {
    enum Kind: Hashable { case herdrAgent, herdrPane, desktop, registered }
    var kind: Kind
    var id: String        // herdr pane id, or "desktop"
    var title: String
    var aliases: [String] // folder name etc.
    var focused: Bool
    /// Picked because it was in front ("this one" / no name): sending also requires it still is.
    var byFocus = false
    /// A chat Needs You just started: its title is not known yet.
    var fresh = false
    /// herdr tab label ("summer-trips") and folder name ("" for the home folder),
    /// kept apart so the matcher can weigh them (HM-1364).
    var label = ""
    var folder = ""
    /// Registered chats: what it works on (status line, last prompt), for matching.
    var detail = ""

    /// Stays the same when the chat restarts: its folder, else its name (routing memory).
    var memoryKey: String { folder.isEmpty ? "title:" + title.lowercased() : "folder:" + folder.lowercased() }

    var candidate: ChatCandidate {
        ChatCandidate(title: kind == .registered ? [title, detail].filter { !$0.isEmpty }.joined(separator: " ") : title, label: label, folder: folder,
                      aliases: kind == .herdrAgent || kind == .registered ? [] : aliases, focused: focused, isDesktop: kind == .desktop)
    }
}

enum Router {
    static let herdr = "/opt/homebrew/bin/herdr"
    /// Added on its own line to every delivered message, so the agent answers out loud.
    static let voiceSuffix = "(sent by voice: reply by voice with needs-you)"
    static let desktopBundleID = "com.anthropic.claudefordesktop"

    /// Test panes armed with `needs-you wake-test --arm-pane` (pane id -> expiry).
    /// Kept in defaults so a restart during a test does not reopen real chats.
    @MainActor static var armedPanes: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: "armedTestPanes") as? [String: Date]) ?? [:] }
        set { newValue.isEmpty ? UserDefaults.standard.removeObject(forKey: "armedTestPanes") : UserDefaults.standard.set(newValue, forKey: "armedTestPanes") }
    }

    // MARK: Targets

    /// Chats that registered through the Needs You MCP server (HM-1364). Once any chat
    /// has, these are the only targets: nothing is read off the screen and nothing is
    /// typed; a message waits in the chat's inbox for its next tool call or turn end.
    @MainActor static func registeredTargets() -> [ChatTarget] {
        let reg = ChatRegistry.shared
        let chats = reg.reachable
        func used(_ c: ChatInfo) -> Date {
            max(c.lastPromptAt ?? .distantPast, reg.lastSpokenTo[c.id] ?? .distantPast)
        }
        let front = chats.max { used($0) < used($1) }
        return chats.map { c in
            ChatTarget(kind: .registered, id: c.id, title: c.displayName,
                       aliases: [],
                       focused: c.id == front?.id && used(c) > .distantPast,
                       label: "", folder: c.folder,
                       // The status is the title already when the chat has no folder: say it once.
                       detail: c.folder.isEmpty ? (c.prompts.last.map { "last asked: " + String($0.prefix(120)) } ?? "") : c.summary)
        }
    }

    /// Registered chats when there are any; else the old herdr scan (until he connects an agent).
    static func voiceTargets(testOnly: Bool = false) async -> [ChatTarget] {
        if !testOnly {
            let reg = await MainActor.run { registeredTargets() }
            if !reg.isEmpty { return reg }
        }
        return await targets(testOnly: testOnly)
    }

    /// Tests only ever see the panes they armed, never a real chat.
    static func targets(testOnly: Bool = false) async -> [ChatTarget] {
        if testOnly {
            let all = await targetsAll()
            // A pane id herdr reused for a Claude chat is never a test pane.
            let agents = Set(all.filter { $0.kind == .herdrAgent }.map(\.id))
            return all.filter { $0.kind == .herdrPane && !agents.contains($0.id) }
        }
        return await targetsAll()
    }

    private static func targetsAll() async -> [ChatTarget] {
        var out: [ChatTarget] = []
        // Tab labels the user gave in herdr ("summer-trips") are names too.
        var labels: [String: String] = [:]
        if let json = try? await run([herdr, "tab", "list"]),
           let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tabs = (root["result"] as? [String: Any])?["tabs"] as? [[String: Any]] {
            for t in tabs { if let id = t["tab_id"] as? String, let l = t["label"] as? String { labels[id] = l } }
        }
        if let json = try? await run([herdr, "agent", "list"]),
           let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let agents = (root["result"] as? [String: Any])?["agents"] as? [[String: Any]] {
            for a in agents {
                guard let pane = a["pane_id"] as? String else { continue }
                let cwd = (a["cwd"] as? String) ?? ""
                let folder = cwd.split(separator: "/").last.map(String.init) ?? ""
                let label = labels[(a["tab_id"] as? String) ?? ""] ?? ""
                var title = (a["terminal_title_stripped"] as? String) ?? (a["terminal_title"] as? String) ?? "Claude"
                if title.isEmpty || title == "Claude Code" { title = folder.isEmpty ? "Claude Code" : "Claude Code in \(folder)" }
                out.append(ChatTarget(kind: .herdrAgent, id: pane, title: title,
                                      aliases: [folder, label].filter { !$0.isEmpty },
                                      focused: (a["focused"] as? Bool) ?? false,
                                      label: label, folder: cwd == NSHomeDirectory() ? "" : folder))
            }
        }
        let armed = await MainActor.run { armedPanes.filter { $0.value > Date() }.map(\.key) }
        for pane in armed {
            var title = "Test pane \(pane)"
            var focused = false
            // A pane that no longer exists is not a target (fail closed).
            guard let json = try? await run([herdr, "pane", "get", pane]),
               let data = json.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let p = ((root["result"] as? [String: Any])?["pane"] as? [String: Any]) else { continue }
            if let tab = p["tab_id"] as? String, let l = labels[tab], !l.isEmpty { title = l }
            focused = (p["focused"] as? Bool) ?? false
            if focused { for i in out.indices { out[i].focused = false } }
            out.append(ChatTarget(kind: .herdrPane, id: pane, title: title, aliases: ["test"], focused: focused))
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleID).first != nil {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == desktopBundleID
            out.append(ChatTarget(kind: .desktop, id: "desktop", title: "Claude desktop app",
                                  aliases: ["desktop", "claude app", "app"], focused: front))
        }
        return out
    }

    // MARK: Parsing

    enum Parsed {
        case send(ChatTarget, String)
        case choose([ChatTarget], String, heardName: String)
        case nothing(String) // reason
        case newChat(String?, String) // project name as heard (nil = home), message
    }

    static func parse(_ transcript: String, targets: [ChatTarget]) -> Parsed { parseLogged(transcript, targets: targets).0 }

    /// The message part of a command so far, without the wake phrase and a leading
    /// chat name ("Hey Claude, this one:" -> ""). HM-1360: a pause there is not the end.
    static func messageAfterTarget(_ transcript: String) -> String {
        var rest = Wake.afterWakeWord(transcript) ?? transcript
        if let r = rest.range(of: #"^(?i)(this one|this chat|this window|this tab|this|here)\b[\s,.:;!-]*"#, options: .regularExpression) { rest = String(rest[r.upperBound...]) }
        else if let colon = rest.firstIndex(of: ":"), rest.distance(from: rest.startIndex, to: colon) <= 60 { rest = String(rest[rest.index(after: colon)...]) }
        let text = clean(rest)
        return Speech.isFillerOnly(text) ? "" : text
    }

    /// Parses and returns one line for the routing log (heard name, top matches, why).
    /// The matching itself is `ChatMatcher` (NeedsYouShared), unit-tested on real cases.
    static func parseLogged(_ transcript: String, targets: [ChatTarget]) -> (Parsed, String) {
        guard let rest = Wake.afterWakeWord(transcript) else { return (.nothing("No \"\(Wake.phrase)\" in what I heard."), "no wake phrase") }
        let (route, log) = ChatMatcher.route(rest, targets.map(\.candidate), isProject: isProject)
        return parsed(route, log: log, targets: targets)
    }

    /// The matcher, then the on-device model where the matcher is not sure (HM-1364).
    @MainActor static func parseSmart(_ transcript: String, targets: [ChatTarget], memory: ((String) -> String?)? = nil) async -> (Parsed, String) {
        RoutingMemoryStore.shared.openKeys = Set(targets.map(\.memoryKey))
        let memory = memory ?? { RoutingMemoryStore.shared.lookup($0) }
        guard let rest = Wake.afterWakeWord(transcript) else { return parseLogged(transcript, targets: targets) }
        let (route, log) = ChatMatcher.route(rest, targets.map(\.candidate), isProject: isProject)
        switch route {
        case .named, .newChat: return parsed(route, log: log, targets: targets)
        case .front, .choose: break
        }
        let words: String = { if case .choose(_, _, let h) = route { return RoutingMemory.words(rest: rest, heardName: h) }; return RoutingMemory.words(rest: rest) }()
        let mem = memory(words).flatMap { key in targets.firstIndex { $0.memoryKey == key } }
        let model = await ModelRouter.shared.pick(rest, targets)
        let (judged, why) = RouteJudge.decide(route, model: model, memory: mem, explicitFront: log.hasPrefix("this one"))
        return parsed(judged, log: why.isEmpty ? log : log + "; " + why, targets: targets)
    }

    private static func parsed(_ route: ChatMatcher.Route, log: String, targets: [ChatTarget]) -> (Parsed, String) {

        func message(_ m: String) -> String? {
            let text = clean(m)
            return text.isEmpty || Speech.isFillerOnly(text) ? nil : text
        }
        switch route {
        case .newChat(let project, let m):
            guard let text = message(m) else { return (.nothing("There was no message to send."), log) }
            return (.newChat(project, text), log)
        case .named(let i, let m):
            guard let text = message(m) else { return (.nothing("There was no message to send."), log) }
            return (.send(targets[i], text), log) // named: a focus change later does not cancel it
        case .front(let i, let m):
            guard let text = message(m) else { return (.nothing("There was no message to send."), log) }
            if i == nil, targets.first?.kind == .registered {
                // Connected chats only: never start a chat by typing; ask which one.
                return (.choose(Array(targets.prefix(4)), text, heardName: ""), log + "; nothing in front -> ask")
            }
            guard let i else {
                // No chat in front (or none open): start a new one in the home folder.
                if !targets.contains(where: { $0.kind != .desktop }) { return (.newChat(nil, text), log) }
                return (.newChat(nil, text), log + "; nothing in front -> new chat")
            }
            var t = targets[i]; t.byFocus = true
            return (.send(t, text), log)
        case .choose(let idx, let m, let heard):
            guard let text = message(m) else { return (.nothing("There was no message to send."), log) }
            return (.choose(idx.map { targets[$0] }, text, heardName: heard), log)
        }
    }

    /// A heard name that is a project folder under ~/Projects ("needs-you: ..." with no
    /// such chat open starts a chat there).
    private static func isProject(_ name: String) -> Bool {
        let root = NSHomeDirectory() + "/Projects"
        guard let best = rankFolders(name, projectFolders(root: root)).first else { return false }
        return best.score >= 0.9
    }

    static func clean(_ message: String) -> String {
        let message = message.replacingOccurrences(of: #"\s+([.,!?])"#, with: "$1", options: .regularExpression)
        return Speech.stripStopPhrase(message.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",:;-—")).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: New chats

    /// Set by `needs-you wake-test --projects-root`: tests never open real project folders.
    @MainActor static var testRoot: String?

    struct Folder { var name: String; var path: String }

    /// Project folders under ~/Projects, one and two levels deep (work/site, personal/blog).
    static func projectFolders(root: String) -> [Folder] {
        let fm = FileManager.default
        var out: [Folder] = []
        func dirs(_ p: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: p)) ?? []).filter { n in
                var isDir: ObjCBool = false
                return !n.hasPrefix(".") && !n.hasPrefix("_") && n != "node_modules" && fm.fileExists(atPath: p + "/" + n, isDirectory: &isDir) && isDir.boolValue
            }
        }
        for a in dirs(root) {
            out.append(Folder(name: a, path: root + "/" + a))
            for b in dirs(root + "/" + a) where !fm.fileExists(atPath: root + "/" + a + "/.git") {
                out.append(Folder(name: b, path: root + "/" + a + "/" + b))
            }
        }
        return out
    }

    static func rankFolders(_ name: String, _ folders: [Folder]) -> [(folder: Folder, score: Double)] {
        let squash: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        let want = tokens(name), whole = squash(name)
        return folders.map { f in
            let have = tokens(f.name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))
            var score = want.isEmpty ? 0 : Double(want.filter { w in have.contains { similar(w, $0) } }.count) / Double(want.count)
            let fn = squash(f.name)
            if fn == whole { score = max(score, 1.2) } else if whole.count >= 4, levenshtein(fn, whole) <= 2 { score = max(score, 0.9) }
            return (f, score)
        }
        .filter { $0.score > 0 }
        .sorted { $0.score > $1.score }
    }

    /// Opens a herdr tab in `dir`, starts claude there, and returns it once it is ready for input.
    static func startNewChat(in dir: String, label: String, focus: Bool = true) async throws -> ChatTarget {
        // Tests never move the user's focus.
        let created = try await run([herdr, "tab", "create", "--cwd", dir, "--label", label] + (focus ? ["--focus"] : []), checkExit: true)
        guard let data = created.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pane = ((root["result"] as? [String: Any])?["root_pane"] as? [String: Any])?["pane_id"] as? String else {
            throw DeliveryError.failed("Could not open a new herdr tab.")
        }
        let name = "voice-" + UUID().uuidString.prefix(6).lowercased()
        var lastError = ""
        for _ in 0..<3 { // the shell prompt may need a moment
            try await Task.sleep(nanoseconds: 800_000_000)
            do {
                _ = try await run([herdr, "agent", "start", name, "--kind", "claude", "--pane", pane, "--timeout", "60000"], checkExit: true)
                return ChatTarget(kind: .herdrAgent, id: pane, title: label, aliases: [], focused: focus, fresh: true)
            } catch { lastError = error.localizedDescription }
        }
        throw DeliveryError.failed("Claude did not start in the new tab: \(lastError.prefix(160))")
    }

    // MARK: Fuzzy match

    static func tokens(_ s: String) -> [String] { ChatMatcher.tokens(s) }
    static func similar(_ a: String, _ b: String) -> Bool { ChatMatcher.similar(a, b) }
    static func levenshtein(_ a: String, _ b: String) -> Int { ChatMatcher.levenshtein(a, b) }

    static func rank(_ name: String, _ targets: [ChatTarget]) -> [(target: ChatTarget, score: Double)] {
        ChatMatcher.rank(name, targets.map(\.candidate)).map { (targets[$0.index], $0.score) }
    }

    /// Picks one of the offered chats from a spoken answer ("the second one", "trip planner").
    static func pick(_ answer: String, from options: [ChatTarget]) -> ChatTarget? {
        let w = Speech.words(answer)
        let ordinals: [(Set<String>, Int)] = [(["first", "one", "1"], 0), (["second", "two", "2"], 1), (["third", "three", "3"], 2), (["fourth", "four", "4"], 3)]
        for (names, i) in ordinals where i < options.count && !w.filter({ names.contains($0) }).isEmpty && w.count <= 4 {
            return options[i]
        }
        let ranked = rank(answer, options)
        if let best = ranked.first, best.score >= 0.34 { return best.target }
        return nil
    }

    // MARK: Delivery

    enum DeliveryError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
    }

    /// Re-reads the target right before typing. Throws if it is gone, renamed,
    /// or (for "this one") no longer the chat in front.
    static func verify(_ target: ChatTarget) async throws {
        if target.kind == .registered {
            let alive = await MainActor.run { ChatRegistry.shared.reachable.contains { $0.id == target.id } }
            if !alive { throw DeliveryError.failed("That chat has ended, so nothing was sent.") }
            return
        }
        let now = await targetsAll()
        guard let live = now.first(where: { $0.kind == target.kind && $0.id == target.id }) else {
            throw DeliveryError.failed("That chat is gone, so nothing was sent.")
        }
        guard target.fresh || live.title == target.title else {
            throw DeliveryError.failed("That chat changed its title (now \u{201C}\(live.title)\u{201D}), so nothing was sent.")
        }
        if target.byFocus && !live.focused {
            throw DeliveryError.failed("Focus moved to another chat, so nothing was sent.")
        }
    }

    /// How a message went out.
    enum Delivered: Equatable {
        /// Typed into the chat's window (HM-1374): the app's name.
        case typed(String)
        /// Waits in the chat's inbox for its next tool call, hook or turn end; why it was not typed.
        case queued(String)
    }

    /// Every message that is typed goes through `AXDelivery` (HM-1374): one generic
    /// Accessibility path for every app, with herdr or tmux selecting the pane first.
    /// A connected chat is typed into only when it is idle; a busy one (or a failed
    /// check) gets it from its inbox.
    @discardableResult
    static func deliver(_ text: String, to target: ChatTarget) async throws -> Delivered {
        try await verify(target)
        await MainActor.run { AXDelivery.lastLog = [] }
        switch target.kind {
        case .herdrAgent, .herdrPane:
            let ax = AXDelivery.Target(hint: AXMatch.Hint(cwd: "", names: [target.label, target.folder].filter { !$0.isEmpty }),
                                       pid: nil, pane: PaneRef(kind: .herdr, id: target.id))
            switch await AXDelivery.send(text, to: ax) {
            case .typed(let app): return .typed(app)
            case .notTyped(let why): throw DeliveryError.failed("Not typed: \(why).")
            }
        case .desktop:
            let ax = AXDelivery.Target(hint: AXMatch.Hint(cwd: ""), pid: nil, pane: nil, bundleID: desktopBundleID)
            switch await AXDelivery.send(text, to: ax) {
            case .typed(let app): return .typed(app)
            case .notTyped(let why): throw DeliveryError.failed("Not typed into the Claude app: \(why).")
            }
        case .registered:
            // Typed when idle; on .queued the caller queues it with its history entry (VoiceCommands).
            return await typeIntoChat(text, id: target.id)
        }
    }

    /// A connected chat: typed into its window when it is idle (HM-1374). Never queues;
    /// on `.queued` the caller puts it in the inbox.
    @MainActor
    static func typeIntoChat(_ text: String, id: String, dryRun: Bool = false) async -> Delivered {
        let reg = ChatRegistry.shared
        AXDelivery.lastLog = []
        guard let c = reg.chats[id] else { return .queued("chat not found") }
        guard c.state == .idle else { return .queued("it is busy") }
        guard reg.queuedCount(id) == 0 else { return .queued("earlier messages still wait") }
        switch await AXDelivery.send(text, to: axTarget(c), dryRun: dryRun) {
        case .typed(let app):
            if !dryRun { reg.typedInto(id, ifUnchangedSince: c.lastActivity); reg.spokeTo(id) }
            return .typed(app)
        case .notTyped(let why):
            return .queued(why)
        }
    }

    static func axTarget(_ c: ChatInfo) -> AXDelivery.Target {
        let names = [c.folder, c.status ?? ""].filter { !$0.isEmpty }
        let texts = [c.lastReply ?? "", c.prompts.last ?? ""].filter { !$0.isEmpty }
        return AXDelivery.Target(hint: AXMatch.Hint(cwd: c.cwd, names: names, texts: texts), pid: c.agentPid, pane: c.pane)
    }

    // MARK: Process

    static func run(_ args: [String], checkExit: Bool = false, env extra: [String: String] = [:]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: args[0])
            p.arguments = Array(args.dropFirst())
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            for (k, v) in extra { env[k] = v }
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if checkExit && proc.terminationStatus != 0 {
                    cont.resume(throwing: DeliveryError.failed("herdr failed: \(out.prefix(200))"))
                } else {
                    cont.resume(returning: out)
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
