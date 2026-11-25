import AppKit
import Foundation
import NeedsYouShared

// Approve Claude Code permission prompts by voice (HM-1369).
//
// `needs-you permission-hook` (Claude Code's PermissionRequest hook) sends a
// `permission-ask` request for risky calls only. Needs You asks once, out
// loud, in one short line, and maps the answer to allow / always / deny.
// Anything in doubt returns "fallback": the hook prints nothing and the
// normal on-screen prompt shows. Never allows on its own.

extension Conductor {
    func permission(_ req: Request, clientAlive: @escaping () -> Bool) async -> Response {
        var fallback = Response(status: "fallback")
        let test = req.mute == true
        guard test || PermissionVoice.enabled else { fallback.state = "off in Settings"; return fallback }
        guard !DoNotDisturb.shared.on else { fallback.state = "do not disturb"; return fallback }
        // Another conversation is running: wait a moment (the last one may be saying
        // its closing line), then leave it to the on-screen prompt; no long queueing.
        for _ in 0..<20 where busy { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard !busy, clientAlive() else { fallback.state = "busy"; return fallback }

        var q = req
        q.command = .ask
        q.once = true
        q.waitSeconds = min(max(req.waitSeconds ?? 12, 1), 20)

        // The hook went away (answered on screen, or Claude Code's timeout): stop talking.
        let watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !clientAlive() {
                    guard let self else { return }
                    if self.voicePlaying { self.stopSpeaking(.escape) } else { self.endAnswer() }
                    return
                }
            }
        }
        let r = await ask(q, clientAlive: clientAlive)
        watch.cancel()

        let heard = (r.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let answer: PermissionAnswer = (r.status == "answered" || r.status == "interrupted") && !heard.isEmpty && clientAlive()
            ? PermissionAnswer.parse(heard) : .unclear
        Isolation.note("permission: \(req.project ?? "?") -> \(r.status), \(answer.rawValue)")

        // Close the conversation (says the closing line) after replying, so the hook is not kept waiting.
        if let id = r.conversationID, current?.id == id {
            var close = Request(command: .done)
            close.conversationID = id
            close.mute = req.mute
            close.text = heard.isEmpty || !clientAlive() ? nil : answer.closing
            Task { @MainActor [weak self] in
                _ = await self?.done(close)
                if test { self?.forget(conversationID: id) }
            }
        } else if test, let id = r.conversationID {
            forget(conversationID: id)
        }

        guard answer != .unclear else {
            fallback.state = r.status
            fallback.transcript = heard.isEmpty ? nil : heard
            fallback.decision = answer.rawValue
            return fallback
        }
        var out = Response(status: "answered")
        out.decision = answer.rawValue
        out.transcript = heard
        out.conversationID = r.conversationID
        return out
    }
}

/// The Settings → Agents switch and the hook entry in ~/.claude/settings.json.
@MainActor
final class PermissionVoice: ObservableObject {
    static let shared = PermissionVoice()
    nonisolated static let enabledKey = "permissionVoiceEnabled"
    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    @Published private(set) var installed = false
    @Published private(set) var lastError: String?

    let installer = PermissionHookInstaller(dir: AgentInstructions.targetDir())
    /// The --ui-demo windows only touch the file when a test folder is set.
    private var mayWrite: Bool { !Prefs.readOnly || ProcessInfo.processInfo.environment["NEEDS_YOU_CLAUDE_DIR"] != nil }

    /// The CLI inside the app bundle (falls back to ~/.local/bin for `swift run`).
    var cliPath: String {
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/needs-you")
        if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle.path }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/needs-you").path
    }

    var preview: String { PermissionHookInstaller.preview(cli: cliPath) }

    /// On launch and when Settings opens: only when he turned it on, keep the path current.
    func sync() {
        guard mayWrite else { installed = false; return }
        if Self.enabled {
            do { try installer.install(cli: cliPath); lastError = nil } catch { lastError = error.localizedDescription }
        }
        installed = installer.isInstalled
    }

    func setEnabled(_ on: Bool) {
        guard mayWrite else { return }
        do {
            if on { try installer.install(cli: cliPath) } else { try installer.remove() }
            UserDefaults.standard.set(on, forKey: Self.enabledKey)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        installed = installer.isInstalled
    }

    func revealSettings() { NSWorkspace.shared.activateFileViewerSelecting([installer.settingsURL]) }
}
