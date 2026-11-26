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
    var id: String        // herdr pane id, registered chat id, or a chat app's bundle id
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
    /// A chat in a chat app's sidebar that is not open (HM-1389): opened before typing.
    var appChat: String? = nil
    /// Unique among targets (chat app chats share the app's bundle id).
    var key: String { id + (appChat.map { "#" + $0 } ?? "") }

    /// Stays the same when the chat restarts: its folder, else its name (routing memory).
    var memoryKey: String { folder.isEmpty ? "title:" + title.lowercased() : "folder:" + folder.lowercased() }

    var candidate: ChatCandidate {
        var c = ChatCandidate(title: kind == .registered ? [title, detail].filter { !$0.isEmpty }.joined(separator: " ") : title, label: label, folder: folder,
                              aliases: kind == .herdrAgent || kind == .registered ? [] : aliases, focused: focused, isDesktop: kind == .desktop)
        if kind == .desktop { c.detail = detail }
        return c
    }
}

enum Router {
    static let herdr = "/opt/homebrew/bin/herdr"
    /// Added on its own line to every delivered message, so the agent answers out loud.
    static let voiceSuffix = "(sent by voice: reply by voice with needs-you)"
    static let desktopBundleID = "com.anthropic.claudefordesktop"

    /// Chat apps with no MCP registration of their own (HM-1374): reachable by name only
    /// ("Hey Claude, ChatGPT: ..."), never as "this one"; typed into their open chat.
    static let chatApps: [(bundle: String, title: String, aliases: [String])] = [
        (desktopBundleID, "Claude app", ["claude desktop", "claude app", "claude for desktop", "claude desktop app", "desktop"]),
        ("com.openai.codex", "ChatGPT", ["chatgpt", "chat gpt", "chat g p t", "chatgbt", "codex app"]),
        ("com.openai.chat", "ChatGPT", ["chatgpt", "chat gpt", "chat g p t", "chatgbt"]),
    ]

    /// A chat app on this Mac, running or not (HM-1383).
    struct ChatApp: Hashable { var bundle: String; var title: String; var aliases: [String] }

    /// Installed chat apps, one per name (a running copy first): what "new chat on ..." can open.
    static func installedApps() -> [ChatApp] {
        var out: [ChatApp] = []
        let sorted = chatApps.sorted { a, b in
            let ra = !NSRunningApplication.runningApplications(withBundleIdentifier: a.bundle).isEmpty
            let rb = !NSRunningApplication.runningApplications(withBundleIdentifier: b.bundle).isEmpty
            return ra && !rb
        }
        for a in sorted where !out.contains(where: { $0.title == a.title }) {
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: a.bundle).isEmpty
            guard running || NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bundle) != nil else { continue }
            out.append(ChatApp(bundle: a.bundle, title: a.title, aliases: a.aliases))
        }
        for f in AppDiscovery.found where !out.contains(where: { $0.bundle == f.bundle }) && !f.name.isEmpty {
            out.append(ChatApp(bundle: f.bundle, title: f.name, aliases: [f.name.lowercased()]))
        }
        return out
    }

    /// The app has the Needs You MCP server, so its chat can answer out loud. Without it
    /// the voice line is left off and the app stays in front, so he can read the answer.
    static func appHasNeedsYou(_ bundle: String) -> Bool {
        guard bundle == desktopBundleID else { return false }
        let path = NSHomeDirectory() + "/Library/Application Support/Claude/claude_desktop_config.json"
        return ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").contains("needs-you")
    }

    /// Running chat apps: the ones found by layout (AppDiscovery) plus the known ones, whose
    /// entries only add the spoken names ("chat g p t") and open them when not running.
    static func runningChatApps() -> [ChatApp] {
        var out: [ChatApp] = []
        for a in chatApps where NSRunningApplication.runningApplications(withBundleIdentifier: a.bundle).first != nil
            && !out.contains(where: { $0.title == a.title }) {
            out.append(ChatApp(bundle: a.bundle, title: a.title, aliases: a.aliases))
        }
        for f in AppDiscovery.found where !out.contains(where: { $0.bundle == f.bundle }) && !f.name.isEmpty {
            out.append(ChatApp(bundle: f.bundle, title: f.name, aliases: [f.name.lowercased()]))
        }
        return out
    }

    static func appTargets() -> [ChatTarget] {
        runningChatApps().map { a in
            var t = ChatTarget(kind: .desktop, id: a.bundle, title: a.title, aliases: a.aliases, focused: false)
            t.detail = AXDelivery.openChatTitle(a.bundle) ?? "" // the chat open in it, for "what did it say about X"
            return t
        }
    }

    /// The chats in a chat app's sidebar that are not open now (Claude app: Pinned and Recents),
    /// each a target that opens it before typing. Only while the sidebar is shown.
    static func appChatTargets(_ apps: [ChatTarget]) -> [ChatTarget] {
        apps.flatMap { app -> [ChatTarget] in
            (AXDelivery.scanApp(app.id)?.chats.map(\.title) ?? []).filter { $0.caseInsensitiveCompare(app.detail) != .orderedSame }.prefix(15).map { title in
                var t = ChatTarget(kind: .desktop, id: app.id, title: title, aliases: [], focused: false)
                t.detail = title
                t.appChat = title
                return t
            }
        }
    }

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
        let regs = chats.map { c in
            ChatTarget(kind: .registered, id: c.id, title: c.displayName,
                       aliases: [],
                       focused: c.id == front?.id && used(c) > .distantPast,
                       label: "", folder: c.folder,
                       // The status is the title already when the chat has no folder: say it once.
                       detail: c.folder.isEmpty ? (c.prompts.last.map { "last asked: " + String($0.prefix(120)) } ?? "") : c.summary)
        }
        return regs.isEmpty ? [] : regs + appTargets()
    }

    /// Registered chats first, then herdr chats that never connected (started before Claude Code
    /// was connected, HM-1383: "send to the Game Boy terminal" must find them), then the chat apps.
    /// With nothing registered: the old herdr scan.
    static func voiceTargets(testOnly: Bool = false) async -> [ChatTarget] {
        if !testOnly {
            let reg = await MainActor.run { registeredTargets() }
            if !reg.isEmpty {
                let panes = await MainActor.run { Set(ChatRegistry.shared.reachable.compactMap { $0.pane?.id }) }
                let unconnected = await targetsAll().filter { $0.kind == .herdrAgent && !panes.contains($0.id) }
                    .map { t -> ChatTarget in var t = t; t.focused = false; return t } // "in front" means used last, among connected chats
                let apps = reg.filter { $0.kind == .desktop }
                return reg.filter { $0.kind != .desktop } + unconnected + apps + appChatTargets(apps)
            }
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
        out += appTargets()
        return out
    }

    // MARK: Parsing

    enum Parsed {
        case send(ChatTarget, String)
        case choose([ChatTarget], String, heardName: String)
        case nothing(String) // reason
        case newChat(String?, String) // project name as heard (nil = home), message
        /// A chat app with no hooks (HM-1383): a new chat there, or its open chat.
        case app(ChatApp, String, newChat: Bool)
    }

    /// "new chat on Claude desktop, ask ...", "use ChatGPT to ask ...": always a new chat in that app.
    static func appCommand(_ rest: String) -> (Parsed, String)? {
        let apps = installedApps()
        guard let m = AppCommand.parse(rest, apps: apps.map(\.aliases)) else { return nil }
        let log = "app command: new chat in \(apps[m.app].title)"
        let text = clean(m.message)
        guard !text.isEmpty, !Speech.isFillerOnly(text) else { return (.nothing("There was no message to send."), log) }
        return (.app(apps[m.app], text, newChat: true), log)
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
        if let a = appCommand(rest) { return a }
        let (route, log) = ChatMatcher.route(rest, targets.map(\.candidate), isProject: isProject)
        return parsed(route, log: log, targets: targets)
    }

    /// The matcher, then the on-device model where the matcher is not sure (HM-1364).
    @MainActor static func parseSmart(_ transcript: String, targets: [ChatTarget], memory: ((String) -> String?)? = nil) async -> (Parsed, String) {
        RoutingMemoryStore.shared.openKeys = Set(targets.map(\.memoryKey))
        let memory = memory ?? { RoutingMemoryStore.shared.lookup($0) }
        guard let rest = Wake.afterWakeWord(transcript) else { return parseLogged(transcript, targets: targets) }
        if let a = appCommand(rest) { return a }
        let candidates = targets.map(\.candidate)
        let (route, log) = ChatMatcher.route(rest, candidates, isProject: isProject)
        switch route {
        case .named, .newChat: return parsed(route, log: log, targets: targets)
        case .front, .choose: break
        }
        let words: String = { if case .choose(_, _, let h) = route { return RoutingMemory.words(rest: rest, heardName: h) }; return RoutingMemory.words(rest: rest) }()
        let mem = memory(words).flatMap { key in targets.firstIndex { $0.memoryKey == key } }
        let model = await ModelRouter.shared.pick(rest, targets)
        // The model asks for a new chat in an app he named ("start a ChatGPT chat about ..."):
        // only when the app's name is really in his words (HM-1383).
        if let p = model, p.newChat, targets[p.index].kind == .desktop, mentions(rest, targets[p.index]),
           let app = installedApps().first(where: { $0.bundle == targets[p.index].id }) {
            let text = clean(ModelRouter.trusted(p.message, in: rest) ?? rest)
            if !text.isEmpty { return (.app(app, text, newChat: true), log + "; model: new chat in \(app.title)") }
        }
        let topic = ChatMatcher.topic(rest, candidates)
        let (judged, why) = RouteJudge.decide(route, model: model?.index, memory: mem, topic: topic, explicitFront: log.hasPrefix("this one"))
        let topicNote = topic.map { "topic \($0)" }
        // Nothing named and nothing clear: ask between the chats used most recently.
        var judged0 = judged
        if case .choose(let idx, let m, let h) = judged, idx.isEmpty, h.isEmpty {
            judged0 = .choose(Array(targets.indices.filter { targets[$0].kind != .desktop }.prefix(3)), m, heardName: "")
        }
        return parsed(judged0, log: [log, topicNote, why.isEmpty ? nil : why].compactMap { $0 }.joined(separator: "; "), targets: targets)
    }

    /// One of the app's names is in what he said.
    static func mentions(_ rest: String, _ t: ChatTarget) -> Bool {
        let said = " " + ChatMatcher.words(rest).joined(separator: " ") + " "
        return ([t.title] + t.aliases).contains { a in
            let w = ChatMatcher.words(a).joined(separator: " ")
            return !w.isEmpty && w != "desktop" && said.contains(" " + w + " ")
        }
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

    /// Opens a new chat in a chat app (HM-1383): starts the app if needed, picks its
    /// "New Chat" menu item (Cmd+N when it has none), and waits until the page is an
    /// empty new chat. Throws when that never shows, so nothing is typed into an old chat.
    @MainActor static func startAppChat(_ app: ChatApp) async throws -> ChatTarget {
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundle).first
        if running == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundle) else {
                throw DeliveryError.failed("\(app.title) is not installed.")
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            running = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
        guard let r = running else { throw DeliveryError.failed("Could not open \(app.title).") }
        AXDelivery.enableWebAX(r)
        let ax = AXUIElementCreateApplication(r.processIdentifier)
        // A freshly started app needs a moment for its first window.
        for _ in 0..<100 where ((AXDelivery.attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []).isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        r.activate(options: [.activateAllWindows])
        for _ in 0..<100 where NSWorkspace.shared.frontmostApplication?.processIdentifier != r.processIdentifier {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == r.processIdentifier else {
            throw DeliveryError.failed("\(app.title) did not come to the front.")
        }
        let how = AXDelivery.pressMenuItem(ax, titles: ["New Chat", "New chat", "New Session", "New session", "New Conversation", "New conversation", "New Thread", "New thread", "New Task", "New task"])
        if how == nil { AXDelivery.key(45, .maskCommand) }
        AXDelivery.log("new chat in \(app.title): \(how.map { "menu \u{201C}\($0)\u{201D}" } ?? "Cmd+N")")
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if AXDelivery.desktopShowsNewSession(app.bundle) {
                return ChatTarget(kind: .desktop, id: app.bundle, title: app.title, aliases: app.aliases, focused: true, fresh: true)
            }
        }
        throw DeliveryError.failed("\(app.title) did not show a new chat.")
    }

    /// Brings a connected chat's window to the front (HM-1384): its herdr or tmux pane first,
    /// then the app that shows it. Nothing is typed.
    @MainActor @discardableResult
    static func reveal(_ c: ChatInfo) async -> Bool {
        if let p = c.pane, Mux.owns(p, pid: c.agentPid), let m = await Mux.focus(p),
           let app = m.clientPid.flatMap(AXDelivery.guiApp) {
            app.activate(options: [.activateAllWindows])
            return true
        }
        guard let app = AXDelivery.guiApp(c.agentPid) else { return false }
        app.activate(options: [.activateAllWindows])
        return true
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
    static func deliver(_ text: String, to target: ChatTarget, stayInFront: Bool = false) async throws -> Delivered {
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
            if let chat = target.appChat, !(await AXDelivery.openSidebarChat(target.id, title: chat)) {
                throw DeliveryError.failed("Could not open \u{201C}\(chat)\u{201D}.")
            }
            let ax = AXDelivery.Target(hint: AXMatch.Hint(cwd: ""), pid: nil, pane: nil, bundleID: target.id, stayInFront: stayInFront)
            switch await AXDelivery.send(text, to: ax) {
            case .typed(let app): return .typed(app)
            case .notTyped(let why): throw DeliveryError.failed("Not typed into \(target.title): \(why).")
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
