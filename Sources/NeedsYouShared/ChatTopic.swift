import Foundation

extension ChatMatcher {
    /// The chat a message is about when it names none ("how is the orchard linter going"):
    /// the one sharing the most words with it (folder, tab label, title, what it works on).
    /// nil when nothing is shared or two chats tie. A chat app counts only by the chat open in it.
    /// `minScore`: how many rare words' worth it must share (1 / the chats that have each word).
    public static func topic(_ message: String, _ chats: [ChatCandidate], minScore: Double = 0) -> Int? {
        let want = Set(tokens(message).filter { $0.count >= 3 })
        guard !want.isEmpty else { return nil }
        let labels = usableLabels(chats)
        let texts = chats.enumerated().map { i, c -> [String] in
            if c.isDesktop && c.detail.isEmpty { return [] }
            let text = (c.isDesktop ? [c.detail] : [labels[i], c.folder, c.title]).joined(separator: " ")
                .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return tokens(text)
        }
        // A word many chats share ("request") counts for little: 1 / the chats that have it.
        let hits = want.map { w in texts.map { t in t.contains { similar(w, $0) } } }
        let weight = hits.map { h in 1 / Double(max(1, h.filter { $0 }.count)) }
        let scores = chats.indices.map { i in zip(hits, weight).filter { $0.0[i] }.map(\.1).reduce(0, +) }
        let ranked = scores.enumerated().sorted { $0.element > $1.element }
        guard let best = ranked.first, best.element > 0, best.element >= minScore else { return nil }
        // A clear lead: more than one more word's worth than the next chat.
        if ranked.count > 1, ranked[1].element > 0, best.element - ranked[1].element < 1 { return nil }
        return best.offset
    }
}
