import Foundation

/// What the user says after the wake phrase to go away, come back, or catch up
/// (do not disturb with voicemails, HM-1352).
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

    /// Only short commands count, and only from their first words, so a message
    /// like "this one: write a good night message" still goes to the chat.
    public static func parse(_ text: String) -> PresenceCommand? {
        var t = normalize(text)
        // Leading fillers and a polite "okay so".
        while let r = t.range(of: #"^(uh|um|uhm|ähm|okay|ok|so|well|hey|right|alright) "#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        // Trailing "thanks" / "done" / "over".
        while let r = t.range(of: #" ?\b(thanks|thank you|done|over|please)$"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        t = t.trimmingCharacters(in: .whitespaces)
        let words = t.split(separator: " ")
        guard !words.isEmpty, words.count <= 14 else { return nil }

        let summary = t.range(of: summaryPattern, options: .regularExpression) != nil
        if t.range(of: backPattern, options: .regularExpression) != nil || (words.count <= 3 && t.range(of: backShortPattern, options: .regularExpression) != nil) {
            return .back(summary: summary)
        }
        if t.range(of: goodNightPattern, options: .regularExpression) != nil { return .away(goodNight: true) }
        if t.range(of: awayPattern, options: .regularExpression) != nil { return .away(goodNight: false) }
        if t.range(of: "^" + summaryPattern, options: .regularExpression) != nil { return .summary }
        if t.range(of: voicemailPattern, options: .regularExpression) != nil { return .playVoicemails }
        if words.count <= 8, t.range(of: chatsPattern, options: .regularExpression) != nil { return .listChats }
        return nil
    }

    static let goodNightPattern = #"^(good ?night|night night|nighty night|(im|i am) (going|off|heading) to (bed|sleep)|(going|off|heading) to (bed|sleep)|time (for|to) (bed|sleep)|sleep well)\b"#
    static let awayPattern = #"^((do not|dont) disturb( me)?|do not disturb mode|(im|i am) (going to|gonna) (take|have|grab) a (shower|bath|break|nap|walk)|(going to|gonna) (take|have) a (shower|bath|break|nap)|(im|i am) (taking|having) a (shower|bath|break|nap)|(ill|i will) be (right )?back|be right back|brb|(im|i am) (going )?(out|away)( for a (bit|while))?$|pause (everything|all voice|voice|all)|quiet mode|i need (some )?quiet)\b"#
    static let backPattern = #"^((im|i am) back|good morning|(im|i am) (here|awake|up) again|(turn|switch) off (do not|dont) disturb|end (do not|dont) disturb|you can talk( to me)? again|back again)\b"#
    static let backShortPattern = #"^(morning|(im|i am) (here|awake|up)|resume|welcome back)$"#
    static let summaryPattern = #"(what (did|have) you( all| guys)? (work(ed)? on|do|done|get done)|what happened (last night|overnight|while i was (away|gone|out|asleep))|catch me up|give me (a|the) summary)"#
    static let chatsPattern = #"^((list|show|tell me|name|read)( me)? (all )?(my |the )?(open |connected )?chats|(what|which) chats (are|do i have)\b|(what|which) (are )?my chats|my chats$|what chats$)"#
    static let voicemailPattern = #"((play|read)( me)? (my |the )?(voicemails?|messages)|^any (new )?(voicemails?|messages)|(do i have|are there) (any )?(new )?(voicemails?|messages))"#

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
