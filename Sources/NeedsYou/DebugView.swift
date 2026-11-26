import AppKit
import ApplicationServices
import NeedsYouShared
import SwiftUI

// MARK: - Debug window (HM-1389)

/// Window > Router Debug (⌥⌘D): every place a voice message can reach, and a playground that
/// runs the real router on typed text. Nothing is sent from here.
/// Local builds only (the owner, 26 Nov): a release build (it has an update feed) shows neither
/// the menu item nor the window.
struct DebugView: View {
    /// Builds from scripts/install.sh or swift build; never a published release.
    static var available: Bool { !Updates.configured }

    var body: some View {
        if Self.available { tabs } else { Text("Router Debug is only in local builds.").padding() }
    }

    private var tabs: some View {
        TabView {
            TargetsDebug().tabItem { Label("Targets", systemImage: "list.bullet.rectangle") }
            RouterDebug().tabItem { Label("Router", systemImage: "arrow.triangle.branch") }
        }
        .padding(.top, 4)
        .frame(minWidth: 720, minHeight: 520)
    }
}

// MARK: Targets

struct TargetsDebug: View {
    @ObservedObject private var registry = ChatRegistry.shared
    @State private var targets: [ChatTarget] = []
    @State private var loading = false
    @State private var at = Date()

    var body: some View {
        let connected = targets.filter { $0.kind == .registered }
        let herdr = targets.filter { $0.kind == .herdrAgent || $0.kind == .herdrPane }
        let apps = Router.installedApps()
        List {
            Section("Status") {
                LabeledContent("Accessibility", value: AXIsProcessTrusted() ? "Allowed" : "Not allowed: nothing can be typed")
                LabeledContent("On-device model", value: ModelRouter.available ? "Available" : "Not available: the matcher routes alone")
                LabeledContent("Router targets", value: "\(targets.count), read \(at.formatted(date: .omitted, time: .standard))")
            }
            Section("Connected chats (\(connected.count))") {
                if connected.isEmpty { Text("None. Turn on an agent in Settings, Agents.").foregroundStyle(.secondary) }
                ForEach(connected, id: \.id) { t in
                    TargetDebugRow(target: t, index: targets.firstIndex(of: t), chat: registry.chats[t.id])
                }
            }
            Section("herdr chats, not connected (\(herdr.count))") {
                if herdr.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(herdr, id: \.id) { t in TargetDebugRow(target: t, index: targets.firstIndex(of: t), chat: nil) }
            }
            Section("Chat apps and their sidebar chats (\(targets.filter { $0.kind == .desktop }.count))") {
                ForEach(targets.filter { $0.kind == .desktop }, id: \.key) { t in
                    TargetDebugRow(target: t, index: targets.firstIndex(of: t), chat: nil)
                }
            }
            Section("Chat apps installed") {
                ForEach(apps, id: \.bundle) { a in
                    HStack(spacing: 10) {
                        AgentAvatar(image: AgentApp.icon(bundle: a.bundle), symbol: "app", size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).fontWeight(.semibold)
                            Text("\(a.bundle) \u{00B7} \(ChatAppDetail.running(a) == nil ? "not running (a new chat opens it)" : "running, a router target") \u{00B7} \(Router.appHasNeedsYou(a.bundle) ? "has the Needs You MCP server" : "no MCP server: typed into, answers on screen")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Names: " + a.aliases.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(loading)
                    .keyboardShortcut("r")
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        targets = await Router.voiceTargets()
        at = Date()
        loading = false
    }
}

struct TargetDebugRow: View {
    let target: ChatTarget
    let index: Int?
    let chat: ChatInfo?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index.map { "\($0 + 1)" } ?? "-").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
            AgentAvatar(image: AgentApp.icon(bundle: AgentApp.bundle(chat?.agent ?? (target.kind == .herdrAgent ? "claude" : nil))),
                        symbol: "terminal", badge: chat.flatMap(ChatDetail.host)?.icon, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(target.title).fontWeight(.semibold).lineLimit(1)
                    if target.focused { Text("used last").font(.caption).foregroundStyle(.orange) }
                }
                Text(fields).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !target.detail.isEmpty, target.detail != target.title {
                    Text("Works on: " + target.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let chat {
                Button { Task { await Router.reveal(chat) } } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).help("Show Chat")
            }
        }
        .padding(.vertical, 2)
    }

    private var fields: String {
        var p = [String]()
        p.append("id " + target.id)
        if !target.folder.isEmpty { p.append("folder " + target.folder) }
        if !target.label.isEmpty { p.append("tab " + target.label) }
        if let c = chat {
            p.append(c.agentName)
            p.append(c.state.rawValue)
            p.append(c.hasHooks ? "MCP + hooks" : "MCP only")
            if let pane = c.pane { p.append("\(pane.kind.rawValue) \(pane.id)") }
        }
        return p.joined(separator: " \u{00B7} ")
    }
}

// MARK: Router playground

/// One try: what each stage said, and what would happen.
struct RouteTrial: Identifiable {
    let id = UUID()
    var text: String
    var outcome: String
    var message: String?
    var steps: [(String, String)]
    var ranked: [(String, Double, String)]
    var ms: Int
}

struct RouterDebug: View {
    @State private var text = "\(Wake.phrase), "
    @State private var running = false
    @State private var trials: [RouteTrial] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("\(Wake.phrase), use ChatGPT to ask \u{2026}", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(run)
                Button("Route", action: run)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(running || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Runs the same router as a spoken command (matcher, on-device model, topic, routing memory) over the targets open right now. Nothing is sent.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(trials) { t in
                    Section {
                        LabeledContent("Result") { Text(t.outcome).fontWeight(.semibold).textSelection(.enabled) }
                        if let m = t.message { LabeledContent("Message") { Text(m).textSelection(.enabled) } }
                        ForEach(Array(t.steps.enumerated()), id: \.offset) { _, s in
                            LabeledContent(s.0) { Text(s.1).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        if !t.ranked.isEmpty {
                            DisclosureGroup("Name scores") {
                                ForEach(Array(t.ranked.enumerated()), id: \.offset) { _, r in
                                    LabeledContent(r.0) { Text(String(format: "%.2f %@", r.1, r.2)).monospacedDigit().foregroundStyle(.secondary) }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("\u{201C}\(t.text)\u{201D}").textCase(nil)
                            Spacer()
                            Text("\(t.ms) ms").monospacedDigit()
                        }
                    }
                }
            }
            .overlay {
                if trials.isEmpty {
                    ContentUnavailableView("Try a Command", systemImage: "arrow.triangle.branch",
                                           description: Text("For example \u{201C}\(Wake.phrase), how is the trip planning going\u{201D}."))
                }
            }
        }
        .padding()
        .onAppear { focused = true }
    }

    private func run() {
        let input = text.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty, !running else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            trials.insert(await Self.trial(input), at: 0)
        }
    }

    @MainActor static func trial(_ input: String) async -> RouteTrial {
        let t0 = Date()
        // Typed without the wake phrase: add it, as if he had said it.
        let transcript = Wake.afterWakeWord(input) == nil ? "\(Wake.phrase), \(input)" : input
        guard let rest = Wake.afterWakeWord(transcript) else {
            return RouteTrial(text: input, outcome: "No wake phrase", message: nil, steps: [], ranked: [], ms: 0)
        }
        if let p = PresenceCommand.parse(rest) {
            return RouteTrial(text: input, outcome: "Voice command: \(p)", message: nil, steps: [], ranked: [], ms: Int(Date().timeIntervalSince(t0) * 1000))
        }
        let targets = await Router.voiceTargets()
        let candidates = targets.map(\.candidate)
        var steps: [(String, String)] = [("Targets", "\(targets.count): " + targets.prefix(12).enumerated().map { "\($0.offset + 1) \($0.element.title)" }.joined(separator: ", "))]
        if let a = Router.appCommand(rest) {
            steps.append(("App command", a.1))
        }
        let (fast, fastLog) = ChatMatcher.route(rest, candidates)
        steps.append(("Matcher", describe(fast, targets) + " \u{2014} " + fastLog))
        if let i = ChatMatcher.topic(rest, candidates) { steps.append(("Topic", "\(i + 1) \(targets[i].title)")) } else { steps.append(("Topic", "none (no chat clearly shares its words)")) }
        let tm = Date()
        let model = await ModelRouter.shared.pick(rest, targets)
        let modelMs = Int(Date().timeIntervalSince(tm) * 1000)
        if let m = model {
            steps.append(("Model", "\(m.index + 1) \(targets[m.index].title)\(m.newChat ? ", new chat" : "") \u{00B7} \u{201C}\(m.message)\u{201D} \u{00B7} \(modelMs) ms"))
        } else {
            steps.append(("Model", ModelRouter.available ? "no pick (\(modelMs) ms)" : "not available"))
        }
        let words = RoutingMemory.words(rest: rest)
        if let key = RoutingMemoryStore.shared.lookup(words), let i = targets.firstIndex(where: { $0.memoryKey == key }) {
            steps.append(("Memory", "\u{201C}\(words)\u{201D} meant \(i + 1) \(targets[i].title) before"))
        }
        let (parsed, log) = await Router.parseSmart(transcript, targets: targets)
        steps.append(("Route log", log))
        let outcome: String, message: String?
        switch parsed {
        case .send(let t, let m): outcome = "Send to \(t.title)"; message = m
        case .choose(let o, let m, let h):
            outcome = o.isEmpty ? "Not sent: \(h.isEmpty ? "no chat to offer" : "no chat called \u{201C}\(h)\u{201D}")" : "Ask which chat: " + o.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "  ")
            message = m
        case .nothing(let why): outcome = "Not sent: \(why)"; message = nil
        case .newChat(let p, let m): outcome = "New chat in \(p ?? "your home folder") (herdr)"; message = m
        case .app(let a, let m, let fresh): outcome = fresh ? "New chat in \(a.title)" : "Type into \(a.title)"; message = m
        }
        var heard = rest
        if let colon = rest.firstIndex(of: ":") { heard = String(rest[..<colon]) }
        let ranked = ChatMatcher.rank(heard, candidates).prefix(5).filter { $0.score > 0 }.map { (targets[$0.index].title, $0.score, $0.field) }
        return RouteTrial(text: input, outcome: outcome, message: message, steps: steps, ranked: Array(ranked), ms: Int(Date().timeIntervalSince(t0) * 1000))
    }

    static func describe(_ r: ChatMatcher.Route, _ t: [ChatTarget]) -> String {
        switch r {
        case .named(let i, _): return "named \(i + 1) \(t[i].title)"
        case .front(let i, _): return i.map { "no name, used last is \($0 + 1) \(t[$0].title)" } ?? "no name"
        case .choose(let idx, _, let h): return "unsure about \u{201C}\(h)\u{201D}: " + idx.map { "\($0 + 1)" }.joined(separator: ", ")
        case .newChat(let p, _): return "new chat in \(p ?? "home folder")"
        }
    }
}
