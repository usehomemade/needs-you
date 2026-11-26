import AppKit
import NeedsYouShared
import SwiftUI

// MARK: - Agent icons (HM-1384)

/// The app whose icon stands for an agent: Claude Code and the Claude app show Claude's,
/// Codex and ChatGPT the ChatGPT app's, Cursor its own.
enum AgentApp {
    static func bundle(_ agent: String?) -> String? {
        switch agent {
        case "claude", "claude-app": return Router.desktopBundleID
        case "codex", "chatgpt": return "com.openai.codex"
        case "cursor": return "com.todesktop.230313mzl4w4u92"
        default: return nil
        }
    }

    static func name(_ agent: String?) -> String? {
        switch agent {
        case "claude": return "Claude Code"
        case "claude-app": return "Claude app"
        case "codex": return "Codex"
        case "chatgpt": return "ChatGPT"
        case "cursor": return "Cursor"
        default: return nil
        }
    }

    static func icon(bundle: String?) -> NSImage? {
        guard let b = bundle else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: b).first, let i = running.icon { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// An agent's app icon at list size; a symbol on a quiet tile when no app stands for it.
/// `badge`: the app showing the chat (Ghostty, Terminal, Cursor), small in the corner.
struct AgentAvatar: View {
    var image: NSImage?
    var symbol: String
    var badge: NSImage? = nil
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(.quaternary)
                    .overlay(Image(systemName: symbol).font(.system(size: size * 0.45)).foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Image(nsImage: badge).resizable().frame(width: size * 0.55, height: size * 0.55)
                    .offset(x: size * 0.15, y: size * 0.15)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Main window (HM-1356)

/// Sidebar (Conversations, Voicemails, one row per project), a list, and the
/// selected item, like Mail or Voice Memos.
struct MainView: View {
    @EnvironmentObject var conductor: Conductor
    @ObservedObject private var nav = Nav.shared
    @ObservedObject private var dnd = DoNotDisturb.shared
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } content: {
            Group {
                switch nav.section ?? .conversations {
                case .voicemails: VoicemailList(search: search)
                case .chats: ChatList(search: search)
                case .conversations: ConversationList(project: nil, search: search)
                case .project(let p): ConversationList(project: p, search: search)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 480)
        } detail: {
            switch nav.section ?? .conversations {
            case .voicemails:
                if let v = dnd.voicemails.first(where: { $0.id == nav.voicemail }) {
                    VoicemailDetail(voicemail: v)
                } else {
                    ContentUnavailableView("No Voicemail Selected", systemImage: "recordingtape")
                }
            case .chats:
                if let id = nav.chat, id.hasPrefix("app:"), let app = Router.installedApps().first(where: { "app:" + $0.bundle == id }) {
                    ChatAppDetail(app: app)
                } else if let c = ChatRegistry.shared.chats[nav.chat ?? ""] {
                    ChatDetail(chat: c)
                } else {
                    ContentUnavailableView("No Chat Selected", systemImage: "terminal")
                }
            default:
                if let c = conductor.current?.id == nav.conversation ? conductor.current : conductor.history.first(where: { $0.id == nav.conversation }) {
                    ConversationDetail(convo: c)
                } else {
                    ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: searchPrompt)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { UpdateButton().buttonStyle(.borderedProminent) }
        }
        .onAppear { Nav.openWindowAction = openWindow }
    }

    private var searchPrompt: String {
        if case .voicemails = nav.section { return "Search Voicemails" }
        if case .chats = nav.section { return "Search Chats" }
        return "Search Conversations"
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @EnvironmentObject var conductor: Conductor
    @ObservedObject private var registry = ChatRegistry.shared
    @ObservedObject private var nav = Nav.shared
    @ObservedObject private var dnd = DoNotDisturb.shared

    var body: some View {
        List(selection: $nav.section) {
            Section {
                Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                    .tag(Nav.Section.conversations)
                Label("Voicemails", systemImage: "recordingtape")
                    .badge(dnd.unheard.count)
                    .tag(Nav.Section.voicemails)
                Label("Chats", systemImage: "terminal")
                    .badge(registry.reachable.count)
                    .tag(Nav.Section.chats)
            }
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects, id: \.name) { p in
                        Label(p.name, systemImage: "folder")
                            .badge(p.count)
                            .tag(Nav.Section.project(p.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus() }
    }

    /// The ten project folders heard from most recently, with how many conversations each has.
    /// Only real folders: a chat's title or the home folder is never a project (HM-1384).
    private var projects: [(name: String, count: Int)] {
        var order: [String] = [], count: [String: Int] = [:], shown: [String: String] = [:]
        for c in conductor.history where c.kind != "voicemail" {
            guard let f = c.folder else { continue }
            let k = Conversation.folderKey(f)
            if count[k] == nil { order.append(k) }
            // The real folder name ("needs-you") wins over a --project label ("Needs You").
            if shown[k] == nil || c.cwd != nil && shown[k] != f && !(shown[k] ?? "").contains("-") { shown[k] = f }
            count[k, default: 0] += 1
        }
        return order.prefix(10).map { (shown[$0] ?? $0, count[$0] ?? 0) }
    }
}

/// What Needs You is doing, at the bottom of the sidebar (like Mail's activity).
struct SidebarStatus: View {
    @EnvironmentObject var conductor: Conductor
    @ObservedObject private var dnd = DoNotDisturb.shared
    @ObservedObject private var voice = VoiceCommands.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: MenuStatus.symbol)
                    .foregroundStyle(dnd.on ? Color.indigo : Color.secondary)
                    .frame(width: 16)
                Text(MenuStatus.line())
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.callout)
            if conductor.phase == .listening {
                LevelMeter(level: conductor.level, active: conductor.hearingSpeech)
            }
            if conductor.queued > 0 {
                Text("\(conductor.queued) more waiting").font(.caption).foregroundStyle(.secondary)
            }
            if dnd.on {
                Button("Turn Off Do Not Disturb") { dnd.set(false) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: Chats (HM-1364)

/// The chats connected through the Needs You MCP server: the ones voice can reach.
struct ChatList: View {
    let search: String
    @ObservedObject private var registry = ChatRegistry.shared
    @ObservedObject private var nav = Nav.shared

    var body: some View {
        let chats = registry.reachable.filter { c in
            search.isEmpty || [c.displayName, c.agentName, c.summary, c.cwd].contains { $0.localizedCaseInsensitiveContains(search) }
        }
        let apps = Router.installedApps().filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        List(selection: $nav.chat) {
            Section("Connected Chats") {
                ForEach(chats, id: \.id) { c in
                    ChatRow(chat: c, queued: registry.queuedCount(c.id)).tag(c.id)
                        .contextMenu { Button("Show Chat") { Task { await Router.reveal(c) } } }
                }
                if chats.isEmpty {
                    Text(search.isEmpty ? "None yet. Turn on an agent in Settings \u{2192} Agents; new chats show up here." : "No results")
                        .foregroundStyle(.secondary)
                }
            }
            if !apps.isEmpty {
                Section("Chat Apps") {
                    ForEach(apps, id: \.bundle) { a in
                        ChatAppRow(app: a).tag("app:" + a.bundle)
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .navigationSubtitle(chats.isEmpty ? "" : "\(chats.count) connected")
    }
}

struct ChatRow: View {
    let chat: ChatInfo
    let queued: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(image: AgentApp.icon(bundle: AgentApp.bundle(chat.agent)), symbol: "terminal",
                        badge: ChatDetail.host(chat)?.icon)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.displayName).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(chat.lastActivity, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                Text(ChatDetail.stateLine(chat, queued: queued)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let p = chat.prompts.last { Text(p).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            Button { Task { await Router.reveal(chat) } } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .help("Show Chat")
                .accessibilityLabel("Show Chat")
        }
        .padding(.vertical, 3)
    }
}

/// A chat app (Claude, ChatGPT) in the Chats list: reached by name, opened from here.
struct ChatAppRow: View {
    let app: Router.ChatApp

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(image: AgentApp.icon(bundle: app.bundle), symbol: "app")
            VStack(alignment: .leading, spacing: 2) {
                Text(app.title).font(.headline)
                Text(ChatAppDetail.stateLine(app)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { ChatAppDetail.open(app) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .help("Open \(app.title)")
                .accessibilityLabel("Open \(app.title)")
        }
        .padding(.vertical, 3)
    }
}

struct ChatAppDetail: View {
    let app: Router.ChatApp

    static func running(_ app: Router.ChatApp) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundle).first
    }

    static func stateLine(_ app: Router.ChatApp) -> String {
        (running(app) == nil ? "Not running" : "Running") + " \u{00B7} " + (Router.appHasNeedsYou(app.bundle) ? "answers out loud" : "typed into, answers on screen")
    }

    static func open(_ app: Router.ChatApp) {
        if let r = running(app) { r.activate(options: [.activateAllWindows]); return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AgentAvatar(image: AgentApp.icon(bundle: app.bundle), symbol: "app", size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.title).font(.title2.weight(.semibold))
                        Text(Self.stateLine(app)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Say", value: "\u{201C}\(Wake.phrase), use \(app.title) to ask \u{2026}\u{201D}")
                LabeledContent("Or", value: "\u{201C}\(Wake.phrase), \(app.title): \u{2026}\u{201D} for the chat open there")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(app.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Self.open(app) } label: { Label("Open \(app.title)", systemImage: "arrow.up.forward.app") }
                    .help("Open \(app.title)")
            }
        }
    }
}

struct ChatDetail: View {
    let chat: ChatInfo
    @ObservedObject private var registry = ChatRegistry.shared

    static func stateLine(_ c: ChatInfo, queued: Int) -> String {
        var s = c.agentName
        switch c.state {
        case .working: s += " \u{00B7} working"
        case .waiting: s += " \u{00B7} waiting for you"
        case .idle: s += " \u{00B7} idle"
        case .unknown: break
        }
        if queued > 0 { s += " \u{00B7} \(queued) queued" }
        return s
    }

    /// The app that shows the chat (the terminal, or Cursor).
    static func host(_ c: ChatInfo) -> NSRunningApplication? { AXDelivery.guiApp(c.agentPid) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AgentAvatar(image: AgentApp.icon(bundle: AgentApp.bundle(chat.agent)), symbol: "terminal",
                                badge: Self.host(chat)?.icon, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.displayName).font(.title2.weight(.semibold)).lineLimit(2)
                        Text(Self.stateLine(chat, queued: registry.queuedCount(chat.id))).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Agent", value: chat.agentName)
                if let h = Self.host(chat) { LabeledContent("Shown in", value: h.localizedName ?? "") }
                LabeledContent("Folder", value: chat.cwd.isEmpty ? "Unknown" : (chat.cwd as NSString).abbreviatingWithTildeInPath)
                LabeledContent("State", value: Self.stateLine(chat, queued: 0))
                LabeledContent("Connected", value: chat.hasHooks ? "MCP and hooks" : "MCP")
                if let s = chat.status, !s.isEmpty { LabeledContent("Status", value: s) }
            }
            let q = registry.queued(chat.id)
            if !q.isEmpty {
                Section("Waiting for its next tool call or turn end") {
                    ForEach(Array(q.enumerated()), id: \.offset) { Text($0.element) }
                }
            }
            if !chat.prompts.isEmpty {
                Section("Recent prompts") {
                    ForEach(Array(chat.prompts.reversed().enumerated()), id: \.offset) { Text($0.element).lineLimit(4) }
                }
            }
            if let r = chat.lastReply, !r.isEmpty {
                Section("Last reply") { Text(r).lineLimit(8) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(chat.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await Router.reveal(chat) } } label: { Label("Show Chat", systemImage: "arrow.up.forward.app") }
                    .help("Bring this chat's window to the front")
            }
        }
    }
}

// MARK: Conversations

struct ConversationList: View {
    @EnvironmentObject var conductor: Conductor
    @ObservedObject private var nav = Nav.shared
    var project: String?
    var search: String

    var body: some View {
        let items = filtered
        List(selection: $nav.conversation) {
            if let c = conductor.current, matches(c) {
                Section("Now") { ConversationRow(convo: c, live: true).tag(c.id) }
            }
            ForEach(Self.byDay(items.filter { $0.id != conductor.current?.id }), id: \.0) { day, list in
                Section(day) {
                    ForEach(list) { c in
                        ConversationRow(convo: c).tag(c.id)
                            .contextMenu { ConversationActions(convo: c) }
                    }
                }
            }
        }
        .overlay {
            if items.isEmpty && conductor.current == nil {
                if search.isEmpty {
                    ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("When an agent asks you something, or you talk to a chat, it shows up here."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .navigationTitle(project ?? "Conversations")
        .navigationSubtitle(items.isEmpty ? "" : "\(items.count) conversation\(items.count == 1 ? "" : "s")")
        .onDeleteCommand { if let id = nav.conversation { conductor.deleteHistory(ids: [id]) } }
    }

    private var filtered: [Conversation] {
        conductor.history.filter(matches)
    }

    private func matches(_ c: Conversation) -> Bool {
        if let project, c.folder.map(Conversation.folderKey) != Conversation.folderKey(project) { return false }
        if project == nil, c.kind == "voicemail" { return false } // the Voicemails list has those
        guard !search.isEmpty else { return true }
        let q = search
        return c.title.localizedCaseInsensitiveContains(q) || c.message.localizedCaseInsensitiveContains(q)
            || c.source.localizedCaseInsensitiveContains(q) || c.turns.contains { $0.text.localizedCaseInsensitiveContains(q) }
    }

    /// Today, Yesterday, then dates, newest first.
    static func byDay(_ list: [Conversation]) -> [(String, [Conversation])] {
        var out: [(String, [Conversation])] = []
        let cal = Calendar.current
        for c in list.sorted(by: { $0.startedAt > $1.startedAt }) {
            let day: String
            if cal.isDateInToday(c.startedAt) { day = "Today" }
            else if cal.isDateInYesterday(c.startedAt) { day = "Yesterday" }
            else { day = c.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            if out.last?.0 == day { out[out.count - 1].1.append(c) } else { out.append((day, [c])) }
        }
        return out
    }
}

struct ConversationRow: View {
    var convo: Conversation
    var live = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(image: AgentApp.icon(bundle: AgentApp.bundle(convo.agent)),
                        symbol: convo.kind == "send" ? "waveform" : "bubble.left")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(convo.sender).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(convo.startedAt, format: .dateTime.hour().minute())
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let t = distinctTitle {
                    Text(t).font(.subheadline.weight(.medium)).lineLimit(1)
                }
                Text(snippet).lineLimit(2).foregroundStyle(.secondary)
                Text(live ? "Now" : convo.outcomeText)
                    .font(.caption)
                    .foregroundStyle(outcomeColor)
            }
        }
        .padding(.vertical, 3)
    }

    /// The title, only when it says something the sender and the preview don't (HM-1384):
    /// most titles are the message's first words, cut off.
    private var distinctTitle: String? {
        let squash: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        var t = convo.title.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("\u{2026}") || t.hasSuffix(".") { t.removeLast() }
        let st = squash(t), body = squash(snippet.replacingOccurrences(of: "You: ", with: "")), who = squash(convo.sender)
        if st.isEmpty || st == "heyclaude" || st == who || st == "to" + who { return nil }
        if convo.kind == "send", t.hasPrefix("To ") { return nil }
        if body.hasPrefix(st) || st.hasPrefix(body) { return nil }
        if squash(convo.message).hasPrefix(st) && body.hasPrefix(squash(convo.message).prefix(20)) { return nil }
        return convo.title
    }

    private var snippet: String {
        let last = convo.turns.last(where: { $0.role == .user }) ?? convo.turns.first
        return last.map { ($0.role == .user ? "You: " : "") + $0.text } ?? convo.message
    }

    private var outcomeColor: Color {
        switch convo.outcome {
        case .noAnswer: return .orange
        case .error: return .red
        default: return .secondary
        }
    }
}

struct ConversationActions: View {
    @EnvironmentObject var conductor: Conductor
    var convo: Conversation

    var body: some View {
        Button("Copy Transcript") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(convo.transcriptText, forType: .string)
        }
        if let cwd = convo.cwd {
            Button("Show Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) }
        }
        if let url = convo.artifactURL, let u = URL(string: url) {
            Button("Open Artifact") { NSWorkspace.shared.open(u) }
        }
        Divider()
        Button("Delete", role: .destructive) { conductor.deleteHistory(ids: [convo.id]) }
            .disabled(convo.id == conductor.current?.id)
    }
}

struct ConversationDetail: View {
    @EnvironmentObject var conductor: Conductor
    var convo: Conversation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(convo.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text("\(convo.source) · \(convo.kindText) · \(convo.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(convo.outcomeText)")
                        .foregroundStyle(.secondary)
                }
                if let e = convo.error {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(convo.turns.enumerated()), id: \.offset) { _, turn in
                        TurnView(turn: turn, agentName: convo.source)
                    }
                    if convo.turns.isEmpty { Text(convo.message).textSelection(.enabled) }
                }
                if let ctx = convo.context, !ctx.isEmpty {
                    GroupBox("Details") {
                        Text(ctx)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
                if let cwd = convo.cwd {
                    Text(cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            if let url = convo.artifactURL, let u = URL(string: url) {
                ToolbarItem { Link(destination: u) { Label("Open Artifact", systemImage: "safari") }.help("Open Artifact") }
            }
            if let cwd = convo.cwd {
                ToolbarItem {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) } label: {
                        Label("Show Folder in Finder", systemImage: "folder")
                    }
                    .help("Show Folder in Finder")
                }
            }
            ToolbarItem {
                Button { conductor.deleteHistory(ids: [convo.id]) } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete Conversation")
                    .disabled(convo.id == conductor.current?.id)
            }
        }
    }
}

struct TurnView: View {
    var turn: Turn
    var agentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(turn.role == .agent ? agentName : "You").fontWeight(.semibold)
                    .foregroundStyle(turn.role == .agent ? Color.primary : Color.accentColor)
                Text(turn.at, format: .dateTime.hour().minute()).foregroundStyle(.tertiary)
            }
            .font(.callout)
            Text(turn.text).textSelection(.enabled)
            if let original = turn.original {
                DisclosureGroup("As Heard") {
                    Text(original).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }
}

// MARK: Voicemails

struct VoicemailList: View {
    @EnvironmentObject var conductor: Conductor
    @ObservedObject private var nav = Nav.shared
    @ObservedObject private var dnd = DoNotDisturb.shared
    var search: String

    var body: some View {
        let all = dnd.voicemails.filter(matches)
        let unheard = all.filter { !$0.heard }.sorted { $0.at < $1.at }
        let heard = all.filter(\.heard).sorted { $0.at > $1.at }
        List(selection: $nav.voicemail) {
            if !unheard.isEmpty {
                Section("Unheard") { ForEach(unheard) { row($0) } }
            }
            if !heard.isEmpty {
                Section("Heard") { ForEach(heard) { row($0) } }
            }
        }
        .overlay {
            if all.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No Voicemails", systemImage: "recordingtape",
                                           description: Text("When you don't answer, or Do Not Disturb is on, what an agent wanted to say is kept here."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .navigationTitle("Voicemails")
        .navigationSubtitle(unheard.isEmpty ? "" : "\(unheard.count) unheard")
        .toolbar {
            ToolbarItem {
                Button { Task { await conductor.playVoicemails(greeting: nil, summary: false) } } label: {
                    Label("Play Unheard", systemImage: "play.fill")
                }
                .help("Play Unheard Voicemails")
                .disabled(dnd.unheard.isEmpty || conductor.busy)
            }
            ToolbarItem {
                Button { dnd.clearHeard() } label: { Label("Clear Heard", systemImage: "trash") }
                    .help("Delete Heard Voicemails")
                    .disabled(!dnd.voicemails.contains { $0.heard })
            }
        }
        .onDeleteCommand { if let id = nav.voicemail { dnd.remove(ids: [id]) } }
    }

    private func row(_ v: Voicemail) -> some View {
        VoicemailRow(voicemail: v).tag(v.id)
            .contextMenu { VoicemailActions(voicemail: v) }
    }

    private func matches(_ v: Voicemail) -> Bool {
        guard !search.isEmpty else { return true }
        return v.text.localizedCaseInsensitiveContains(search) || v.source.localizedCaseInsensitiveContains(search)
            || (v.title ?? "").localizedCaseInsensitiveContains(search)
    }
}

struct VoicemailRow: View {
    var voicemail: Voicemail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Unheard dot, as in Mail.
            Circle().fill(voicemail.heard ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(voicemail.title ?? voicemail.source).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Self.time(voicemail.at)).font(.callout).foregroundStyle(.secondary)
                }
                Text(voicemail.text).lineLimit(2).foregroundStyle(.secondary)
                Text(voicemail.answer.map { "\(voicemail.source) · Answered: \($0)" } ?? voicemail.source)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    static func time(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

struct VoicemailActions: View {
    @EnvironmentObject var conductor: Conductor
    @ObservedObject private var dnd = DoNotDisturb.shared
    var voicemail: Voicemail

    var body: some View {
        Button("Play") { Task { await conductor.playVoicemails(greeting: nil, summary: false, only: [voicemail.id]) } }
            .disabled(conductor.busy)
        Button(voicemail.heard ? "Mark as Unheard" : "Mark as Heard") {
            var v = voicemail; v.heard.toggle(); dnd.update(v)
        }
        Divider()
        Button("Delete", role: .destructive) { dnd.remove(ids: [voicemail.id]) }
    }
}

struct VoicemailDetail: View {
    @EnvironmentObject var conductor: Conductor
    @ObservedObject private var dnd = DoNotDisturb.shared
    var voicemail: Voicemail
    @State private var answer = ""
    @State private var sending = false
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(voicemail.title ?? "From \(voicemail.source)").font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text("\(voicemail.source) · \(kind) · \(voicemail.at.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                Text(voicemail.text).textSelection(.enabled)
                if let a = voicemail.answer {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("You").fontWeight(.semibold).foregroundStyle(Color.accentColor).font(.callout)
                        Text(a).textSelection(.enabled)
                    }
                }
                if let ctx = voicemail.context, !ctx.isEmpty {
                    GroupBox("Details") {
                        Text(ctx).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Type your answer to \(voicemail.source)", text: $answer, axis: .vertical)
                            .lineLimit(2...6)
                            .textFieldStyle(.plain)
                            .onSubmit(send)
                        HStack {
                            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Send", action: send)
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                        }
                    }
                    .padding(4)
                }
                Text("The answer is typed into the chat the voicemail came from.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await conductor.playVoicemails(greeting: nil, summary: false, only: [voicemail.id]) } } label: {
                    Label("Play", systemImage: "play")
                }
                .help("Play this voicemail, then listen for your answer")
                .disabled(conductor.busy)
            }
            ToolbarItem {
                Button { var v = voicemail; v.heard.toggle(); dnd.update(v) } label: {
                    Label(voicemail.heard ? "Mark as Unheard" : "Mark as Heard", systemImage: voicemail.heard ? "envelope.badge" : "envelope.open")
                }
                .help(voicemail.heard ? "Mark as Unheard" : "Mark as Heard")
            }
            ToolbarItem {
                Button { dnd.remove(ids: [voicemail.id]) } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete Voicemail")
            }
        }
        .onChange(of: voicemail.id) { _, _ in answer = ""; note = nil }
    }

    private var kind: String {
        switch voicemail.kind {
        case .ask: return "Question"
        case .say: return "Message"
        case .noAnswer: return "Not answered"
        }
    }

    private func send() {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            if let why = await Conductor.deliverAnswer(voicemail, text) {
                note = "Not sent: \(why)"
            } else {
                var v = voicemail
                v.answer = text
                v.heard = true
                dnd.update(v)
                answer = ""
                note = "Sent to \(voicemail.source)."
            }
        }
    }
}
