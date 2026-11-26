import Foundation

/// Going away, coming back, catching up (do not disturb with voicemails, HM-1352).
/// The on-device model decides which one he meant (HM-1399).
public enum PresenceCommand: Equatable, Sendable {
    /// "Good night" (goodNight) or "I'm going to take a shower": do not disturb on.
    case away(goodNight: Bool)
    /// "I'm back", "Good morning": do not disturb off, then the voicemails one by one.
    /// `summary`: he also asked what was done ("Good morning, what did you work on last night?").
    case back(summary: Bool)
    /// "Play my voicemails", "Any messages?"
    case playVoicemails
    /// "What did you work on last night?"
    case summary
    /// "List my chats", "Which chats are open?" (HM-1364)
    case listChats

    public static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
    }
}

/// "List my chats" out loud (HM-1364): the connected chats, what each is doing,
/// and how many voice messages wait for it.
public enum ChatsSpeech {
    public static func line(_ chats: [ChatInfo], queued: (String) -> Int = { _ in 0 }) -> String {
        guard !chats.isEmpty else {
            return "No chats are connected yet. Turn them on in Settings, Agents, Reach by Voice, then start a new chat."
        }
        let items = chats.prefix(6).map { c -> String in
            var s = c.displayName
            switch c.state {
            case .working: s += ", working"
            case .waiting: s += ", waiting for you"
            case .idle: s += ", idle"
            case .unknown: break
            }
            let n = queued(c.id)
            if n > 0 { s += n == 1 ? ", one message waiting" : ", \(n) messages waiting" }
            return s
        }
        let head = chats.count == 1 ? "One chat is connected: " : "\(chats.count) chats are connected: "
        let more = chats.count > 6 ? ". And \(chats.count - 6) more." : "."
        return head + items.joined(separator: ". ") + more
    }
}
