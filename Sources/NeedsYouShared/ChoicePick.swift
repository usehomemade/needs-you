import Foundation

/// His answer to "Which chat? 1, recipebox. Or 2, orchard?" (HM-1364).
public enum ChoicePick {
    /// Number words in English, Turkish and German. Values are 1-based.
    static let numbers: [String: Int] = [
        "1": 1, "one": 1, "won": 1, "first": 1, "bir": 1, "birinci": 1, "eins": 1, "erste": 1, "ersten": 1, "erstes": 1,
        "2": 2, "two": 2, "second": 2, "iki": 2, "ikinci": 2, "zwei": 2, "zweite": 2, "zweiten": 2, "zwo": 2,
        "3": 3, "three": 3, "third": 3, "üç": 3, "uc": 3, "uç": 3, "üçüncü": 3, "drei": 3, "dritte": 3, "dritten": 3,
        "4": 4, "four": 4, "fourth": 4, "dört": 4, "dort": 4, "dördüncü": 4, "vier": 4, "vierte": 4, "vierten": 4,
    ]
    /// Mishearings of a lone number ("Two." often comes back as "To.").
    static let soundsLike: [String: Int] = ["to": 2, "too": 2, "tu": 2, "for": 4, "fore": 4, "tree": 3, "free": 3]

    public static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Drops our own question when the mic heard it before his answer. The leading
    /// words that follow the question in order (loosely: "Witchchat" is "which chat")
    /// count as our echo when they include one of the question's own words, not
    /// only chat names or numbers, so "Portuguese bakery" alone stays his answer.
    public static func stripEcho(_ answer: String, question: String, names: [String] = []) -> String {
        let q = tokens(question).map(spelled), a = tokens(answer).map(spelled)
        guard !q.isEmpty, a.count >= 2 else { return answer }
        let nameWords = Set(names.flatMap { tokens($0).map(spelled) })
        let numberWords = Set(numbers.keys.map(spelled))
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
                for k in h.j..<(h.j + h.len) where !nameWords.contains(q[k]) && !numberWords.contains(q[k]) { scaffold = true }
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

    /// Digits as the voice says them, so "2" in the question matches "two" heard.
    static func spelled(_ w: String) -> String {
        ["1": "one", "2": "two", "3": "three", "4": "four"][w] ?? w
    }

    /// The number he said, 0-based, among `count` options. "The second one" is 2:
    /// "one" counts only when no other number was said.
    public static func number(_ answer: String, count: Int) -> Int? {
        let w = tokens(answer)
        guard !w.isEmpty, w.count <= 8 else { return nil }
        // One option ("Which chat? orchard?"): yes picks it.
        if count == 1, w.count <= 4, !Set(w).isDisjoint(with: ["yes", "yeah", "yep", "sure", "okay", "ok", "evet", "ja", "correct", "right"]) { return 0 }
        var found = Set<Int>(), ones = false
        for t in w {
            if let n = numbers[t] { if n == 1 && (t == "one" || t == "won") { ones = true } else { found.insert(n) } }
            else if w.count <= 3, let n = soundsLike[t] { found.insert(n) }
        }
        if found.isEmpty && ones { found = [1] }
        guard found.count == 1, let n = found.first, n <= count else { return nil }
        return n - 1
    }

    /// The option he named, 0-based: most of a name's words, and only one name fits.
    public static func name(_ answer: String, names: [String]) -> Int? {
        let a = Set(tokens(answer))
        let scored = names.enumerated().map { i, n -> (Int, Double) in
            let words = tokens(n).filter { $0.count > 2 }
            guard !words.isEmpty else { return (i, 0) }
            return (i, Double(words.filter(a.contains).count) / Double(min(words.count, 2)))
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= 0.5, (scored.dropFirst().first?.1 ?? 0) < best.1 else { return nil }
        return best.0
    }

    /// Echo removed, then a number, then a name.
    public static func pick(_ answer: String, question: String, names: [String]) -> Int? {
        let clean = stripEcho(answer, question: question, names: names)
        let named = name(clean, names: names)
        // "The Portuguese one": "one" is a pronoun when a name was said.
        let onlyOne = tokens(clean).allSatisfy { numbers[$0] == nil || $0 == "one" || $0 == "won" }
        if let named, onlyOne { return named }
        return number(clean, count: names.count) ?? named
    }
}
