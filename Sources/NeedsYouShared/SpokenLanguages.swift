import Foundation

/// The languages the user usually speaks to Needs You (Settings → Microphones → Languages
/// I Usually Speak, HM-1351, HM-1362). Whisper scores every language for each utterance,
/// with these ones favoured; another language counts once it is clear (`LanguagePick`).
/// "Only these languages" (`strict`, off by default) keeps Whisper to the picked ones,
/// and English only + strict is the old English-only path. Never translated.
public enum SpokenLanguages {
    public struct Language: Hashable, Identifiable {
        public var code: String   // Whisper's language code
        public var name: String
        public var id: String { code }
    }

    public static let all: [Language] = [
        Language(code: "en", name: "English"),
        Language(code: "tr", name: "Turkish"),
        Language(code: "de", name: "German"),
        Language(code: "fr", name: "French"),
        Language(code: "it", name: "Italian"),
        Language(code: "ru", name: "Russian"),
    ]

    public static let defaultsKey = "spokenLanguages"

    /// "en,tr" -> ["en", "tr"], in the order of `all`; unknown codes dropped;
    /// never empty (English when nothing valid is stored).
    public static func parse(_ stored: String?) -> [String] {
        let picked = Set((stored ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let codes = all.map(\.code).filter { picked.contains($0) }
        return codes.isEmpty ? ["en"] : codes
    }

    public static func store(_ codes: [String]) -> String { parse(codes.joined(separator: ",")).joined(separator: ",") }

    public static var enabled: [String] { parse(UserDefaults.standard.string(forKey: defaultsKey)) }
    /// Settings: "Only these languages" (HM-1362). Off: any language he speaks is followed.
    public static let strictKey = "onlyPickedLanguages"
    public static var strict: Bool { UserDefaults.standard.bool(forKey: strictKey) }
    /// The old English-only path (Parakeet for everything quick, Whisper forced to English):
    /// only when he picked English alone and turned on "Only these languages".
    public static var onlyEnglish: Bool { strict && enabled == ["en"] }

    public static func name(_ code: String) -> String {
        all.first { $0.code == code }?.name ?? Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    // MARK: End words ("done") per language

    /// Words that end his turn, like "done" / "that's it" in English. Only counted
    /// when they stand alone at the end (after the start, a comma or a full stop):
    /// Turkish and German put the verb last, so "Test bitti." ("the test is done")
    /// is a sentence, not an end word, while "Testleri çalıştır, bitti." ends.
    public static let endWords: [String: [String]] = [
        "tr": ["tamam", "tamamdır", "bitti", "bu kadar", "o kadar"],
        "de": ["fertig", "das war's", "das wars", "das war es", "das ist alles", "ende"],
        "fr": ["fini", "terminé", "c'est tout", "c'est fini", "voilà"],
        "it": ["finito", "ho finito", "fatto", "è tutto", "basta"],
        "ru": ["готово", "всё", "это всё", "это все", "конец"],
    ]

    private static func pattern(_ words: [String]) -> String {
        let alts = words.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: "'", with: "['’]?") }
            .joined(separator: "|")
        // Start of text or a sentence/clause break, the end word, then only punctuation.
        return #"(?i)(^|[,.;:!?\-–—…]\s*)(\#(alts))[\s.!?…]*$"#
    }

    private static func match(_ text: String, languages: [String]) -> Range<String.Index>? {
        for code in languages where code != "en" {
            guard let words = endWords[code] else { continue }
            if let r = text.range(of: pattern(words), options: .regularExpression) { return r }
        }
        return nil
    }

    /// True when `text` ends on a standalone end word of one of `languages` (English excluded:
    /// its own, older rule lives in the app).
    public static func endsWithEndWord(_ text: String, languages: [String] = enabled) -> Bool {
        match(text.trimmingCharacters(in: .whitespacesAndNewlines), languages: languages) != nil
    }

    /// Removes a standalone end word at the end ("Testleri çalıştır, bitti." ->
    /// "Testleri çalıştır"). Keeps the text when nothing else would be left: a lone
    /// "Tamam." is his answer ("okay"), not an empty turn.
    public static func stripEndWord(_ text: String, languages: [String] = enabled) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = match(t, languages: languages) else { return text }
        var head = String(t[..<r.lowerBound])
        // Keep the break before it only when it ends a sentence.
        let lead = t[r].prefix { ",.;:!?-–—… ".contains($0) }
        if lead.contains(where: { ".!?…".contains($0) }) { head += "." }
        head = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-–— ")).isEmpty ? text : head
    }
}
