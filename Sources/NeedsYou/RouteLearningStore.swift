import Foundation
import NaturalLanguage
import NeedsYouShared

/// route-matches.json in Application Support (HM-1408): the last 500 messages that found
/// their chat, as sentence vectors. Earlier picks in the old word-keyed routing-memory.json
/// are moved over once (their words embedded).
@MainActor final class RouteLearningStore {
    static let shared = RouteLearningStore()
    private let url = Wire.supportDir.appendingPathComponent("route-matches.json")
    private let legacyURL = Wire.supportDir.appendingPathComponent("routing-memory.json")
    private(set) lazy var learning: RouteLearning = load()

    private func load() -> RouteLearning {
        if let l = RouteLearning.load(url) { return l }
        var l = RouteLearning()
        let old = RouteLearning.Legacy.load(legacyURL)
        for e in old {
            let lang = MeaningIndex.shared.language(e.words)
            guard let v = MeaningIndex.shared.vector(e.words, lang) else { continue }
            l.add(text: e.words, key: e.key, name: e.name, source: "earlier", lang: lang.rawValue, vector: v, at: e.at)
        }
        if !old.isEmpty {
            l.save(url)
            Isolation.note("route learning: moved \(l.matches.count) of \(old.count) earlier picks over")
        }
        return l
    }

    /// A message found its chat: remember it, so messages like it lean to that chat.
    func learn(_ text: String, target: ChatTarget, source: String) {
        let lang = MeaningIndex.shared.language(text)
        guard let v = MeaningIndex.shared.vector(text, lang) else { return }
        learning.add(text: text, key: target.memoryKey, name: target.title, source: source, lang: lang.rawValue, vector: v)
        if !Prefs.readOnly { learning.save(url) }
        Isolation.note("route learning: \u{201C}\(text.prefix(60))\u{201D} -> \(target.memoryKey) (\(source), \(learning.matches.count) kept)")
    }

    /// Votes for the open targets, strongest first (target indices; a key two targets share votes for the first).
    func votes(_ vector: [Float]?, lang: NLLanguage, targets: [ChatTarget]) -> [(vote: RouteLearning.Vote, index: Int)] {
        guard let vector else { return [] }
        let keys = Set(targets.map(\.memoryKey))
        return learning.votes(vector, lang: lang.rawValue, among: keys).compactMap { v in
            targets.firstIndex { $0.memoryKey == v.key }.map { (v, $0) }
        }
    }

    func examples(_ targets: [ChatTarget]) -> [RouteLearning.Match] { learning.examples(among: Set(targets.map(\.memoryKey))) }
}
