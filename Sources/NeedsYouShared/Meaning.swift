import Foundation

/// What a message is about, compared with what each chat is about (HM-1408). The app turns
/// text into sentence vectors on the Mac (NaturalLanguage); this is the arithmetic on them,
/// so it can be tested without the embedding model. No word list decides anything here.
public enum Meaning {
    public struct Score: Equatable, Sendable {
        public var index: Int
        public var sim: Double
        public init(index: Int, sim: Double) { self.index = index; self.sim = sim }
    }

    /// Lead over the next chat that lets meaning confirm the model (or the learned votes).
    public static let agreeMargin = 0.04
    /// Lead and similarity that let meaning decide on its own, when nothing disagrees.
    public static let veryClearMargin = 0.12
    public static let veryClearSim = 0.4
    /// Below this nothing is "about" the chat at all.
    public static let minSim = 0.25

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0, x: Float = 0, y: Float = 0
        for i in a.indices { d += a[i] * b[i]; x += a[i] * a[i]; y += b[i] * b[i] }
        let n = (x * y).squareRoot()
        return n > 0 ? Double(d / n) : 0
    }

    /// How close a message is to a chat: its closest part (title, folder, status, a prompt,
    /// a sentence of its last reply). One long description blurs; its parts do not.
    public static func similarity(_ message: [Float], parts: [[Float]]) -> Double? {
        parts.map { cosine(message, $0) }.max()
    }

    /// Chats by similarity, best first. A chat with no parts (nothing known about it) is left out.
    public static func rank(_ message: [Float], _ chats: [[[Float]]], excluding: Set<Int> = []) -> [Score] {
        chats.enumerated().compactMap { i, parts -> Score? in
            guard !excluding.contains(i), let s = similarity(message, parts: parts) else { return nil }
            return Score(index: i, sim: s)
        }.sorted { $0.sim > $1.sim || ($0.sim == $1.sim && $0.index < $1.index) }
    }

    /// The best chat when it leads the next one by `margin` and is at least `minSim` close.
    public static func leader(_ ranked: [Score], margin: Double = agreeMargin, minSim: Double = minSim) -> Int? {
        guard let best = ranked.first, best.sim >= minSim else { return nil }
        if ranked.count > 1, best.sim - ranked[1].sim < margin { return nil }
        return best.index
    }

    public static func veryClear(_ ranked: [Score]) -> Int? {
        leader(ranked, margin: veryClearMargin, minSim: veryClearSim)
    }

    /// "1 0.51, 3 0.36, 2 0.22" (1-based), for logs.
    public static func describe(_ ranked: [Score], max: Int = 3) -> String {
        ranked.isEmpty ? "none" : ranked.prefix(max).map { String(format: "%d %.2f", $0.index + 1, $0.sim) }.joined(separator: ", ")
    }
}
