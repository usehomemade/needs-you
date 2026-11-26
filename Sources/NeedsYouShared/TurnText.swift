import Foundation

/// Does the text so far read like a finished thought? (HM-1360)
/// Used when a pause would end his turn: a sentence left hanging on "I think I like",
/// "when I try to", "and", "um" gets more time, a finished one ends as before.
public enum TurnText {
    /// Words a sentence almost never ends on: fillers, joining words, articles and
    /// prepositions (English, a few Turkish, German, French and Italian ones). Words that
    /// can end a short answer ("so", "that", "no", "on", "is", "yani") are left out.
    static let open: Set<String> = [
        // fillers
        "uh", "um", "uhm", "umm", "erm", "er", "ah", "eh", "hmm", "mm", "ähm", "äh", "öhm", "ee", "eee", "şey", "euh", "ehm",
        // joining words
        "and", "but", "or", "because", "cause", "if", "when", "while", "than", "which", "whether", "although", "unless", "like", "plus",
        // articles, determiners, possessives
        "the", "a", "an", "my", "your", "our", "their", "every",
        // prepositions that need what follows
        "to", "of", "at", "for", "from", "with", "without", "about", "into", "onto", "between", "via", "per", "as",
        // a subject still waiting for its verb
        "i", "i'm", "we're", "they're", "you're", "it's", "let's", "gonna", "wanna", "gotta",
        // Turkish
        "ve", "ama", "fakat", "çünkü", "mesela", "veya", "ile", "eğer",
        // German
        "und", "aber", "oder", "weil", "dass", "der", "ein", "eine", "mit", "für", "zu", "von", "wenn", "ich",
        // French / Italian
        "et", "mais", "parce", "les", "une", "des", "pour", "avec", "je", "perché", "di", "per", "con", "che",
    ]

    /// Two-word endings that leave the thought open ("I think", "I like", "I mean").
    static let openPairs: Set<String> = [
        "i think", "i like", "i love", "i mean", "i want", "i need", "i feel", "i'd like", "i would",
        "we should", "we need", "and then", "so that", "kind of", "sort of", "first of",
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// True when the last words leave the sentence open. Empty text is not open
    /// (nothing to wait for). Final "?" or "!" counts as finished; a final "." does
    /// not, since the recognizers put one after every pause ("I think I like.").
    public static func trailsOff(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("?") || t.hasSuffix("!") { return false }
        // "...", "-", "," at the end: he stopped mid-thought.
        // "...", "-", "," or ":" at the end: he stopped mid-thought ("Hey Mac, this one:").
        if t.hasSuffix("...") || t.hasSuffix("…") || t.hasSuffix(",") || t.hasSuffix("-") || t.hasSuffix("–") || t.hasSuffix(":") { return !words(t).isEmpty }
        let w = words(t)
        guard let last = w.last else { return false }
        if open.contains(last) { return true }
        if w.count >= 2, openPairs.contains(w[w.count - 2] + " " + last) { return true }
        return false
    }
}

/// Which language is he speaking? (HM-1362) Whisper scores every language; the ones he
/// usually speaks get a prior. A language counts only once the score is clear, so the
/// subtitles never show a guess in the wrong language or script.
public enum LanguagePick {
    public struct Decision: Equatable {
        /// The language to use (the best of his languages when nothing is clear yet).
        public var code: String
        /// True when the evidence is clear enough to show subtitles in it or switch to it.
        public var confident: Bool
        public var top: Float
        public var margin: Float
        public init(code: String, confident: Bool, top: Float, margin: Float) {
            self.code = code; self.confident = confident; self.top = top; self.margin = margin
        }
    }

    /// Prior weight of a language he usually speaks, against 1 for any other.
    public static let boost: Float = 4
    /// Least speech (seconds, his words only) before a decision counts.
    public static let minSpeech = 1.5
    /// A clear decision: top probability (after the prior) and gap to the second.
    public static let minTop: Float = 0.8
    public static let minMargin: Float = 0.6
    /// A language he did not pick needs this much on its own (before the prior).
    public static let minOther: Float = 0.9

    /// `probs`: Whisper's language probabilities (any subset; normalised here).
    /// `picked`: his languages, in his order. `strict`: only these ("Only these languages").
    public static func decide(_ probs: [String: Float], picked: [String], strict: Bool, speech: Double) -> Decision {
        let fallback = picked.first ?? "en"
        let allowed = strict ? probs.filter { picked.contains($0.key) } : probs
        let total = allowed.values.reduce(0, +)
        guard total > 0 else { return Decision(code: fallback, confident: false, top: 0, margin: 0) }
        let raw = allowed.mapValues { $0 / total }
        var weighted = raw
        if !strict { for (k, v) in raw where picked.contains(k) { weighted[k] = v * boost } }
        let wsum = weighted.values.reduce(0, +)
        let ranked = weighted.mapValues { $0 / wsum }.sorted { $0.value > $1.value }
        let top = ranked[0], second = ranked.count > 1 ? ranked[1].value : 0
        let margin = top.value - second
        let isPicked = picked.contains(top.key)
        let clear = speech >= minSpeech && top.value >= minTop && margin >= minMargin && (isPicked || (raw[top.key] ?? 0) >= minOther)
        if clear { return Decision(code: top.key, confident: true, top: top.value, margin: margin) }
        // Not clear: the best of his own languages, not shown as subtitles yet.
        let best = picked.max { (weighted[$0] ?? 0) < (weighted[$1] ?? 0) } ?? fallback
        return Decision(code: best, confident: false, top: top.value, margin: margin)
    }
}

/// Writing systems, so subtitles never show a script his language does not use (HM-1362).
public enum Script: String {
    case latin, cyrillic, greek, arabic, hebrew, devanagari, cjk, kana, hangul, thai, other

    static func of(_ s: Unicode.Scalar) -> Script? {
        guard s.properties.isAlphabetic else { return nil }
        switch s.value {
        case 0x41...0x24F, 0x1E00...0x1EFF: return .latin
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F: return .cyrillic
        case 0x590...0x5FF: return .hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x900...0x97F: return .devanagari
        case 0xE00...0xE7F: return .thai
        case 0x3040...0x30FF: return .kana
        case 0xAC00...0xD7AF, 0x1100...0x11FF: return .hangul
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: return .cjk
        default: return .other
        }
    }

    /// The scripts text in this language is written in.
    public static func expected(_ code: String) -> Set<Script> {
        switch code {
        case "ru", "uk", "be", "bg", "sr", "mk", "kk", "ky", "tg", "mn", "ba", "tt": return [.cyrillic, .latin]
        case "el": return [.greek, .latin]
        case "ar", "fa", "ur", "ps", "sd": return [.arabic, .latin]
        case "he", "yi": return [.hebrew, .latin]
        case "hi", "mr", "ne", "sa": return [.devanagari, .latin]
        case "zh", "yue": return [.cjk, .latin]
        case "ja": return [.kana, .cjk, .latin]
        case "ko": return [.hangul, .cjk, .latin]
        case "th": return [.thai, .latin]
        case "ta", "te", "kn", "ml", "bn", "gu", "pa", "si", "my", "km", "lo", "ka", "hy", "am", "bo": return [.other, .latin]
        default: return [.latin]
        }
    }

    /// True when (nearly) every letter is in a script one of `languages` uses.
    public static func fits(_ text: String, languages: [String]) -> Bool {
        let ok = languages.reduce(into: Set<Script>()) { $0.formUnion(expected($1)) }
        var total = 0, bad = 0
        for s in text.unicodeScalars {
            guard let sc = of(s) else { continue }
            total += 1
            if !ok.contains(sc) { bad += 1 }
        }
        return total == 0 || Double(bad) / Double(total) < 0.1
    }
}
