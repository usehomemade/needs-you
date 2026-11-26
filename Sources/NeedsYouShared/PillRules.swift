import Foundation

/// The island's states (HM-1350) and the rules that decide when each one ends (HM-1414).
/// Every state has a way out: the next event, else its own time limit. Listening (the
/// mic level bars) is shown only while a mic is really open for him.
public enum PillMode: String, CaseIterable, Sendable {
    case idle, wake, listening, thinking, sending, speaking, done, error, moon
}

public enum PillRules {
    /// The longest a state stays when nothing new happens, in seconds (nil: idle stays).
    /// `waitingForTake`: his mic just closed and his words are on their way to the router;
    /// if they never arrive (the mic was stopped, the command dropped) it folds back soon.
    public static func timeout(_ m: PillMode, sendSeconds: Double = 2, hasNote: Bool = false, waitingForTake: Bool = false) -> Double? {
        switch m {
        case .idle: return nil
        case .wake: return 4                     // no command followed
        case .listening: return 150              // the mic itself ends a turn after 2 minutes
        case .thinking: return waitingForTake ? 8 : 15 // the agent may work for minutes: don't sit there
        case .sending: return sendSeconds + 4    // delivery normally ends it
        case .speaking: return 120
        case .done: return hasNote ? 2.2 : 1.1
        case .error: return 4
        case .moon: return 1.6
        }
    }

    /// The mic `closed` stopped listening for him (his turn ended, it was stopped or the
    /// command was dropped). Listening or the wake ears shown for that mic must not stay up:
    /// it waits for his words (thinking) instead. nil: nothing to change.
    public static func micClosed(mode: PillMode, shownFor source: String?, closed: String) -> PillMode? {
        guard mode == .listening || mode == .wake, source == nil || source == closed else { return nil }
        return .thinking
    }

    /// What the island does when a Hey Mac command or a conversation ends.
    public enum Ending: Equatable, Sendable {
        /// Leave what is shown (the "Queued for ..." check, an error already on screen).
        case keep
        case done, thinking, idle
        case error
    }

    /// Every outcome folds back or shows what happened: sent and queued end on a check,
    /// not sent and cancelled fold back (an error already shown stays its few seconds),
    /// an answer to an agent's question shows thinking while it works on it.
    public static func ending(_ status: String, mode: PillMode) -> Ending {
        switch status {
        case "answered", "interrupted": return .thinking
        case "spoken", "done", "sent", "delivered": return mode == .idle || mode == .error ? .keep : .done
        case "queued": return mode == .done || mode == .error ? .keep : .done
        case "error": return .error
        default: return mode == .error ? .keep : .idle
        }
    }

    /// The level bars and the listening label: only while a mic is open for him.
    public static func showsLevels(_ m: PillMode, micOpen: Bool) -> Bool {
        (m == .listening || m == .wake) && micOpen
    }
}
