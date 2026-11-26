import Foundation
import NaturalLanguage
import NeedsYouShared

/// Sentence vectors on the Mac (NaturalLanguage, HM-1408): what a message means next to what
/// each chat is about (title, folder, tab label, status, recent prompts, its last reply; for a
/// chat app the chat open in it). The language is the message's, English when the Mac has no
/// sentence model for it. Vectors of chat parts are cached; `Meaning` does the arithmetic.
@MainActor final class MeaningIndex {
    static let shared = MeaningIndex()

    private var models: [String: NLEmbedding?] = [:]
    private var cache: [String: [Float]] = [:]

    /// The message's language when the Mac has a sentence model for it, else English.
    func language(_ text: String) -> NLLanguage {
        if let l = NLLanguageRecognizer.dominantLanguage(for: text), l != .english, model(l) != nil { return l }
        return .english
    }

    private func model(_ lang: NLLanguage) -> NLEmbedding? {
        if let m = models[lang.rawValue] { return m }
        let m = NLEmbedding.sentenceEmbedding(for: lang)
        models[lang.rawValue] = m
        return m
    }

    var available: Bool { model(.english) != nil }

    func vector(_ text: String, _ lang: NLLanguage) -> [Float]? {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        guard !t.isEmpty, let m = model(lang) else { return nil }
        let k = lang.rawValue + "|" + t
        if let v = cache[k] { return v }
        guard let v = m.vector(for: t) else { return nil }
        let f = v.map(Float.init)
        if cache.count > 3000 { cache.removeAll() }
        cache[k] = f
        return f
    }

    /// What a chat is about, in parts (one long description blurs, so each is compared on its own).
    func parts(_ t: ChatTarget) -> [String] {
        var out: [String] = []
        func add(_ s: String?) {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !s.hasPrefix("<") else { return }
            let clean = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            if !out.contains(clean) { out.append(clean) }
        }
        if t.kind == .desktop {
            add(t.detail) // the chat open in the app, or the sidebar chat's title
            return out
        }
        add(t.title); add(t.folder); add(t.label)
        for p in t.detail.components(separatedBy: "; ") {
            add(p.hasPrefix("last asked: ") ? String(p.dropFirst(12)) : p)
        }
        if t.kind == .registered, let c = ChatRegistry.shared.chats[t.id] {
            add(c.status)
            for p in c.prompts { add(String(p.prefix(300))) }
            if let reply = c.lastReply {
                let tok = NLTokenizer(unit: .sentence)
                tok.string = reply
                var n = 0
                tok.enumerateTokens(in: reply.startIndex..<reply.endIndex) { r, _ in
                    add(String(reply[r].prefix(300))); n += 1
                    return n < 5
                }
            }
        }
        return out
    }

    struct Result {
        var lang: NLLanguage
        var vector: [Float]?
        var scores: [Meaning.Score]
    }

    /// The targets ranked by how close `text` is to what each is about. `excluding`: indices left out.
    func rank(_ text: String, _ targets: [ChatTarget], excluding: Set<Int> = []) -> Result {
        let lang = language(text)
        guard let v = vector(text, lang) else { return Result(lang: lang, vector: nil, scores: []) }
        let chats = targets.map { t in parts(t).compactMap { vector($0, lang) } }
        return Result(lang: lang, vector: v, scores: Meaning.rank(v, chats, excluding: excluding))
    }
}
