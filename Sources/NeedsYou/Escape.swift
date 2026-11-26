import Foundation
import NeedsYouShared

/// Escape, while Needs You has it registered (Hotkeys): once = close, twice = reset
/// (HM-1429, EscapeKeys). Every state follows the same rule:
/// - speaking: the voice stops, the conversation closes (the agent is told);
/// - his command: listening stops, his words so far are kept, not sent;
/// - "which chat?": it closes, his message is kept, not sent;
/// - the send countdown: nothing is typed, the message is kept, not sent;
/// - an agent's question he is answering: listening stops, it waits as a voicemail.
/// A second press within half a second drops whatever the close kept, cancels what is
/// still running and goes back to listening for the wake phrase.
@MainActor
enum Escape {
    private(set) static var keys = EscapeKeys()

    /// From the Escape hotkey.
    static func pressed() {
        let p = keys.press(at: Date())
        Hotkeys.shared.escapeGrace() // stays registered long enough for a second press
        Isolation.note("keys: Escape: \(p.rawValue)")
        switch p {
        case .close: close()
        case .reset: reset()
        }
    }

    /// When the last close happened (nil if a reset came after it).
    static var lastClose: Date? { keys.closedAt }

    /// Waits until the close at `at` is final: `.close`, or `.reset` if he pressed again.
    static func settle(_ at: Date?) async -> EscapeKeys.Press {
        guard let at else { return .reset }
        while true {
            if let o = keys.outcome(of: at, at: Date()) { return o }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private static func close() {
        if VoiceCommands.shared.closePendingSend() { return }
        if Conductor.shared.voicePlaying { Conductor.shared.escapePressed(); return }
        if VoiceCommands.shared.capturing { VoiceCommands.shared.closeCommand(); return }
        if Conductor.shared.answering { Conductor.shared.closeAnswer(); return }
    }

    private static func reset() {
        VoiceCommands.shared.resetAll()
        Conductor.shared.resetAll()
        Subtitles.shared.userStopped()
        Island.shared.idle()
        Sounds.shared.play(.cancelled)
    }
}
