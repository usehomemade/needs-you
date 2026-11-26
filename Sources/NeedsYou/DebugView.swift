import AppKit
import ApplicationServices
import NeedsYouShared
import SwiftUI

// MARK: - Debug window (HM-1389)

/// Window > Router Debug (⌥⌘D): every place a voice message can reach, and a playground that
/// runs the real router on typed text. Nothing is sent from here.
/// Local builds only (26 Nov): a release build (it has an update feed) shows neither
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
                if !AXIsProcessTrusted() {
                    Button("Open Accessibility Settings\u{2026}") { PermissionSettings.open(.accessibility) }
                }
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
    /// Closest chats by meaning (top 5) and the votes of earlier matches (HM-1408).
    var meaning: [(String, Double)] = []
    var learned: [(String, Double, String)] = []
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
            Text("Runs the same router as a spoken command (on-device model, meaning, learned matches, names and topic words) over the targets open right now. Nothing is sent.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(trials) { t in
                    Section {
                        LabeledContent("Result") { Text(t.outcome).fontWeight(.semibold).textSelection(.enabled) }
                        if let m = t.message { LabeledContent("Message") { Text(m).textSelection(.enabled) } }
                        ForEach(Array(t.steps.enumerated()), id: \.offset) { _, s in
                            LabeledContent(s.0) { Text(s.1).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        if !t.meaning.isEmpty {
                            DisclosureGroup("Meaning (top 5)", isExpanded: .constant(true)) {
                                ForEach(Array(t.meaning.enumerated()), id: \.offset) { _, r in
                                    LabeledContent(r.0) { Text(String(format: "%.2f", r.1)).monospacedDigit().foregroundStyle(.secondary) }
                                }
                            }
                        }
                        DisclosureGroup("Learned votes (\(t.learned.count))") {
                            if t.learned.isEmpty { Text("No earlier message like this one went to an open chat.").foregroundStyle(.secondary) }
                            ForEach(Array(t.learned.enumerated()), id: \.offset) { _, r in
                                LabeledContent(r.0) { Text(String(format: "%.2f \u{00B7} %@", r.1, r.2)).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
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
        guard Wake.afterWakeWord(transcript) != nil else {
            return RouteTrial(text: input, outcome: "No wake phrase", message: nil, steps: [], ranked: [], ms: 0)
        }
        let targets = await Router.voiceTargets()
        let candidates = targets.map(\.candidate)
        var steps: [(String, String)] = [("Targets", "\(targets.count): " + targets.prefix(12).enumerated().map { "\($0.offset + 1) \($0.element.title)" }.joined(separator: ", "))]
        let tm = Date()
        let (parsed, log) = await Router.parseSmart(transcript, targets: targets)
        let ms = Int(Date().timeIntervalSince(tm) * 1000)
        let reading = Router.lastReading
        if let m = reading?.intent {
            let chat = m.chat.map { "\($0 + 1) \(targets[$0].title)" } ?? "no chat"
            var named = m.named.isEmpty ? "" : " \u{00B7} named \u{201C}\(m.named)\u{201D}"
            if let raw = reading?.rawNamed, !raw.isEmpty, m.named.isEmpty { named = " \u{00B7} named \u{201C}\(raw)\u{201D} ignored (not his words)" }
            steps.append(("Model", "\(m.action.rawValue) \u{00B7} \(chat)\(named)\(m.meansFront ? " \u{00B7} the chat in front" : "") \u{00B7} \u{201C}\(m.message)\u{201D}"))
        } else {
            steps.append(("Model", ModelRouter.available ? "no answer" : "not available"))
        }
        if let ev = reading?.evidence {
            let lead = ev.meaningVeryClear.map { "very clear: \($0 + 1)" } ?? ev.meaningLead.map { "leads: \($0 + 1)" } ?? "no clear lead"
            steps.append(("Meaning", (MeaningIndex.shared.available ? "" : "no sentence model; ") + lead + " (\(reading?.lang ?? "-"))"))
            steps.append(("Topic", ev.topic.map { "\($0 + 1) \(targets[$0].title)\(ev.clearTopic == $0 ? " (clear)" : "")" } ?? "none (no chat clearly shares its rare words)"))
            steps.append(("Learned", ev.learnedVeryClear.map { "very clear: \($0 + 1)" } ?? ev.learnedLead.map { "leads: \($0 + 1)" } ?? (ev.learned.isEmpty ? "no earlier match like it" : "no clear lead")))
        }
        steps.append(("Route log", log + " \u{00B7} \(ms) ms"))
        let outcome: String, message: String?
        switch parsed {
        case .send(let t, let m): outcome = "Send to \(t.title)"; message = m
        case .choose(let o, let m, let h):
            outcome = o.isEmpty ? "Not sent: \(h.isEmpty ? "no chat to offer" : "no chat called \u{201C}\(h)\u{201D}")" : "Ask which chat: " + o.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "  ")
            message = m
        case .nothing(let why): outcome = "Not sent: \(why)"; message = nil
        case .newChat(let p, let m): outcome = "New chat in \(p ?? "your home folder") (herdr)"; message = m
        case .app(let a, let m, let fresh): outcome = fresh ? "New chat in \(a.title)" : "Type into \(a.title)"; message = m
        case .presence(let p): outcome = "Voice command: \(p)"; message = nil
        }
        let named = reading?.intent?.named ?? ""
        let ranked = named.isEmpty ? [] : ChatMatcher.rank(named, candidates).prefix(5).filter { $0.score > 0 }.map { (targets[$0.index].title, $0.score, $0.field) }
        let meaning = (reading?.evidence.meaning ?? []).prefix(5).map { ("\($0.index + 1) \(targets[$0.index].title)", $0.sim) }
        let learned = (reading?.votes ?? []).prefix(5).map { ("\($0.index + 1) \(targets[$0.index].title)", $0.vote.weight, "\($0.vote.count) earlier, closest \u{201C}\($0.vote.example)\u{201D} \(String(format: "%.2f", $0.vote.bestSim))") }
        return RouteTrial(text: input, outcome: outcome, message: message, steps: steps, ranked: Array(ranked),
                          meaning: Array(meaning), learned: Array(learned), ms: Int(Date().timeIntervalSince(t0) * 1000))
    }
}
