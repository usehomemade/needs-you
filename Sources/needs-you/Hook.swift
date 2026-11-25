import Foundation
import NeedsYouShared

/// `needs-you hook <event> [--agent claude|codex]` (HM-1364): run by the agent's
/// hooks. Tells the app what the chat is doing and, where the event allows it,
/// prints the user's waiting voice messages as the hook's answer. Never blocks
/// the agent: without the app it prints nothing.
enum Hook {
    static func run(_ args: [String]) -> Never {
        let event = args.first ?? ""
        var agentHint: String?
        if let i = args.firstIndex(of: "--agent"), i + 1 < args.count { agentHint = args[i + 1] }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let env = ProcessInfo.processInfo.environment
        let agent = AgentProcess.agent()
        var u = ChatUpdate(event: event, agent: AgentProcess.kind(comm: agent.comm, hint: agentHint, env: env), agentPid: agent.pid)
        u.sessionID = (json["session_id"] as? String) ?? (json["conversation_id"] as? String)
        u.cwd = (json["cwd"] as? String) ?? (json["workspace_roots"] as? [String])?.first ?? FileManager.default.currentDirectoryPath
        u.pane = PaneRef.from(env: env)
        u.transcriptPath = json["transcript_path"] as? String
        u.prompt = json["prompt"] as? String
        u.reply = (json["last_assistant_message"] as? String) ?? (json["last_agent_message"] as? String) ?? (event == "AgentResponse" ? json["text"] as? String : nil)
        if event == "SessionStart" || event == "SessionEnd" || event == "Notification" { u.prompt = nil }
        // Hooks inside a subagent run in the same agent process: their output goes to the
        // subagent, never to the chat he spoke to, so they must not take its messages.
        u.subagent = HookSetup.isSubagent(json)
        var r = Request(command: .register)
        r.chat = u
        r.cwd = u.cwd
        // A Stop hook that already continued once must not loop: the app empties the inbox, so the next Stop finds nothing.
        let resp = Client.response(r, launch: false)
        let messages = resp?.messages ?? []
        log("\(event) pid \(agent.pid) session \(u.sessionID ?? "-") subagent \(u.subagent == true) keys [\(json.keys.sorted().joined(separator: ","))] app \(resp == nil ? "down" : "ok") handed \(messages.count)")
        guard let out = HookSetup.output(event: event, messages: messages, agent: u.agent),
              let data = try? JSONSerialization.data(withJSONObject: out, options: [.withoutEscapingSlashes]) else { exit(0) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        exit(0)
    }

    /// hooks.log in Application Support: one line per hook run (no message text).
    static func log(_ line: String) {
        let url = Wire.supportDir.appendingPathComponent("hooks.log")
        let f = ISO8601DateFormatter()
        let data = Data((f.string(from: Date()) + " " + line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }
}
