import Darwin
import Foundation

/// A terminal pane an agent runs in, as the agent reported it from its own
/// environment (HM-1364). Needs You types into it only by this id, never by a
/// name it read off the screen.
public struct PaneRef: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case herdr, tmux }
    public var kind: Kind
    public var id: String
    /// tmux server socket (from `$TMUX`), herdr socket (from `$HERDR_SOCKET_PATH`).
    public var socket: String?

    public init(kind: Kind, id: String, socket: String? = nil) {
        self.kind = kind; self.id = id; self.socket = socket
    }

    /// The pane in an agent's environment: herdr first (it runs inside a terminal), then tmux.
    public static func from(env: [String: String]) -> PaneRef? {
        if let p = env["HERDR_PANE_ID"], !p.isEmpty { return PaneRef(kind: .herdr, id: p, socket: env["HERDR_SOCKET_PATH"]) }
        if let p = env["TMUX_PANE"], !p.isEmpty {
            let socket = env["TMUX"].flatMap { $0.split(separator: ",").first.map(String.init) }
            return PaneRef(kind: .tmux, id: p, socket: socket)
        }
        return nil
    }
}

/// One update from an agent: the MCP server's register and heartbeat, or a hook event.
public struct ChatUpdate: Codable, Equatable, Sendable {
    /// "mcp", "heartbeat", "status", or a hook event: "SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd".
    public var event: String
    /// claude, codex, gemini, opencode, or the process name.
    public var agent: String
    /// The agent's process: the MCP server and the hooks are both its children, so
    /// this is what joins them into one chat.
    public var agentPid: Int32
    public var sessionID: String?
    public var cwd: String?
    public var pane: PaneRef?
    /// The hook ran inside a subagent: it updates the chat, but never takes its messages.
    public var subagent: Bool?
    /// MCP `status`: one line on what the chat is working on.
    public var status: String?
    /// UserPromptSubmit: what was typed.
    public var prompt: String?
    /// Stop: the agent's last reply (shortened).
    public var reply: String?
    public var transcriptPath: String?

    public init(event: String, agent: String, agentPid: Int32) {
        self.event = event; self.agent = agent; self.agentPid = agentPid
    }
}

/// A chat Needs You can reach, built only from what its agent reported.
public struct ChatInfo: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case working, idle, waiting, unknown }

    /// "pid:<agent pid>": the same for the MCP server and the hooks of one agent.
    public var id: String
    public var agent: String
    public var agentPid: Int32
    public var sessionID: String?
    public var cwd: String
    public var pane: PaneRef?
    public var status: String?
    /// The last prompts typed into it (newest last, at most 3).
    public var prompts: [String] = []
    public var lastReply: String?
    public var state: State = .unknown
    /// Has the MCP server (required to be listed) / has hooks (then busy chats get messages at the end of their turn).
    public var hasMCP = false
    public var hasHooks = false
    public var firstSeen: Date
    public var lastSeen: Date
    public var lastActivity: Date
    /// When he last typed into it: the chat "in front" is the one he used last.
    public var lastPromptAt: Date?

    public init(id: String, agent: String, agentPid: Int32, cwd: String, now: Date = Date()) {
        self.id = id; self.agent = agent; self.agentPid = agentPid; self.cwd = cwd
        firstSeen = now; lastSeen = now; lastActivity = now
    }

    public static func id(pid: Int32) -> String { "pid:\(pid)" }

    /// Last folder name; empty for the home folder.
    public var folder: String {
        let home = NSHomeDirectory()
        if cwd.isEmpty || cwd == home || cwd + "/" == home { return "" }
        return (cwd as NSString).lastPathComponent
    }

    /// What to call it on the island and out loud: the folder, else the agent.
    public var displayName: String {
        folder.isEmpty ? (status.map { String($0.prefix(40)) } ?? agentName + " in your home folder") : folder
    }

    public var agentName: String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "claude-app": return "Claude app"
        case "gemini": return "Gemini"
        case "opencode": return "opencode"
        default: return agent
        }
    }

    /// One line for the router and the chat list.
    public var summary: String {
        var parts: [String] = []
        if let s = status, !s.isEmpty { parts.append(s) }
        if let p = prompts.last, !p.isEmpty { parts.append("last asked: " + String(p.prefix(120))) }
        return parts.joined(separator: "; ")
    }

    public mutating func apply(_ u: ChatUpdate, now: Date = Date()) {
        lastSeen = now
        if !u.agent.isEmpty, agent == "unknown" || agent.isEmpty { agent = u.agent }
        if let s = u.sessionID, !s.isEmpty { sessionID = s }
        if let c = u.cwd, !c.isEmpty { cwd = c }
        if let p = u.pane { pane = p }
        if let s = u.status?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { status = String(s.prefix(200)) }
        switch u.event {
        case "mcp", "heartbeat", "status", "tool": hasMCP = true
        default: hasHooks = true
        }
        switch u.event {
        case "UserPromptSubmit":
            state = .working; lastActivity = now; lastPromptAt = now
            if let p = u.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                prompts.append(String(p.prefix(300)))
                if prompts.count > 3 { prompts.removeFirst(prompts.count - 3) }
            }
        case "Stop":
            state = .idle; lastActivity = now
            if let r = u.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty { lastReply = String(r.prefix(300)) }
        case "AgentResponse":
            // Cursor's afterAgentResponse: the reply text, before its stop hook.
            if let r = u.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty { lastReply = String(r.prefix(300)) }
        case "Notification", "PermissionRequest": state = .waiting; lastActivity = now
        case "SessionStart": state = .idle; lastActivity = now
        case "status": lastActivity = now
        default: break
        }
    }
}

/// Finding the agent process from inside one of its children.
public enum AgentProcess {
    /// Parent pid and short command name of a process (nil when it is gone).
    public static func info(_ pid: Int32) -> (ppid: Int32, comm: String)? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return (kp.kp_eproc.e_ppid, comm)
    }

    static let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "needs-you", "timeout", "nice"]

    /// The first ancestor that is not a shell or wrapper: the agent that started us.
    public static func agent(from pid: Int32 = getppid()) -> (pid: Int32, comm: String) {
        var p = pid
        for _ in 0..<8 {
            guard let i = info(p) else { break }
            let name = (i.comm as NSString).lastPathComponent
            if !wrappers.contains(name) && !name.hasPrefix("-") { return (p, name) }
            if i.ppid <= 1 { break }
            p = i.ppid
        }
        return (pid, info(pid)?.comm ?? "unknown")
    }

    /// claude / codex / gemini / opencode from a process name or a hint.
    public static func kind(comm: String, hint: String? = nil, env: [String: String] = [:]) -> String {
        if let h = hint, !h.isEmpty { return h }
        let c = comm.lowercased()
        for k in ["claude", "codex", "gemini", "opencode"] where c.contains(k) { return k }
        if env["CLAUDECODE"] == "1" { return "claude" }
        return comm.isEmpty ? "unknown" : comm
    }

    public static func alive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
