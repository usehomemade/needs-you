import Foundation

/// One chat as the matcher sees it (HM-1364). The app builds these from its
/// targets (herdr panes, the Claude app); index order is kept in the results.
public struct ChatCandidate: Equatable, Sendable {
    /// The agent's own title ("Lisbon and Porto trip planner"). Claude Code sets it
    /// from the first prompt and never changes it, so it can be weeks out of date.
    public var title: String
    /// The tab label he gave it in herdr ("summer-trips"). Chosen by him, so it wins.
    public var label: String
    /// Last folder name of the chat's working directory; empty for the home folder.
    public var folder: String
    /// Other names (the Claude app's "desktop", a test pane's "test").
    public var aliases: [String]
    public var focused: Bool
    /// The Claude desktop app: in front, it counts as "this one" before any pane.
    public var isDesktop: Bool
    /// Chat apps: the chat open in it ("Learning to bake sourdough"); counts for the topic.
    public var detail = ""

    public init(title: String, label: String = "", folder: String = "", aliases: [String] = [], focused: Bool = false, isDesktop: Bool = false) {
        self.title = title; self.label = label; self.folder = folder
        self.aliases = aliases; self.focused = focused; self.isDesktop = isDesktop
    }
}

public enum ChatMatcher {
    /// Weights per field: his tab label beats the folder, which beats the agent's title.
    public static let labelWeight = 1.0
    public static let aliasWeight = 0.9
    public static let folderWeight = 0.85
    public static let titleWeight = 0.7

    // MARK: Ranking

    public struct Score: Equatable, Sendable {
        public var index: Int
        public var score: Double
        /// Which field matched best: "label", "folder", "title", "alias".
        public var field: String
    }

    /// Labels that can serve as a name: not junk, not only digits, and not shared by another chat.
    public static func usableLabels(_ chats: [ChatCandidate]) -> [String] {
        let labels = chats.map { cleanLabel($0.label) }
        var count: [String: Int] = [:]
        for l in labels where !l.isEmpty { count[l, default: 0] += 1 }
        return labels.map { l in
            if l.isEmpty || l.allSatisfy({ $0.isNumber || $0 == " " }) || (count[l] ?? 0) > 1 { return "" }
            return l
        }
    }

    /// "voice: orchard" (a chat Needs You started) names the project, not "voice".
    static func cleanLabel(_ label: String) -> String {
        var l = label.trimmingCharacters(in: .whitespaces).lowercased()
        if l.hasPrefix("voice:") { l = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if l.hasPrefix("needs-you test:") { l = String(l.dropFirst(15)).trimmingCharacters(in: .whitespaces) }
        return l
    }

    public static func rank(_ heard: String, _ chats: [ChatCandidate]) -> [Score] {
        let want = tokens(heard)
        guard !want.isEmpty else { return [] }
        let whole = squash(heard)
        let labels = usableLabels(chats)
        func split(_ t: String) -> [String] { tokens(t.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")) }
        // A heard word that most chats share ("claude", "code") counts for little: weight
        // 1 / the number of chats whose names have it. No word list decides this.
        let names = chats.enumerated().map { i, c in Set(split(([labels[i], c.folder, c.title] + c.aliases).joined(separator: " "))) }
        let weight = want.map { w -> Double in 1 / Double(max(1, names.filter { $0.contains { similar(w, $0) } }.count)) }
        let total = weight.reduce(0, +)
        func fieldScore(_ text: String) -> Double {
            guard !text.isEmpty else { return 0 }
            if !whole.isEmpty, squash(text) == whole { return 1 }
            let have = split(text)
            return zip(want, weight).filter { w, _ in have.contains { similar(w, $0) } }.map(\.1).reduce(0, +) / total
        }
        return chats.enumerated().map { i, c in
            var best = Score(index: i, score: 0, field: "")
            func consider(_ text: String, _ weight: Double, _ field: String) {
                let s = fieldScore(text) * weight
                if s > best.score { best = Score(index: i, score: s, field: field) }
            }
            consider(labels[i], labelWeight, "label")
            consider(c.folder, folderWeight, "folder")
            consider(c.title, titleWeight, "title")
            for a in c.aliases { consider(a, aliasWeight, "alias") }
            return best
        }
        .sorted { $0.score > $1.score || ($0.score == $1.score && $0.index < $1.index) }
    }

    // MARK: Words

    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    public static func tokens(_ s: String) -> [String] { words(s) }

    static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    public static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 4, b.count >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        if a.count >= 4, b.count >= 4 { return levenshtein(a, b) <= (max(a.count, b.count) >= 8 ? 2 : 1) }
        return false
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }

    // MARK: Log

    static func name(_ i: Int?, _ chats: [ChatCandidate]) -> String {
        guard let i else { return "nothing in front" }
        return "\"\(chats[i].title)\""
    }

    public static func describe(_ ranked: [Score], _ chats: [ChatCandidate]) -> String {
        let top = ranked.prefix(3).filter { $0.score > 0 }
        if top.isEmpty { return "no chat matched" }
        return top.map { String(format: "\"%@\" %.2f (%@)", chats[$0.index].title, $0.score, $0.field) }.joined(separator: ", ")
    }
}
