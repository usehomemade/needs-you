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

    public init(title: String, label: String = "", folder: String = "", aliases: [String] = [], focused: Bool = false, isDesktop: Bool = false) {
        self.title = title; self.label = label; self.folder = folder
        self.aliases = aliases; self.focused = focused; self.isDesktop = isDesktop
    }
}

public enum ChatMatcher {
    /// What to do when the words before a colon match no chat and no project
    /// ("Hey Claude, two questions: ..."). Before HM-1364 this opened a new chat in
    /// the home folder. Flip to `.ask` to ask "Which chat?" instead.
    public enum UnmatchedName: Sendable { case chatInFront, ask }
    public static let unmatchedName: UnmatchedName = .chatInFront

    /// Weights per field: his tab label beats the folder, which beats the agent's title.
    public static let labelWeight = 1.0
    public static let aliasWeight = 0.9
    public static let folderWeight = 0.85
    public static let titleWeight = 0.7

    /// Tab labels that say nothing about the chat: Needs You's own "voice" for new
    /// chats, herdr's numbered defaults, and leftovers like "continue".
    public static let junkLabels: Set<String> = ["voice", "continue", "new", "new tab", "tab", "shell", "zsh", "bash", "fish", "terminal", "claude", "claude code", "codex", "test"]

    public static let stopwords: Set<String> = ["the", "a", "an", "to", "in", "on", "for", "and", "of", "chat", "session", "tab", "one", "window", "claude", "code"]

    public static let newChatPattern = #"^(?i)(?:a\s+|start\s+a\s+|open\s+a\s+)?new\s+(?:chat|session|conversation|claude)\b\s*(?:in|for|at|on)?\s*([^:,.]*?)\s*[:,.]\s*(.*)$"#
    public static let thisOne = #"^(?i)(this one|this chat|this window|this tab|this|here)\b[\s,.:;!-]*"#

    // MARK: Decision

    public enum Route: Equatable, Sendable {
        /// He named this chat. Focus moving later does not stop the send.
        case named(Int, String)
        /// The chat in front ("this one", no name, or a colon phrase that names nothing).
        /// nil when nothing is in front.
        case front(Int?, String)
        /// Unsure: ask between these (most likely first).
        case choose([Int], String, heardName: String)
        case newChat(String?, String)
    }

    /// Routes what came after the wake phrase. `isProject` says whether a heard name
    /// is a project folder (then "name: message" with no such chat opens a chat there).
    /// Returns the route and one line for the routing log.
    public static func route(_ rest: String, _ chats: [ChatCandidate], isProject: (String) -> Bool = { _ in false }) -> (Route, String) {
        let front = chats.firstIndex(where: { $0.isDesktop && $0.focused }) ?? chats.firstIndex(where: { $0.focused && !$0.isDesktop })

        // "new chat in <project>: <message>"
        if let re = try? NSRegularExpression(pattern: newChatPattern),
           let m = re.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let pr = Range(m.range(at: 1), in: rest), let mr = Range(m.range(at: 2), in: rest) {
            let project = rest[pr].trimmingCharacters(in: .whitespaces)
            return (.newChat(project.isEmpty ? nil : project, String(rest[mr])), "new chat: \"\(project)\"")
        }
        // "this one: ..."
        if let r = rest.range(of: thisOne, options: .regularExpression), !rest[r].trimmingCharacters(in: .whitespaces).isEmpty {
            return (.front(front, String(rest[r.upperBound...])), "this one -> " + name(front, chats))
        }
        // "<name>: <message>"
        if let colon = rest.firstIndex(of: ":"), rest.distance(from: rest.startIndex, to: colon) <= 60 {
            let heard = String(rest[..<colon])
            let message = String(rest[rest.index(after: colon)...])
            if heard.range(of: thisOne, options: .regularExpression) != nil,
               heard.trimmingCharacters(in: .whitespaces).split(separator: " ").count <= 2 {
                return (.front(front, message), "this one -> " + name(front, chats))
            }
            let ranked = rank(heard, chats)
            let log = "heard \"\(heard.trimmingCharacters(in: .whitespaces))\": " + describe(ranked, chats)
            if let best = ranked.first, best.score >= 0.5, (ranked.dropFirst().first?.score ?? 0) <= best.score - 0.2 {
                return (.named(best.index, message), log)
            }
            let options = ranked.filter { $0.score > 0 }.prefix(3).map(\.index)
            if !options.isEmpty { return (.choose(Array(options), message, heardName: heard), log) }
            let trimmed = heard.trimmingCharacters(in: .whitespaces)
            if isProject(trimmed) { return (.newChat(trimmed, message), log + "; project folder -> new chat") }
            // Names no chat and no project: it was part of the message ("two questions: ...").
            switch unmatchedName {
            case .chatInFront: return (.front(front, rest), log + "; no such chat -> whole sentence to " + name(front, chats))
            case .ask: return (.choose(Array(chats.indices.prefix(3)), rest, heardName: heard), log + "; no such chat -> ask")
            }
        }
        // "<name>, <message>" or "<name>. <message>" when that first clause is clearly a chat name.
        if let sep = rest.firstIndex(where: { $0 == "," || $0 == "." }), rest.distance(from: rest.startIndex, to: sep) <= 50 {
            let heard = String(rest[..<sep])
            let ranked = rank(heard, chats)
            if let best = ranked.first, best.score >= 0.6, (ranked.dropFirst().first?.score ?? 0) <= best.score - 0.25 {
                return (.named(best.index, String(rest[rest.index(after: sep)...])),
                        "heard \"\(heard.trimmingCharacters(in: .whitespaces))\": " + describe(ranked, chats))
            }
        }
        return (.front(front, rest), "no name -> " + name(front, chats))
    }

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
            if l.isEmpty || junkLabels.contains(l) || l.allSatisfy({ $0.isNumber || $0 == " " }) || (count[l] ?? 0) > 1 { return "" }
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
        func fieldScore(_ text: String) -> Double {
            guard !text.isEmpty else { return 0 }
            if !whole.isEmpty, squash(text) == whole { return 1 }
            let have = tokens(text.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))
            return Double(want.filter { w in have.contains { similar(w, $0) } }.count) / Double(want.count)
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

    public static func tokens(_ s: String) -> [String] { words(s).filter { !stopwords.contains($0) } }

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

    static func describe(_ ranked: [Score], _ chats: [ChatCandidate]) -> String {
        let top = ranked.prefix(3).filter { $0.score > 0 }
        if top.isEmpty { return "no chat matched" }
        return top.map { String(format: "\"%@\" %.2f (%@)", chats[$0.index].title, $0.score, $0.field) }.joined(separator: ", ")
    }
}
