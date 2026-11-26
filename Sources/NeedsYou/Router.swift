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
    /// herdr workspace label ("general", HM-1425): he names chats by it too.
    var workspace = ""
    /// It runs in his home folder (`folder` is empty then).
    var home = false
    /// Registered chats: what it works on (status line, last prompt), for matching.
    var detail = ""
    /// A chat in a chat app's sidebar that is not open (HM-1389): opened before typing.
    var appChat: String? = nil
    /// The app it belongs to (HM-1415): "herdr", "tmux" or a bundle id; nil when unknown.
    var app: String? = nil
    /// Its app is turned on in Settings, Apps.
    var enabled: Bool { ChatApps.isEnabled(app) }
    /// Unique among targets (chat app chats share the app's bundle id).
    var key: String { id + (appChat.map { "#" + $0 } ?? "") }

    /// Stays the same when the chat restarts: its folder, else its name (routing memory).
    var memoryKey: String { folder.isEmpty ? "title:" + title.lowercased() : "folder:" + folder.lowercased() }

    var candidate: ChatCandidate {
        var c = ChatCandidate(title: kind == .registered ? [title, detail].filter { !$0.isEmpty }.joined(separator: " ") : title, label: label, folder: folder,
                              aliases: kind == .herdrAgent || kind == .registered ? places : aliases, focused: focused, isDesktop: kind == .desktop)
        if kind == .desktop { c.detail = detail }
        return c
    }

    /// Its herdr workspace, alone and with the tab label ("bakery general"), as names (HM-1425).
    var places: [String] {
        guard !workspace.isEmpty else { return [] }
        return [workspace] + (label.isEmpty ? [] : [label + " " + workspace])
    }
}

enum Router {
    static let herdr = "/opt/homebrew/bin/herdr"
    /// Added on its own line to every delivered message, so the agent answers out loud.
    static let voiceSuffix = "(sent by voice: reply by voice with needs-you)"
    /// Chat apps sync their chats to his other Macs: the reply names this Mac, and Needs You
    /// on any other Mac refuses to speak it (HM-1398).
    static var appVoiceSuffix: String {
        let mac = Host.current().localizedName ?? "this Mac"
        return "(sent by voice from \(mac): reply by voice with needs-you, for_mac \"\(mac)\")"
    }
    static let desktopBundleID = "com.anthropic.claudefordesktop"

    /// A chat app on this Mac, running or not (HM-1383). Found by its layout
    /// (AppDiscovery), named by its own name: no app is listed here by name.
    struct ChatApp: Hashable { var bundle: String; var title: String; var aliases: [String] }

    private static func chatApp(_ f: AppDiscovery.Found) -> ChatApp {
        ChatApp(bundle: f.bundle, title: f.name, aliases: [f.name.lowercased()])
    }

    /// Chat apps found on this Mac, running ones first: what "new chat on ..." can open.
    static func installedApps(includeDisabled: Bool = false) -> [ChatApp] {
        let running = runningChatApps()
        let all = running + AppDiscovery.known.filter { k in !running.contains { $0.bundle == k.bundle } }.map(chatApp)
        return includeDisabled ? all : all.filter { ChatApps.isEnabled($0.bundle) } // HM-1415
    }

    /// The app has the Needs You MCP server, so its chat can answer out loud. Without it
    /// the voice line is left off and the app stays in front, so he can read the answer.
    static func appHasNeedsYou(_ bundle: String) -> Bool {
        guard bundle == desktopBundleID else { return false }
        let path = NSHomeDirectory() + "/Library/Application Support/Claude/claude_desktop_config.json"
        return ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").contains("needs-you")
    }

    /// Running chat apps, as found by their layout (AppDiscovery).
    static func runningChatApps() -> [ChatApp] {
        AppDiscovery.found.filter { !$0.name.isEmpty }.map(chatApp)
    }

    static func appTargets() -> [ChatTarget] {
        runningChatApps().map { a in
            var t = ChatTarget(kind: .desktop, id: a.bundle, title: a.title, aliases: a.aliases, focused: false)
            t.app = a.bundle
            t.detail = AXDelivery.openChatTitle(a.bundle) ?? "" // the chat open in it, for "what did it say about X"
            return t
        }
    }

    /// The chats in a chat app's sidebar that are not open now (Claude app: Pinned and Recents),
    /// each a target that opens it before typing. Only while the sidebar is shown.
    static func appChatTargets(_ apps: [ChatTarget]) -> [ChatTarget] {
        apps.flatMap { app -> [ChatTarget] in
            (AXDelivery.scanApp(app.id)?.chats.map(\.title) ?? []).filter { $0.caseInsensitiveCompare(app.detail) != .orderedSame }.map { title in
                var t = ChatTarget(kind: .desktop, id: app.id, title: title, aliases: [], focused: false)
                t.app = app.id
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
            var t = ChatTarget(kind: .registered, id: c.id, title: c.displayName,
                       aliases: [],
                       focused: c.id == front?.id && used(c) > .distantPast,
                       label: "", folder: c.folder,
                       // What it works on (HM-1408): the status, and the last prompt. With no folder the title is
                       // the status's start already: the status is repeated only when it is longer than that.
                       detail: c.folder.isEmpty && (c.status ?? "").count <= 40 ? (c.prompts.last.map { "last asked: " + String($0.prefix(120)) } ?? "") : c.summary)
            t.app = ChatApps.owner(c)?.id
            t.home = !c.cwd.isEmpty && c.folder.isEmpty
            return t
        }
        // The chat apps are read off the screen by `voiceTargets`, off the main thread (HM-1418).
        return regs
    }

    /// Registered chats first, then herdr chats that never connected (started before Claude Code
    /// was connected, HM-1383: "send to the Game Boy terminal" must find them), then the chat apps.
    /// With nothing registered: the old herdr scan.
    /// Chats of apps turned off in Settings, Apps (HM-1415) are left out: never offered, never
    /// matched, never learned from. `includeDisabled` is for Router Debug, which shows them greyed.
    static func voiceTargets(testOnly: Bool = false, includeDisabled: Bool = false) async -> [ChatTarget] {
        let all = await voiceTargetsAll(testOnly: testOnly)
        return includeDisabled ? all : all.filter(\.enabled)
    }

    private static func voiceTargetsAll(testOnly: Bool) async -> [ChatTarget] {
        if !testOnly {
            var reg = await MainActor.run { registeredTargets() }
            if !reg.isEmpty {
                // Connected chats in herdr get its tab and workspace names too (HM-1425).
                let herdrPanes = await MainActor.run { () -> [String: String] in
                    var m: [String: String] = [:]
                    for c in ChatRegistry.shared.reachable { if let p = c.pane, p.kind == .herdr { m[c.id] = p.id } }
                    return m
                }
                if !herdrPanes.isEmpty {
                    let places = await herdrPlaces()
                    for i in reg.indices {
                        guard let pane = herdrPanes[reg[i].id], let p = places[pane] else { continue }
                        reg[i].label = p.tab; reg[i].workspace = p.workspace
                    }
                }
                let panes = await MainActor.run { Set(ChatRegistry.shared.reachable.compactMap { $0.pane?.id }) }
                let unconnected = await targetsAll(apps: false).filter { $0.kind == .herdrAgent && !panes.contains($0.id) }
                    .map { t -> ChatTarget in var t = t; t.focused = false; return t } // "in front" means used last, among connected chats
                // Reading chat apps' windows can take seconds when one is busy: never on the main thread (HM-1418).
                let apps = reg.filter { $0.kind == .desktop }
                let enabled = apps.filter(\.enabled)
                let sidebar = await AXDelivery.offMain { appChatTargets(enabled) }
                return reg.filter { $0.kind != .desktop } + unconnected + apps + sidebar
            }
        }
        return await targets(testOnly: testOnly, includeDisabled: true)
    }

    /// Tests only ever see the panes they armed, never a real chat.
    static func targets(testOnly: Bool = false, includeDisabled: Bool = false) async -> [ChatTarget] {
        let all = await targetsAll()
        let out: [ChatTarget]
        if testOnly {
            // A pane id herdr reused for a Claude chat is never a test pane.
            let agents = Set(all.filter { $0.kind == .herdrAgent }.map(\.id))
            out = all.filter { $0.kind == .herdrPane && !agents.contains($0.id) }
        } else {
            out = all
        }
        return includeDisabled ? out : out.filter(\.enabled)
    }

    /// herdr workspace id -> its label ("w2" -> "general").
    static func herdrWorkspaces() async -> [String: String] {
        var out: [String: String] = [:]
        if let json = try? await run([herdr, "workspace", "list"]),
           let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = (root["result"] as? [String: Any])?["workspaces"] as? [[String: Any]] {
            for w in list { if let id = w["workspace_id"] as? String, let l = w["label"] as? String { out[id] = l } }
        }
        return out
    }

    /// herdr pane id -> its tab label and workspace label, for connected chats in herdr (HM-1425).
    static func herdrPlaces() async -> [String: (tab: String, workspace: String)] {
        let spaces = await herdrWorkspaces()
        var tabs: [String: String] = [:]
        if let json = try? await run([herdr, "tab", "list"]),
           let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = (root["result"] as? [String: Any])?["tabs"] as? [[String: Any]] {
            for t in list { if let id = t["tab_id"] as? String { tabs[id] = (t["label"] as? String) ?? "" } }
        }
        var out: [String: (tab: String, workspace: String)] = [:]
        if let json = try? await run([herdr, "pane", "list"]),
           let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = (root["result"] as? [String: Any])?["panes"] as? [[String: Any]] {
            for p in list {
                guard let id = p["pane_id"] as? String else { continue }
                // A pane label he gave wins over the tab's.
                let paneLabel = (p["label"] as? String) ?? ""
                out[id] = (paneLabel.isEmpty ? tabs[(p["tab_id"] as? String) ?? ""] ?? "" : paneLabel,
                           spaces[(p["workspace_id"] as? String) ?? ""] ?? "")
            }
        }
        return out
    }

    private static func targetsAll(apps: Bool = true) async -> [ChatTarget] {
        var out: [ChatTarget] = []
        // Tab labels the user gave in herdr ("summer-trips") are names too, and workspace labels (HM-1425).
        var labels: [String: String] = [:]
        let spaces = await herdrWorkspaces()
        var tabSpace: [String: String] = [:]
        if let json = try? await run([herdr, "tab", "list"]),
           let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tabs = (root["result"] as? [String: Any])?["tabs"] as? [[String: Any]] {
            for t in tabs {
                guard let id = t["tab_id"] as? String else { continue }
                if let l = t["label"] as? String { labels[id] = l }
                if let w = t["workspace_id"] as? String { tabSpace[id] = spaces[w] ?? "" }
            }
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
                var t = ChatTarget(kind: .herdrAgent, id: pane, title: title,
                                   aliases: [folder, label].filter { !$0.isEmpty },
                                   focused: (a["focused"] as? Bool) ?? false,
                                   label: label, folder: cwd == NSHomeDirectory() ? "" : folder)
                t.app = ChatAppSwitches.muxID(.herdr)
                t.workspace = spaces[(a["workspace_id"] as? String) ?? ""] ?? tabSpace[(a["tab_id"] as? String) ?? ""] ?? ""
                t.home = cwd == NSHomeDirectory()
                out.append(t)
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
            var t = ChatTarget(kind: .herdrPane, id: pane, title: title, aliases: ["test"], focused: focused)
            t.app = ChatAppSwitches.muxID(.herdr)
            out.append(t)
        }
        if apps { out += await AXDelivery.offMain { appTargets() } }
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
        /// Do not disturb, voicemails, list chats (HM-1352), as the model read it.
        case presence(PresenceCommand)
    }

    /// The message part of a command so far, without the wake phrase. HM-1360: a pause
    /// right after "Hey Mac, orchard:" is not the end; the message is still coming.
    static func messageAfterTarget(_ transcript: String) -> String {
        let rest = (Wake.afterWakeWord(transcript) ?? transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasSuffix(":") { return "" }
        let text = clean(rest)
        return Speech.isFillerOnly(text) ? "" : text
    }

    /// What the last routing saw (Router Debug, HM-1408).
    struct Reading {
        var intent: VoiceIntent?
        var rawNamed: String
        var evidence: RouteEvidence
        var votes: [(vote: RouteLearning.Vote, index: Int)]
        var lang: String
    }
    @MainActor static var lastReading: Reading?

    /// The on-device model reads the command (HM-1399); `IntentJudge` checks its pick against
    /// what the message means next to each chat, earlier matches like it, and his words (HM-1408).
    /// No phrase or pattern decides anything.
    @MainActor static func parseSmart(_ transcript: String, targets: [ChatTarget]) async -> (Parsed, String) {
        guard let rest = Wake.afterWakeWord(transcript) else { return (.nothing("No \"\(Wake.phrase)\" in what I heard."), "no wake phrase") }
        let candidates = targets.map(\.candidate)
        var intent = await ModelRouter.shared.pick(rest, targets)
        let rawNamed = intent?.named ?? ""
        // A name counts only when he said it, word for word (HM-1408).
        if let i = intent { intent?.named = VoiceIntent.spokenName(i.named, in: rest) }
        let meaning = MeaningIndex.shared.rank(rest, targets)
        let votes = RouteLearningStore.shared.votes(meaning.vector, lang: meaning.lang, targets: targets)
        let recent = Array(targets.indices.filter { targets[$0].kind != .desktop }.prefix(3))
        let ev = RouteEvidence(topic: ChatMatcher.topic(rest, candidates), clearTopic: ChatMatcher.topic(rest, candidates, minScore: 2),
                               meaning: meaning.scores, learned: votes.map { .init(index: $0.index, weight: $0.vote.weight) }, recent: recent)
        lastReading = Reading(intent: intent, rawNamed: rawNamed, evidence: ev, votes: votes, lang: meaning.lang.rawValue)
        let (outcome, why) = IntentJudge.decide(intent, candidates, ev, isProject: isProject)
        let text = clean(intent.flatMap { ModelRouter.trusted($0.message, in: rest) } ?? rest)
        let hasText = !text.isEmpty && !Speech.isFillerOnly(text)
        let modelNote = intent.map { "model: \($0.action.rawValue) \($0.chat.map { String($0 + 1) } ?? "-")\($0.named.isEmpty ? "" : " named \u{201C}\($0.named)\u{201D}")\($0.meansFront ? " (in front)" : "")" }
            ?? (ModelRouter.available ? "model: no answer" : "model: not available")
        let ignored = !rawNamed.isEmpty && (intent?.named ?? "").isEmpty ? "ignored name \u{201C}\(rawNamed.prefix(60))\u{201D} (not his words)" : nil
        let learned = votes.isEmpty ? nil : "learned " + votes.prefix(3).map { String(format: "%d %.2f", $0.index + 1, $0.vote.weight) }.joined(separator: ", ")
        let log = [modelNote, ignored, "meaning " + Meaning.describe(ev.meaning), learned, ev.topic.map { "topic \($0 + 1)" }, why].compactMap { $0 }.joined(separator: "; ")
        let noText: (Parsed, String) = (.nothing("There was no message to send."), log)
        switch outcome {
        case .nothing:
            return (.nothing("I didn't catch what to do."), log)
        case .presence(let a, let summary):
            switch a {
            case .away: return (.presence(.away(goodNight: false)), log)
            case .goodNight: return (.presence(.away(goodNight: true)), log)
            case .back: return (.presence(.back(summary: summary)), log)
            case .voicemails: return (.presence(.playVoicemails), log)
            case .summary: return (.presence(.summary), log)
            case .listChats: return (.presence(.listChats), log)
            default: return (.nothing("I didn't catch what to do."), log)
            }
        case .notFound(let n):
            guard hasText else { return noText }
            return (.choose([], text, heardName: n), log)
        case .newChat(let name):
            guard hasText else { return noText }
            if !name.isEmpty {
                let apps = installedApps()
                let ranked = ChatMatcher.rank(name, apps.map { ChatCandidate(title: $0.title, aliases: $0.aliases) })
                if let best = ranked.first, best.score >= 0.5, (ranked.dropFirst().first?.score ?? 0) <= best.score - 0.2 {
                    return (.app(apps[best.index], text, newChat: true), log + "; new chat in \(apps[best.index].title)")
                }
            }
            return (.newChat(name.isEmpty ? nil : name, text), log)
        case .send(let i, let byFocus):
            guard hasText else { return noText }
            var t = targets[i]; t.byFocus = byFocus
            return (.send(t, text), log)
        case .ask(let idx, let heard):
            guard hasText else { return noText }
            return (.choose(idx.map { targets[$0] }, text, heardName: heard), log)
        }
    }

    /// A heard name that is a project folder under ~/Projects ("needs-you: ..." with no
    /// such chat open starts a chat there).
    static func isProject(_ name: String) -> Bool {
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
        guard ChatApps.isEnabled(ChatAppSwitches.muxID(.herdr)) else {
            throw DeliveryError.failed("herdr is turned off in Settings, Apps.") // HM-1415
        }
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
                var t = ChatTarget(kind: .herdrAgent, id: pane, title: label, aliases: [], focused: focus, fresh: true)
                t.app = ChatAppSwitches.muxID(.herdr)
                return t
            } catch { lastError = error.localizedDescription }
        }
        throw DeliveryError.failed("Claude did not start in the new tab: \(lastError.prefix(160))")
    }

    /// Opens a new chat in a chat app (HM-1383): starts the app if needed, picks its
    /// "New Chat" menu item (Cmd+N when it has none), and waits until the page is an
    /// empty new chat. Throws when that never shows, so nothing is typed into an old chat.
    @MainActor static func startAppChat(_ app: ChatApp) async throws -> ChatTarget {
        guard ChatApps.isEnabled(app.bundle) else { throw DeliveryError.failed("\(app.title) is turned off in Settings, Apps.") } // HM-1415
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
                var t = ChatTarget(kind: .desktop, id: app.bundle, title: app.title, aliases: app.aliases, focused: true, fresh: true)
                t.app = app.bundle
                return t
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

    /// Picks one of the offered chats from a spoken answer ("the second one", "garden planner").
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
        if target.kind == .desktop {
            // A chat app: it must still run. A chat in its list shares its id (the bundle), so
            // titles are not compared here; opening the chat checks it is there (HM-1397).
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: target.id).first != nil
            if !running { throw DeliveryError.failed("\(target.title) is not running, so nothing was sent.") }
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
        if case .queue(let why) = ChatInfo.typing(c.state) { return .queued(why) }
        // Messages that waited (e.g. a typing check failed earlier) go in first, in the same prompt.
        let earlier = reg.queued(id)
        let all = (earlier + [text]).joined(separator: "\n\n")
        switch await AXDelivery.send(dryRun ? text : all, to: axTarget(c), dryRun: dryRun) {
        case .typed(let app):
            if !dryRun {
                if !earlier.isEmpty { _ = reg.takeInbox(id, how: "typing with a new message") }
                reg.typedInto(id, ifUnchangedSince: c.lastActivity); reg.spokeTo(id)
            }
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

    /// Runs a short command. Its output is read while it runs: read only at exit, a reply
    /// bigger than the pipe (64 KB) would block it and this would never return (HM-1418).
    /// A command still running after `timeout` seconds is stopped.
    static func run(_ args: [String], checkExit: Bool = false, env extra: [String: String] = [:], timeout: Double = 15) async throws -> String {
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
            do { try p.run() } catch { cont.resume(throwing: error); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { Isolation.note("run: \((args[0] as NSString).lastPathComponent) \(args.dropFirst().prefix(2).joined(separator: " ")) still running after \(Int(timeout)) s, stopped"); p.terminate() }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                if checkExit && p.terminationStatus != 0 {
                    cont.resume(throwing: DeliveryError.failed("herdr failed: \(out.prefix(200))"))
                } else {
                    cont.resume(returning: out)
                }
            }
        }
    }
}
