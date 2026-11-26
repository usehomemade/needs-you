import Foundation

/// Finds the wake phrase ("Hey Mac" by default, or what the user set in Settings)
/// in recognized text. The matcher is built from the phrase's words: case and
/// punctuation ignored, each word compared by a small phonetic key plus edit
/// distance, with one mishearing allowed in the last word. The words must come
/// together, so the name alone in a normal sentence ("my Mac is slow") never wakes.
public struct WakeMatcher: Sendable {
    public static let defaultPhrase = "Hey Mac"
    /// The default before HM-1428; a stored phrase equal to it moves to the new default.
    public static let previousDefaultWords = ["hey", "cl" + "aude"]

    /// The phrase to store instead of `stored` (HM-1428): the old default becomes
    /// the new one; nil keeps what is stored (a custom phrase, or nothing set).
    public static func migrated(_ stored: String?) -> String? {
        guard let stored, normalize(stored) == previousDefaultWords else { return nil }
        return defaultPhrase
    }

    /// The phrase as typed (trimmed), e.g. "Hey Baby".
    public let phrase: String
    /// Normalized words: lowercase, no accents, no punctuation.
    public let words: [String]
    public let isDefault: Bool

    public init(phrase: String) {
        let trimmed = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let w = Self.normalize(trimmed)
        self.phrase = w.isEmpty ? Self.defaultPhrase : trimmed
        words = w.isEmpty ? Self.normalize(Self.defaultPhrase) : w
        isDefault = words == Self.normalize(Self.defaultPhrase)
    }

    /// The name part, as typed: the last word ("Mac", "Baby").
    public var name: String {
        let parts = phrase.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        return parts.last(where: { !$0.isEmpty }) ?? "Mac"
    }

    /// Hints for the speech recognizer: the phrase, and the name on its own.
    public var contextualStrings: [String] {
        var out = [phrase]
        if words.count > 1 { out.append(name) }
        return out
    }

    // MARK: Matching

    /// Where the wake phrase is in `text` (the earliest match). `voiceLearned`: a
    /// wake also needs his voice, so worse mishearings may count.
    public func range(in text: String, voiceLearned: Bool) -> Range<String.Index>? {
        let toks = Self.tokens(text)
        for i in toks.indices {
            if let end = match(0, i, toks, voiceLearned: voiceLearned) {
                return toks[i].range.lowerBound..<toks[end].range.upperBound
            }
        }
        return nil
    }

    public func contains(_ text: String, voiceLearned: Bool) -> Bool {
        range(in: text, voiceLearned: voiceLearned) != nil
    }

    /// The newest words of a partial are the phrase with only the start of its last
    /// word ("Hey Cl…", "Hey Ba…"). Callers allow this only with his voice learned.
    public func startsPhrase(_ text: String) -> Bool {
        guard let last = words.last, last.count >= 4 else { return false }
        // Nothing but punctuation after the fragment.
        guard text.range(of: #"[\p{L}\p{N}][.,!?]*\s*$"#, options: .regularExpression) != nil else { return false }
        let toks = Self.tokens(text)
        let n = words.count
        guard toks.count >= n else { return false }
        let frag = toks[toks.count - 1].word
        guard frag.count >= 2, frag.count <= 3, frag.count < last.count, last.hasPrefix(frag) else { return false }
        let start = toks.count - n
        for k in 0..<(n - 1) {
            let t = toks[start + k]
            if !wordMatch(t.word, k, sentenceStart: t.sentenceStart, voiceLearned: false) { return false }
        }
        return true
    }

    /// The first word of the phrase (or a mishearing of "Hey") among the newest
    /// words of a partial: worth a second opinion from the other recognizer.
    public func hint(_ text: String) -> Bool {
        if Self.heyGroup.contains(words[0]) {
            return text.range(of: Self.hintPattern, options: .regularExpression) != nil
        }
        let toks = Self.tokens(text)
        for t in toks.suffix(2) where wordMatch(t.word, 0, sentenceStart: true, voiceLearned: false) { return true }
        return false
    }

    /// The words after the first wake phrase. A wake phrase said again right away
    /// ("Hey Mac. Hey Mac, this one: ...") is skipped; one quoted later in
    /// the message ("don't respond to my 'Hey Mac'") stays part of it.
    public func after(_ text: String, voiceLearned: Bool) -> String? {
        guard let r = range(in: text, voiceLearned: voiceLearned) else { return nil }
        var rest = String(text[r.upperBound...])
        let lead = CharacterSet(charactersIn: " ,.:;!?-—\"'\n\t")
        while true {
            while let f = rest.unicodeScalars.first, lead.contains(f) { rest.removeFirst() }
            // Skip filler and a repeated wake phrase at the very start.
            var body = rest
            if let filler = body.range(of: #"^(?i)(?:(?:uh|um|ähm|hmm|so|okay)[\s,.]+)*"#, options: .regularExpression) {
                body = String(body[filler.upperBound...])
            }
            if let again = range(in: body, voiceLearned: false), again.lowerBound == body.startIndex {
                rest = String(body[again.upperBound...]); continue
            }
            break
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Phrase word `pi` onward, starting at token `ti`: the index of the last token used.
    private func match(_ pi: Int, _ ti: Int, _ toks: [Token], voiceLearned: Bool) -> Int? {
        guard ti < toks.count else { return nil }
        let t = toks[ti]
        let lastWord = pi == words.count - 1
        if wordMatch(t.word, pi, sentenceStart: t.sentenceStart, voiceLearned: voiceLearned) {
            if lastWord { return ti }
            if let end = match(pi + 1, ti + 1, toks, voiceLearned: voiceLearned) { return end }
        }
        // Two words heard as one ("Heybaby", "Playcloud").
        if pi + 1 < words.count, t.word.count >= 4 {
            let chars = Array(t.word)
            for k in 2...(chars.count - 2) {
                let left = String(chars[..<k]), right = String(chars[k...])
                guard wordMatch(left, pi, sentenceStart: t.sentenceStart, voiceLearned: voiceLearned),
                      wordMatch(right, pi + 1, sentenceStart: false, voiceLearned: voiceLearned) else { continue }
                if pi + 1 == words.count - 1 { return ti }
                if let end = match(pi + 2, ti + 1, toks, voiceLearned: voiceLearned) { return end }
            }
        }
        return nil
    }

    /// Does the heard word `w` count as phrase word number `pi`?
    func wordMatch(_ w: String, _ pi: Int, sentenceStart: Bool, voiceLearned: Bool) -> Bool {
        let target = words[pi]
        if w == target { return true }
        let first = pi == 0, last = pi == words.count - 1
        // Greetings: the recognizers swap these freely.
        for group in [Self.heyGroup, Self.okGroup, Self.helloGroup] where group.contains(target) {
            if group.contains(w) { return true }
            if group == Self.heyGroup, first, sentenceStart {
                // Far away, "Hey" comes out as "Pay", "They", "A"; only at a sentence start.
                // Not "A" or "I" before a short name: "A Mac mini would do" is normal talk.
                let shortName = (words.last?.count ?? 0) <= 3
                if Self.heyLoose.contains(w), !(shortName && w.count == 1) { return true }
                if voiceLearned, Self.heyVoiceLoose.contains(w), !(shortName && w.count == 1) { return true }
            }
            return false
        }
        if w == target + "s" || w + "s" == target { return true }
        if let heard = Self.heardAs[target], heard.contains(w) { return true }
        if target.hasSuffix("y"), w == target.dropLast() + "ies" { return true }
        guard w.count >= 2 else { return false }
        let d = Self.distance(Array(w), Array(target))
        let kw = Self.key(w), kt = Self.key(target)
        // Same number of syllables ("Bob" is not "Baby"); one off is fine with his voice.
        let sylOff = abs(Self.syllables(w) - Self.syllables(target))
        guard sylOff == 0 || (voiceLearned && sylOff == 1) else { return false }
        // Same sound, spelled a bit differently ("Bobby" for "Baby", "Mack" for "Mac").
        if kw == kt, d <= (target.count <= 3 ? 1 : target.count / 2) { return true }
        // One mishearing in the last word ("Clyde"), not a different word ("close", "clue").
        if last, target.count >= 4, abs(w.count - target.count) <= 1,
           Self.distance(Array(kw), Array(kt)) <= 1, d <= max(1, target.count / 3) { return true }
        return false
    }

    /// How the recognizers write a short name the phonetic key misses
    /// ("Mac" as "Mach", "Mack", "Mc", "Mak").
    static let heardAs: [String: Set<String>] = ["mac": ["mach", "mack", "macks", "mak", "mc"]]

    static let heyGroup: Set<String> = ["hey", "hay", "heh", "hi", "hei", "okay", "ok"]
    static let heyLoose: Set<String> = ["pay", "they", "fay", "hate", "eight", "8", "a"]
    static let heyVoiceLoose: Set<String> = ["i", "play", "day"]
    static let okGroup: Set<String> = ["ok", "okay", "okey", "o"]
    static let helloGroup: Set<String> = ["hello", "hallo", "hullo", "hellow"]

    // MARK: Text

    struct Token { var word: String; var range: Range<String.Index>; var sentenceStart: Bool }

    public static func normalize(_ s: String) -> [String] {
        tokens(s).map(\.word)
    }

    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var i = text.startIndex
        var sentenceStart = true
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" {
                var j = i
                while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "'" || text[j] == "\u{2019}" { j = text.index(after: j) }
                let w = text[i..<j].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
                    .lowercased().filter { $0.isLetter || $0.isNumber }
                if !w.isEmpty { out.append(Token(word: w, range: i..<j, sentenceStart: sentenceStart)) }
                sentenceStart = false
                i = j
            } else {
                if c == "." || c == "!" || c == "?" { sentenceStart = true }
                i = text.index(after: i)
            }
        }
        return out
    }

    /// A small phonetic key: consonant sounds only, voiced and voiceless pairs merged
    /// (d/t, b/p, g/k, v/f, z/s), soft c/g handled, a leading vowel kept as "A".
    /// "mac", "mack", "mak" -> "MK"; "baby", "bobby", "bob" -> "PP".
    public static func key(_ word: String) -> String {
        var s = word.lowercased().filter { $0.isLetter }
        for (a, b) in [("ph", "f"), ("ck", "k"), ("sch", "sk"), ("sh", "X"), ("ch", "X"), ("th", "0"), ("qu", "kw"), ("wh", "w"), ("x", "ks")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        if s.hasPrefix("kn") || s.hasPrefix("gn") || s.hasPrefix("wr") { s.removeFirst() }
        let ch = Array(s)
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var out: [Character] = []
        for (i, c) in ch.enumerated() {
            let next: Character? = i + 1 < ch.count ? ch[i + 1] : nil
            let prev: Character? = i > 0 ? ch[i - 1] : nil
            var k: Character?
            switch c {
            case "a", "e", "i", "o", "u": k = i == 0 ? "A" : nil
            case "y": k = i == 0 ? "Y" : nil
            case "w": k = (prev == nil || !vowels.contains(prev!)) && next.map { vowels.contains($0) } == true ? "W" : nil
            case "h": k = i == 0 && next.map { vowels.contains($0) } == true ? "H" : nil
            case "c": k = next.map { "eiy".contains($0) } == true ? "S" : "K"
            case "g": k = next.map { "eiy".contains($0) } == true ? "J" : (next == "h" ? nil : "K")
            case "q", "k": k = "K"
            case "d", "t": k = "T"
            case "b", "p": k = "P"
            case "v", "f": k = "F"
            case "z", "s": k = "S"
            case "j": k = "J"
            default: k = Character(c.uppercased())
            }
            // A doubled letter is one sound ("bobby"); the same sound again after a vowel is not ("baby").
            if let k {
                if !(i > 0 && ch[i - 1] == c && out.last == k) { out.append(k) }
            }
        }
        return String(out)
    }

    static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: Checking a phrase before using it

    public struct Check: Sendable, Equatable {
        public var usable: Bool
        public var warning: String?
    }

    static let commonPhrases: Set<String> = [
        "hey you", "hey there", "hi there", "hey guys", "hey man", "hey dude", "hey hey", "hey look",
        "thank you", "thanks", "excuse me", "come on", "oh my god", "you know", "i mean", "all right",
        "alright", "okay", "ok", "hello", "hey", "hi", "lets go", "let's go", "good morning", "good night",
        "hey siri", "hey google", "ok google", "alexa", "hey alexa", "yes", "no", "stop", "done",
    ]

    /// Live advice for the Settings field: at least 2 words or 3 syllables, not
    /// something said all the time in normal talk or on TV.
    public static func check(_ phrase: String) -> Check {
        let w = normalize(phrase)
        if w.isEmpty { return Check(usable: false, warning: "Type a phrase. Until then \u{201C}\(defaultPhrase)\u{201D} stays on.") }
        let joined = w.joined(separator: " ")
        if commonPhrases.contains(joined) {
            return Check(usable: true, warning: "This is said a lot in normal talk and on TV: expect it to wake by mistake.")
        }
        let syl = w.map(syllables).reduce(0, +)
        if w.count < 2 && syl < 3 {
            return Check(usable: true, warning: "Very short: use 2 words or 3 syllables, or it will wake by mistake more often.")
        }
        if let last = w.last, last.count <= 2 {
            return Check(usable: true, warning: "The last word is very short, so it is easy to mishear. A name works better.")
        }
        if w.count > 4 {
            return Check(usable: true, warning: "Long phrases are recognized less reliably, and the chime comes later.")
        }
        return Check(usable: true, warning: nil)
    }

    /// Rough English syllable count: vowel groups, minus a silent final "e".
    static func syllables(_ word: String) -> Int {
        let ch = Array(word.lowercased())
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var n = 0, inVowel = false
        for (i, c) in ch.enumerated() {
            let v = vowels.contains(c) && !(c == "y" && i == 0)
            if v && !inVowel { n += 1 }
            inVowel = v
        }
        if n > 1, word.hasSuffix("e"), !word.hasSuffix("le"), let p = ch.dropLast().last, !vowels.contains(p) { n -= 1 }
        if n > 1, word.hasSuffix("ed"), ch.count > 2, !"tdaeiouy".contains(ch[ch.count - 3]) { n -= 1 }
        return max(1, n)
    }

    // MARK: Stop phrase

    /// "Stop, <name>" ("Stop, Mac" by default) in recognized text: a "stop" (or a
    /// mishearing of it that starts with "st": "Stuff", "Stomp") right before the
    /// phrase's last word, or both heard as one word ("Stopmac").
    public func isStop(_ text: String, voiceLearned: Bool = false) -> Bool {
        let toks = Self.tokens(text)
        let last = words.count - 1
        func stopWord(_ w: String) -> Bool { w == "stop" || (w.hasPrefix("st") && w.count <= 6 && Self.distance(Array(w), Array("stop")) <= 3) }
        for (i, t) in toks.enumerated() {
            if stopWord(t.word), i + 1 < toks.count,
               wordMatch(toks[i + 1].word, last, sentenceStart: false, voiceLearned: voiceLearned) { return true }
            if t.word.hasPrefix("stop"), t.word.count > 4,
               wordMatch(String(t.word.dropFirst(4)), last, sentenceStart: false, voiceLearned: voiceLearned) { return true }
        }
        return false
    }

    /// A "Hey" (or a far-field mishearing of it) among the newest words of a partial.
    static let hintPattern = #"(?i)\b(hey|hay|heh|hi|okay|ok)\b[\s,.!?]*(\w+[.,!?]*)?$"#
}
