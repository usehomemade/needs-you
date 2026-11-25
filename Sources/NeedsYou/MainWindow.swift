import AppKit
import NeedsYouShared
import SwiftUI

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
                if let c = ChatRegistry.shared.chats[nav.chat ?? ""] {
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
                    ForEach(projects, id: \.self) { p in
                        Label(p, systemImage: "folder").tag(Nav.Section.project(p))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus() }
    }

    /// The ten chats and projects heard from most recently.
    private var projects: [String] {
        var seen = Set<String>(), out: [String] = []
        for c in conductor.history where c.kind != "voicemail" && seen.insert(c.source).inserted { out.append(c.source) }
        return Array(out.prefix(10))
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
        if chats.isEmpty {
            ContentUnavailableView(search.isEmpty ? "No Chats Connected" : "No Results",
                                   systemImage: "terminal",
                                   description: Text(search.isEmpty ? "Turn on an agent in Settings \u{2192} Agents \u{2192} Reach by Voice. New chats show up here." : ""))
        } else {
            List(chats, id: \.id, selection: $nav.chat) { c in
                ChatRow(chat: c, queued: registry.queuedCount(c.id)).tag(c.id)
            }
        }
    }
}

struct ChatRow: View {
    let chat: ChatInfo
    let queued: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(chat.displayName).font(.headline).lineLimit(1)
                Spacer()
                Text(chat.lastActivity, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Text(ChatDetail.stateLine(chat, queued: queued)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if let p = chat.prompts.last { Text(p).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(.vertical, 3)
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

    var body: some View {
        Form {
            Section {
                LabeledContent("Agent", value: chat.agentName)
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
        if let project, c.source != project { return false }
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(convo.title).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Text(convo.startedAt, format: .dateTime.hour().minute())
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(snippet).lineLimit(2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(convo.source)
                Text("·")
                Text(live ? "Now" : convo.outcomeText).foregroundStyle(outcomeColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
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
