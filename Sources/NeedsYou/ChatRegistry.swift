import Foundation
import NeedsYouShared

/// The chats Needs You can reach by voice (HM-1364): only agents that registered
/// through the Needs You MCP server or its hooks. Idle ones are typed into through
/// `AXDelivery` (HM-1374); the rest get their messages from the inbox.
@MainActor
final class ChatRegistry: ObservableObject {
    static let shared = ChatRegistry()

    @Published private(set) var chats: [String: ChatInfo] = [:]
    /// Voice messages waiting for a chat (busy, or typing it failed; HM-1374): handed over by its next hook (Stop,
    /// UserPromptSubmit, PostToolUse in the chat itself) or its `inbox` tool.
    struct Queued: Equatable { var text: String; var convoID: String? }
    @Published private(set) var inbox: [String: [Queued]] = [:]
    /// When the user last sent each chat something by voice.
    private(set) var lastSpokenTo: [String: Date] = [:]

    /// The chat an update belongs to. Some agents (Cursor) run their hooks in another process
    /// than their MCP server: a hook from a process with no MCP chat joins the one MCP chat
    /// of that agent in that folder.
    func chatID(for u: ChatUpdate) -> String {
        let id = ChatInfo.id(pid: u.agentPid)
        if chats[id]?.hasMCP == true || ["mcp", "heartbeat", "status", "tool"].contains(u.event) { return id }
        guard let cwd = u.cwd else { return id }
        let same = chats.values.filter { $0.hasMCP && $0.agent == u.agent && AXMatch.path($0.cwd) == AXMatch.path(cwd) }
        if same.count == 1 {
            if chats[id] != nil { chats[id] = nil }
            return same[0].id
        }
        return id
    }

    func apply(_ u: ChatUpdate) {
        let id = chatID(for: u)
        if id != ChatInfo.id(pid: u.agentPid) { Isolation.note("chats: \(u.event) from pid \(u.agentPid) joins \(id)") }
        if u.subagent == true {
            // A subagent's hook: the chat is alive, but its state and prompts stay the main agent's.
            chats[id]?.lastSeen = Date()
            return
        }
        if u.event == "SessionEnd" { remove(id); return }
        var c = chats[id] ?? ChatInfo(id: id, agent: u.agent, agentPid: u.agentPid, cwd: u.cwd ?? "")
        c.apply(u)
        chats[id] = c
    }

    func remove(_ id: String) {
        if let q = inbox[id], !q.isEmpty {
            Isolation.note("deliver: \(id) ended with \(q.count) message(s) undelivered")
        }
        chats[id] = nil
        inbox[id] = nil
    }

    /// Chats whose agent still runs and that have the MCP server, newest activity first.
    var reachable: [ChatInfo] {
        prune()
        return chats.values.filter(\.hasMCP).sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Drops chats whose agent process is gone.
    func prune() {
        for (id, c) in chats where !AgentProcess.alive(c.agentPid) { remove(id) }
    }

    func chat(forPid pid: Int32) -> ChatInfo? { chats[ChatInfo.id(pid: pid)] }

    // MARK: Inbox

    func enqueue(_ text: String, for id: String, convoID: String? = nil) {
        inbox[id, default: []].append(Queued(text: text, convoID: convoID))
        Isolation.note("deliver: queued for \(id) (\(chats[id]?.state.rawValue ?? "gone"), \(inbox[id]?.count ?? 0) waiting)")
    }

    /// Hands the waiting messages to the chat; `how` is the hook or tool that takes them.
    func takeInbox(_ id: String, how: String) -> [String] {
        let m = inbox[id] ?? []
        inbox[id] = nil
        guard !m.isEmpty else { return [] }
        Isolation.note("deliver: \(m.count) message(s) to \(id) via \(how)")
        for q in m { if let c = q.convoID { Conductor.shared.markDelivered(c, how: how) } }
        return m.map(\.text)
    }

    func spokeTo(_ id: String) { lastSpokenTo[id] = Date() }

    /// Typed into its window (HM-1374): it is starting a turn, so the next message waits in the inbox.
    /// (Its own hooks may already have reported the new turn, or even its end: then they win.)
    func typedInto(_ id: String, ifUnchangedSince t: Date) {
        if chats[id]?.lastActivity == t { chats[id]?.state = .working }
    }

    func queuedCount(_ id: String) -> Int { inbox[id]?.count ?? 0 }
    func queued(_ id: String) -> [String] { (inbox[id] ?? []).map(\.text) }
}
