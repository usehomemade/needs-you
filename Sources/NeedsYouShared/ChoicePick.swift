import Foundation

/// His answer to "Which chat? 1, recipebox. Or 2, orchard?" (HM-1364). The on-device
/// model reads it (HM-1399); this is what code still does: drop our own question when the
/// mic heard it, and, with no model, find a chat by the rare words of its name.
public enum ChoicePick {
    public static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Drops our own question when the mic heard it before his answer. The leading
    /// words that follow the question in order (loosely: "Witchchat" is "which chat")
    /// count as our echo when they include one of the question's own words, not
    /// only chat names or numbers, so "Portuguese bakery" alone stays his answer.
    public static func stripEcho(_ answer: String, question: String, names: [String] = []) -> String {
        let q = tokens(question), a = tokens(answer)
        guard !q.isEmpty, a.count >= 2 else { return answer }
        let nameWords = Set(names.flatMap { tokens($0) })
        func same(_ x: String, _ y: String) -> Bool {
            x == y || (min(x.count, y.count) >= 4 && similarity(x, y) >= 0.7)
        }
        var qi = 0, end = 0, misses = 0, scaffold = false, started = false
        var n = 0
        while n < a.count {
            let w = a[n]
            var hit: (j: Int, len: Int)?
            let window = started ? Array(q.indices.dropFirst(qi).prefix(3)) : Array(q.indices.dropFirst(qi))
            for j in window {
                if same(w, q[j]) { hit = (j, 1); break }
                if j + 1 < q.count, same(w, q[j] + q[j + 1]) { hit = (j, 2); break }
            }
            if let h = hit {
                started = true
                for k in h.j..<(h.j + h.len) where !nameWords.contains(q[k]) && !q[k].allSatisfy(\.isNumber) { scaffold = true }
                qi = h.j + h.len; end = n + 1; misses = 0
                if qi >= q.count { break }
            } else if started {
                misses += 1
                if misses > 1 { break }
            } else { break }
            n += 1
        }
        guard scaffold, end >= 2 else { return answer }
        return tokens(answer).dropFirst(end).joined(separator: " ")
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...max(y.count, 1) where !y.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count, 1))
    }

    /// How much each word says about which chat is meant: 1 / the number of chats whose
    /// name has it. A word most chats share ("claude", "code", "request") says little.
    /// Taken from the chat names themselves, so no word list decides it.
    public static func weights(_ corpus: [String]) -> [String: Double] {
        var df: [String: Int] = [:]
        for n in corpus { for w in Set(tokens(n)) { df[w, default: 0] += 1 } }
        return df.mapValues { 1 / Double($0) }
    }

    /// The option he named, 0-based: the name whose rarest words he said, with a clear lead.
    /// `corpus`: every chat name the weights come from (default: `names`).
    public static func name(_ answer: String, names: [String], corpus: [String]? = nil) -> Int? {
        let a = Set(tokens(answer))
        let wt = weights(corpus ?? names)
        let scored = names.enumerated().map { i, n -> (Int, Double) in
            let words = Array(Set(tokens(n).filter { $0.count > 2 }))
            guard !words.isEmpty else { return (i, 0) }
            let w = words.map { wt[$0] ?? 1 }
            // Saying the two rarest words of a name is saying the name.
            let full = w.sorted(by: >).prefix(2).reduce(0, +)
            let got = zip(words, w).filter { a.contains($0.0) }.map(\.1).reduce(0, +)
            return (i, min(1, got / full))
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= 0.5, (scored.dropFirst().first?.1 ?? 0) <= best.1 - 0.2 else { return nil }
        return best.0
    }
}
