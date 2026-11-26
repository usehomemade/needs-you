import Foundation

/// Tells the app's own voice apart from the user's while it talks (HM-1410).
///
/// The stop detector listens while Needs You speaks. Echo cancellation removes most
/// of the voice, but some can leak back (loud speakers, a room with echo). What the
/// detector hears is compared with the text being spoken: when its words come, in
/// order, from that text, it is the voice itself and never stops playback.
/// A word-by-word transcript comparison, not a list of phrases.
public enum SpokenEcho {
    /// True when `heard` is (nearly) all words of `spoken`, in the same order.
    public static func isEcho(_ heard: String, spoken: String) -> Bool {
        let h = words(heard), s = words(spoken)
        guard !h.isEmpty else { return true } // nothing heard: nothing to act on
        guard !s.isEmpty else { return false }
        var j = 0, matched = 0
        for w in h {
            var k = j
            while k < s.count, !similar(w, s[k]) { k += 1 }
            if k < s.count { matched += 1; j = k + 1 }
        }
        // One stray word in four is allowed: recognizers mishear a word now and then.
        return Double(matched) / Double(h.count) >= 0.75
    }

    /// Lowercased words without punctuation or accents.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// Same word, a cut-off partial of it ("Ma" for "Mac"), or one letter apart.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 2, b.hasPrefix(a) { return true }
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 1 else { return false }
        return distance(Array(a), Array(b)) <= 1
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for k in 1...max(1, b.count) where !b.isEmpty {
                cur[k] = min(prev[k] + 1, cur[k - 1] + 1, prev[k - 1] + (a[i - 1] == b[k - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
