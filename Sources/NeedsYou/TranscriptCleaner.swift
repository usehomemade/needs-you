import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// How the user's spoken words are passed on (Settings > Transcript).
enum TranscriptMode: String, CaseIterable, Identifiable {
    case verbatim, removeFillers, polish
    var id: String { rawValue }
    var label: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .removeFillers: return "Remove Fillers"
        case .polish: return "Polish"
        }
    }

    static var current: TranscriptMode {
        TranscriptMode(rawValue: UserDefaults.standard.string(forKey: "transcriptMode") ?? "") ?? .removeFillers
    }
}

enum TranscriptCleaner {
    static func clean(_ text: String, mode: TranscriptMode = .current) async -> String {
        switch mode {
        case .verbatim: return text
        case .removeFillers: return removeFillers(text)
        case .polish: return await polish(text) ?? removeFillers(text)
        }
    }

    // MARK: Remove fillers (rules only: deletes, never adds or rewords)

    private static let fillerWords = #"(?:u+h+m*|u+m+|a+h+|e+h+|e{2,}|e+r+m*|ä+h+m*|ö+h+m*|h+m+|m{2,}|mhm|uh-huh)"#
    private static let keepDoubled: Set<String> = ["had", "that", "is", "do", "very", "really", "no", "bye", "ha"]

    static func removeFillers(_ input: String) -> String {
        var s = input
        // 1. Filler words with their commas: "I think the, uh, period" -> "I think the period".
        // Between two commas both go: "that you, uh, set" -> "that you set".
        s = s.replacingOccurrences(of: #"(?i),\s*\#(fillerWords)\s*,(?=\s)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)(^|[\s,;])\#(fillerWords)(?=[\s,.;!?…-]|$)[,]?"#, with: "$1", options: .regularExpression)
        // 2. Stutters and cut-off restarts: "I- I think" / "th- the" -> "I think" / "the".
        s = s.replacingOccurrences(of: #"(?i)\b(\w{1,6})[-–—]+\s+(\1\w*)"#, with: "$2", options: .regularExpression)
        // 3. A phrase of 2-5 words said again right away: "I want to, I want to go" -> "I want to go".
        for _ in 0..<3 {
            s = s.replacingOccurrences(of: #"(?i)\b((?:[\w']+\s+){1,4}[\w']+)[,.…\-–—]*\s+\1\b"#, with: "$1", options: .regularExpression)
        }
        // 4. A single word said twice: "the the" -> "the" (but keep "had had", "that that").
        if let re = try? NSRegularExpression(pattern: #"(?i)\b([\w']+)(?:[,]?\s+\1\b)+"#) {
            let ns = s as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: m.range(at: 1))
                guard !keepDoubled.contains(word.lowercased()) else { continue }
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + word
                last = m.range.location + m.range.length
            }
            s = result + ns.substring(from: last)
        }
        // 5. Tidy punctuation and spacing left behind.
        s = s.replacingOccurrences(of: #"\s+([,.;!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*([,.;!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([.!?])\s*,+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;").union(.whitespacesAndNewlines))
        // Capital letter at the start and after sentence ends, where a filler was removed.
        s = capitalizeSentences(s)
        return s.isEmpty ? input : s
    }

    private static func capitalizeSentences(_ s: String) -> String {
        var out = ""
        var capNext = true
        for ch in s {
            if capNext, ch.isLetter { out += String(ch).uppercased(); capNext = false; continue }
            if ch == "." || ch == "!" || ch == "?" { capNext = true } else if !ch.isWhitespace { capNext = false }
            out.append(ch)
        }
        return out
    }

    // MARK: Polish (Apple's on-device model; nothing leaves the Mac)

    static var polishAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static func polish(_ text: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: """
                You clean up a spoken message so it reads clearly, in the language it was spoken in. Never translate it. Keep the meaning exactly. \
                Do not add facts, opinions, greetings or answers. Do not reply to the message. \
                Keep names, numbers, commands and technical words exactly as given. \
                Output only the rewritten message.
                """)
            do {
                let r = try await session.respond(to: removeFillers(text))
                let out = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return out.isEmpty ? nil : out
            } catch { return nil }
        }
        #endif
        return nil
    }
}
