import Foundation
import NeedsYouShared

/// The chats Needs You can reach by voice (HM-1364): only agents that registered
/// through the Needs You MCP server or its hooks. Nothing is read off the screen.
@MainActor
final class ChatRegistry: ObservableObject {
    static let shared = ChatRegistry()

    @Published private(set) var chats: [String: ChatInfo] = [:]
    /// Messages for a chat that could not be typed in yet (it was busy): handed over by its Stop hook.
    private(set) var inbox: [String: [String]] = [:]
    /// When the user last sent each chat something by voice.
    private(set) var lastSpokenTo: [String: Date] = [:]

    func apply(_ u: ChatUpdate) {
        let id = ChatInfo.id(pid: u.agentPid)
        if u.event == "SessionEnd" { remove(id); return }
        var c = chats[id] ?? ChatInfo(id: id, agent: u.agent, agentPid: u.agentPid, cwd: u.cwd ?? "")
        c.apply(u)
        chats[id] = c
    }

    func remove(_ id: String) {
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

    func enqueue(_ text: String, for id: String) {
        inbox[id, default: []].append(text)
    }

    func takeInbox(_ id: String) -> [String] {
        let m = inbox[id] ?? []
        inbox[id] = nil
        return m
    }

    func spokeTo(_ id: String) { lastSpokenTo[id] = Date() }
}
