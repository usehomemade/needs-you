import Foundation
import NaturalLanguage

/// Which voice speaks which part of a reply (HM-1368). English stays with Kokoro;
/// Turkish, German, French, Italian and Russian get a native voice (Supertonic-3,
/// downloaded on first use), each sentence in the language it is written in, so a
/// mixed reply switches voice mid-way.
public enum VoiceRouting {
    /// Languages with a native (non-English) voice, in Settings order.
    public static let native: [String] = ["tr", "de", "fr", "it", "ru"]
    /// Languages a sentence is detected among.
    public static let candidates: [String] = ["en"] + native

    /// One run of text in one language.
    public struct Segment: Equatable, CustomStringConvertible {
        public var language: String
        public var text: String
        public init(_ language: String, _ text: String) { self.language = language; self.text = text }
        public var description: String { "\(language): \(text)" }
    }

    /// Splits `text` into runs of sentences in one language. Short or unclear
    /// sentences ("Okay.", "Danke!") take the language of the sentence before them
    /// (or after, at the start); with no clear sentence at all, the whole text is
    /// judged at once, and English is the default.
    public static func segments(_ text: String) -> [Segment] {
        let sentences = split(text)
        guard !sentences.isEmpty else { return [] }
        var langs: [String?] = sentences.map { detect($0) }
        if langs.allSatisfy({ $0 == nil }) {
            let whole = detect(text, minWords: 2) ?? "en"
            langs = Array(repeating: whole, count: sentences.count)
        }
        // Unclear sentences inherit from the nearest clear one before them, else after.
        var last: String?
        for i in langs.indices {
            if let l = langs[i] { last = l } else if let l = last { langs[i] = l }
        }
        var next: String?
        for i in langs.indices.reversed() {
            if let l = langs[i] { next = l } else { langs[i] = next ?? "en" }
        }
        var out: [Segment] = []
        for (s, l) in zip(sentences, langs) {
            let lang = l ?? "en"
            if let i = out.indices.last, out[i].language == lang { out[i].text += s } else { out.append(Segment(lang, s)) }
        }
        return out.compactMap { seg in
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : Segment(seg.language, t)
        }
    }

    /// Sentences, each with the whitespace after it, so joining them gives `text` back.
    public static func split(_ text: String) -> [String] {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var parts: [String] = []
        var start = text.startIndex
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if range.upperBound > start {
                parts.append(String(text[start..<range.upperBound]))
                start = range.upperBound
            }
            return true
        }
        if start < text.endIndex {
            if parts.isEmpty { parts.append(String(text[start...])) } else { parts[parts.count - 1] += text[start...] }
        }
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Words that say nothing about the language: names and product words that
    /// agents use in every language.
    static let neutralWords: Set<String> = ["claude", "herdr", "homemade", "staging", "deploy", "deployment",
                                            "coolify", "infisical", "linear", "github", "pr", "ok", "okay"]
    /// Plus the user's name, with and without accents.
    static var neutral: Set<String> {
        guard let name = userName else { return neutralWords }
        let words = [name, name.folding(options: .diacriticInsensitive, locale: nil)]
            .flatMap { $0.lowercased().components(separatedBy: CharacterSet.letters.inverted) }.filter { !$0.isEmpty }
        return neutralWords.union(words)
    }

    // MARK: The user's name

    /// Settings → General → Your Name (the app's defaults).
    public static var userName: String? {
        let n = UserDefaults.standard.string(forKey: "userName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? nil : n
    }
    /// How each language's voice should spell the name so it sounds right
    /// (no UI): ["de": "…", "de.system": "…" (macOS's voice), "ru": "…"].
    public static let nameSpellingsKey = "userNameSpellings"
    static var nameSpellings: [String: String] {
        UserDefaults.standard.dictionary(forKey: nameSpellingsKey) as? [String: String] ?? [:]
    }

    /// The language of one sentence, or nil when it is too short or unclear.
    public static func detect(_ sentence: String, minWords: Int = 3) -> String? {
        let words = sentence.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        let telling = words.filter { !neutral.contains($0) }
        guard telling.count >= minWords || (telling.count >= 2 && words.count >= minWords) else { return nil }
        // Letters only one of the candidates uses settle it.
        let joined = telling.joined(separator: " ")
        if joined.range(of: "[ğış]", options: .regularExpression) != nil { return "tr" }
        if joined.range(of: "[ß]", options: .regularExpression) != nil { return "de" }
        if joined.range(of: "[а-яё]", options: .regularExpression) != nil { return "ru" }
        let r = NLLanguageRecognizer()
        r.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
        r.processString(joined)
        let hyp = r.languageHypotheses(withMaximum: 3)
        guard let (top, p) = hyp.max(by: { $0.value < $1.value }) else { return nil }
        // English needs less evidence than the others: an English reply with a
        // German product name must stay English.
        let en = hyp[.english] ?? 0
        if top != .english && (p < 0.6 || p - en < 0.3) { return en > 0.2 ? "en" : nil }
        if top == .english && p < 0.4 { return nil }
        return top.rawValue
    }

    // MARK: Names per language

    /// The text as the voice for `language` should read it: the user's name in
    /// the spelling set for that language (Kokoro has its own lexicon for
    /// English). Voices differ: Supertonic-3 and macOS's German voice can each
    /// need their own spelling, so "de.system" is tried first for macOS voices.
    public static func spoken(_ text: String, language: String, systemVoice: Bool = false) -> String {
        guard language != "en" else { return text }
        var t = text
        let spellings = nameSpellings
        if let name = userName,
           let sp = (systemVoice ? spellings[language + ".system"] : nil) ?? spellings[language] {
            let forms = Set([name, name.folding(options: .diacriticInsensitive, locale: nil)])
                .map(NSRegularExpression.escapedPattern(for:)).sorted { $0.count > $1.count }
            t = t.replacingOccurrences(of: "(?i)(?<![\\p{L}])(" + forms.joined(separator: "|") + ")(?![\\p{L}])", with: sp, options: .regularExpression)
        }
        if language == "de" { t = t.replacingOccurrences(of: #"(?i)\bherdr\b"#, with: "Hörder", options: .regularExpression) }
        return t
    }

    // MARK: Settings

    public static let languagesKey = "nativeVoiceLanguages"
    public static let removedKey = "nativeVoiceRemoved"
    public static func voiceKey(_ code: String) -> String { "nativeVoice.\(code)" }
    /// Supertonic-3's built-in speakers; F2 was the clearest in Turkish and German
    /// (Whisper read back both test lines word for word).
    public static let voices = ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"]
    public static let defaultVoice = "F2"

    public static func voiceLabel(_ v: String) -> String {
        guard let n = v.last else { return v }
        return (v.first == "F" ? "Female " : "Male ") + String(n)
    }

    /// Codes from a stored "tr,de" list, in `native` order.
    public static func parse(_ stored: String?) -> [String] {
        let picked = Set((stored ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return native.filter { picked.contains($0) }
    }
    public static func store(_ codes: [String]) -> String { parse(codes.joined(separator: ",")).joined(separator: ",") }

    /// Settings → Voice → Preview, one line per language, with the user's name.
    public static var samples: [String: String] {
        let n = userName
        let sp = n.map { " " + $0 } ?? ""
        return [
            "en": "Hi\(sp). This is how I sound when an agent needs you.",
            "tr": "Merhaba\(sp), bir ajanın sana ihtiyacı olduğunda böyle konuşurum.",
            "de": "Hallo\(sp), so klinge ich, wenn ein Agent dich braucht.",
            "fr": "Bonjour\(sp), voilà ma voix quand un agent a besoin de toi.",
            "it": "Ciao\(sp), ecco come suono quando un agente ha bisogno di te.",
            "ru": "Привет\(n.map { ", " + $0 } ?? "")! Так я звучу, когда тебе нужен агент.",
        ]
    }

    /// macOS voices used when the native voice is not downloaded or fails.
    public static let systemVoices: [String: [String]] = [
        "en": ["Samantha"], "tr": ["Yelda"], "de": ["Anna"], "fr": ["Thomas", "Amélie"], "it": ["Alice"], "ru": ["Milena"],
    ]
}
