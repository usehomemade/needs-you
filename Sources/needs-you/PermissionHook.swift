import Foundation
import NeedsYouShared

/// `needs-you permission-hook`: Claude Code's PermissionRequest hook (HM-1369).
///
/// Reads the hook input on stdin. A risky call (PermissionGuard) is asked out
/// loud through the app; his yes or no comes back as Claude Code's decision.
/// Everything else, and every doubt (app not running, do not disturb, no
/// answer, an unclear answer, the time budget running out), prints nothing and
/// exits 0, so the normal on-screen prompt shows. It never allows on its own.
///
/// Test env: NEEDS_YOU_HOOK_DRY=1 prints what it would ask (stderr) and stops;
/// NEEDS_YOU_HOOK_TEST_INPUT=<wav> or NEEDS_YOU_HOOK_TEST_SILENCE=1 go through
/// the app muted (no sound, no mic); NEEDS_YOU_HOOK_BUDGET=<s> (default 50).
enum PermissionHookCLI {
    static let env = ProcessInfo.processInfo.environment

    static func run() -> Never {
        let start = Date()
        let budget = Double(env["NEEDS_YOU_HOOK_BUDGET"] ?? "") ?? 50
        // Hard stop well inside Claude Code's hook timeout: nothing printed means the normal prompt.
        signal(SIGALRM) { _ in _exit(0) }
        alarm(UInt32(max(1, budget.rounded(.up))))

        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
        let event = obj["hook_event_name"] as? String ?? "PermissionRequest"
        guard event == "PermissionRequest" else { exit(0) }
        let tool = obj["tool_name"] as? String ?? ""
        let toolInput = obj["tool_input"] as? [String: Any] ?? [:]
        let cwd = obj["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        guard let risk = PermissionGuard.classify(toolName: tool, toolInput: toolInput) else { exit(0) }

        let project = PermissionGuard.projectLabel(cwd: cwd)
        let question = PermissionGuard.question(project: project, risk: risk)
        if env["NEEDS_YOU_HOOK_DRY"] == "1" {
            FileHandle.standardError.write(Data("\(risk.kind.rawValue): \(question)\n".utf8))
            exit(0)
        }

        let testInput = env["NEEDS_YOU_HOOK_TEST_INPUT"].map { ($0 as NSString).expandingTildeInPath }
        let testSilence = env["NEEDS_YOU_HOOK_TEST_SILENCE"] == "1"
        let test = testInput != nil || testSilence

        // The app must already run: a hook never launches it.
        guard let sock = UnixSocket.connect(Wire.socketPath) else { log(project, risk, "app not running", start); exit(0) }

        // The Notification hook that says "<chat> needs your permission" skips chats
        // that were just asked out loud (it reads this stamp).
        if !test, let session = obj["session_id"] as? String, !session.isEmpty {
            let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/hooks/state")
            if FileManager.default.fileExists(atPath: state.path) {
                try? String(Date().timeIntervalSince1970).write(to: state.appendingPathComponent("asked-\(session)"), atomically: true, encoding: .utf8)
            }
        }

        var req = Request(command: .permission)
        req.text = question
        req.title = "\(project): permission"
        var shown = tool
        if let c = toolInput["command"] as? String { shown = PermissionGuard.redact(String(c.prefix(2000))) }
        req.context = shown
        req.project = project
        req.cwd = cwd
        req.env = env.filter { k, _ in k == "HERDR_PANE_ID" }
        req.waitSeconds = Double(env["NEEDS_YOU_PERMISSION_WAIT"] ?? "") ?? 12
        if let f = testInput { req.mute = true; req.inputFile = f }
        if testSilence { req.mute = true; req.simulateSilence = true; req.waitSeconds = Double(env["NEEDS_YOU_PERMISSION_WAIT"] ?? "") ?? 1 }

        let left = budget - Date().timeIntervalSince(start)
        var tv = timeval(tv_sec: Int(max(1, left)), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let body = try? LineIO.encoder.encode(req), LineIO.writeLine(fd: sock, body),
              let line = LineIO.readLine(fd: sock),
              let resp = try? LineIO.decoder.decode(Response.self, from: line) else {
            close(sock); log(project, risk, "no reply", start); exit(0)
        }
        close(sock)
        guard resp.status == "answered", let d = resp.decision.flatMap(PermissionAnswer.init(rawValue:)),
              let out = PermissionHookOutput.json(d, transcript: resp.transcript ?? "", suggestions: obj["permission_suggestions"] as? [Any]) else {
            log(project, risk, "on screen (\(resp.decision ?? resp.state ?? resp.status))", start)
            exit(0)
        }
        log(project, risk, d.rawValue, start)
        print(out)
        exit(0)
    }

    /// One line per asked call (never the command itself).
    private static func log(_ project: String, _ risk: PermissionGuard.Risk, _ outcome: String, _ start: Date) {
        let url = Wire.supportDir.appendingPathComponent("permission-hook.log")
        let f = ISO8601DateFormatter()
        let line = String(format: "%@ %@ %@ -> %@ (%.1f s)\n", f.string(from: Date()), project, risk.kind.rawValue, outcome, Date().timeIntervalSince(start))
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
