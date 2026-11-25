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
        return nil
    }

    static let goodNightPattern = #"^(good ?night|night night|nighty night|(im|i am) (going|off|heading) to (bed|sleep)|(going|off|heading) to (bed|sleep)|time (for|to) (bed|sleep)|sleep well)\b"#
    static let awayPattern = #"^((do not|dont) disturb( me)?|do not disturb mode|(im|i am) (going to|gonna) (take|have|grab) a (shower|bath|break|nap|walk)|(going to|gonna) (take|have) a (shower|bath|break|nap)|(im|i am) (taking|having) a (shower|bath|break|nap)|(ill|i will) be (right )?back|be right back|brb|(im|i am) (going )?(out|away)( for a (bit|while))?$|pause (everything|all voice|voice|all)|quiet mode|i need (some )?quiet)\b"#
    static let backPattern = #"^((im|i am) back|good morning|(im|i am) (here|awake|up) again|(turn|switch) off (do not|dont) disturb|end (do not|dont) disturb|you can talk( to me)? again|back again)\b"#
    static let backShortPattern = #"^(morning|(im|i am) (here|awake|up)|resume|welcome back)$"#
    static let summaryPattern = #"(what (did|have) you( all| guys)? (work(ed)? on|do|done|get done)|what happened (last night|overnight|while i was (away|gone|out|asleep))|catch me up|give me (a|the) summary)"#
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
