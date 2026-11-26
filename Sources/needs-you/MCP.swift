import Foundation
import NeedsYouShared

/// `needs-you mcp`: the Needs You MCP server on stdio (HM-1364). The agent starts
/// it; it registers the agent's chat with the app (and keeps it registered while
/// the agent runs), and offers ask / say / done / status / inbox as tools.
/// Newline-delimited JSON-RPC 2.0, as MCP's stdio transport specifies.
final class MCPServer {
    private let out = NSLock()
    private let pending = DispatchGroup()
    private let agent: (pid: Int32, comm: String)
    private let kind: String
    private let env = ProcessInfo.processInfo.environment
    /// Cursor starts MCP servers in its own folder and names the window's workspace in WORKSPACE_FOLDER_PATHS.
    private let cwd = ProcessInfo.processInfo.environment["WORKSPACE_FOLDER_PATHS"].flatMap { $0.split(separator: ",").first.map(String.init) }.flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.currentDirectoryPath

    init() {
        agent = AgentProcess.agent()
        kind = AgentProcess.kind(comm: agent.comm, hint: ProcessInfo.processInfo.environment["NEEDS_YOU_AGENT"], env: ProcessInfo.processInfo.environment)
    }

    static let instructions = """
    Needs You lets the user talk to this chat by voice and lets you talk to them out loud.
    Call `status` with one short line on what this chat is working on whenever the topic changes (it is how the user's spoken messages find this chat). \
    Use `ask` when you need the user (a decision, approval, login, anything blocking); `say` to answer a follow-up; `done` to end the conversation. A question always needs an answer, so ask it with `ask` (or `say` without no_listen), never with no_listen. \
    A message ending with "(sent by voice: reply by voice with needs-you)" came from the user's voice: reply out loud with `ask` or `say` (no_listen when no answer is needed), brief, and also in the chat. When it says "sent by voice from <Mac>", pass that name as for_mac. \
    Only the main agent uses Needs You: a subagent never calls these tools; it puts its question in its report and the main agent asks.
    """

    func run() -> Never {
        register("mcp")
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 30)
                // The agent is gone: stop (stdin usually closes first).
                if !AgentProcess.alive(agent.pid) { exit(0) }
                register("heartbeat")
            }
        }
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Tool calls can wait minutes (ask): each request on its own thread.
            pending.enter()
            Thread.detachNewThread { [self] in handle(msg); pending.leave() }
        }
        // stdin closed: finish what is running, then go.
        pending.wait()
        exit(0)
    }

    // MARK: Registration

    private func update(_ event: String) -> ChatUpdate {
        var u = ChatUpdate(event: event, agent: kind, agentPid: agent.pid)
        u.cwd = cwd
        u.pane = PaneRef.from(env: env)
        u.sessionID = env["CLAUDE_CODE_SESSION_ID"] ?? env["CODEX_SESSION_ID"]
        return u
    }

    private func register(_ event: String, status: String? = nil) {
        // The Claude app runs one server for all its chats (HM-1385): it is reached as an
        // app ("Hey Mac, new chat on Claude desktop"), never as a registered chat.
        if kind == "claude-app" { return }
        var r = Request(command: .register)
        var u = update(event)
        u.status = status
        r.chat = u
        r.cwd = cwd
        _ = Client.send(r, launch: false)
    }

    // MARK: JSON-RPC

    private func handle(_ msg: [String: Any]) {
        guard let method = msg["method"] as? String else { return }
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        guard id != nil else { return } // notifications: nothing to answer
        switch method {
        case "initialize":
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            reply(id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "needs-you", "version": "1"],
                "instructions": Self.instructions,
            ])
        case "ping": reply(id, result: [String: Any]())
        case "tools/list": reply(id, result: ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = call(name, args)
            reply(id, result: ["content": [["type": "text", "text": text]], "isError": isError])
        default:
            send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }

    private func reply(_ id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        out.lock(); defer { out.unlock() }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    // MARK: Tools

    static let tools: [[String: Any]] = [
        tool("status", "Tell Needs You in one short line what this chat is working on. Call it when the topic changes; the user's spoken messages are routed by it.",
             ["text": str("One line, e.g. \"moving orchard deploys to CI\"")], required: ["text"]),
        tool("ask", "Ask the user out loud and wait for the spoken answer (a decision, approval, login, anything blocking). Returns JSON: status answered|voicemail|no_answer|interrupted, transcript, conversation_id.",
             ["text": str("One or two spoken sentences"), "title": str("Short title"), "context": str("Exact steps or commands, shown with the question"), "for_mac": forMac], required: ["text"]),
        tool("say", "Continue the open conversation: speak, then listen for the reply (unless no_listen).",
             ["text": str("What to say"), "conversation_id": str("From ask"), "no_listen": ["type": "boolean", "description": "Speak without waiting for an answer. Only for news that needs no reply; never for a question"], "for_mac": forMac], required: ["text"]),
        tool("done", "End the conversation, optionally saying something first.",
             ["text": str("Last words (optional)"), "conversation_id": str("From ask")], required: []),
        tool("inbox", "Messages from the user waiting for this chat (they normally arrive by themselves).", [:], required: []),
    ]

    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static let forMac = str("When replying to \"(sent by voice from <Mac>: ...)\": that Mac's name. Only that Mac speaks it.")

    /// This Mac's name, as voice messages to chat apps carry it (HM-1398).
    static var macName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    /// A reply meant for another Mac: chat apps sync their chats through the account, so the
    /// same chat can answer on every Mac. Only the Mac he spoke to may speak (HM-1398).
    static func otherMac(_ a: [String: Any]) -> String? {
        guard let m = (a["for_mac"] as? String)?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { return nil }
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return norm(m) == norm(macName) ? nil : m
    }
    private static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    private func call(_ name: String, _ a: [String: Any]) -> (String, Bool) {
        let text = (a["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["ask", "say", "done"].contains(name), let other = Self.otherMac(a) {
            return ("Not spoken: this voice message came from \(other), and this Mac is \(Self.macName). Only \(other) speaks the reply; answer in this chat as text.", false)
        }
        var r: Request
        switch name {
        case "status":
            guard let text, !text.isEmpty else { return ("status needs text", true) }
            register("status", status: text)
            return ("ok", false)
        case "ask":
            guard let text, !text.isEmpty else { return ("ask needs text", true) }
            r = Request(command: .ask); r.text = text
            r.title = a["title"] as? String
            r.context = a["context"] as? String
        case "say":
            guard let text, !text.isEmpty else { return ("say needs text", true) }
            r = Request(command: .say); r.text = text
            r.conversationID = a["conversation_id"] as? String
            if a["no_listen"] as? Bool == true { r.noListen = true }
        case "done":
            r = Request(command: .done); r.text = text
            r.conversationID = a["conversation_id"] as? String
        case "inbox":
            r = Request(command: .inbox)
        default:
            return ("unknown tool \(name)", true)
        }
        r.cwd = cwd
        r.env = Client.callerEnv(env)
        r.chat = update("tool")
        guard let line = Client.send(r) else { return ("Needs You is not running", true) }
        let s = String(data: line, encoding: .utf8) ?? ""
        let status = (try? LineIO.decoder.decode(Response.self, from: line))?.status ?? "error"
        return (s, status == "error")
    }
}
