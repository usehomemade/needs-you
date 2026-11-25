import Foundation

/// Which window or tab on screen holds a registered chat (HM-1374). Pure scoring
/// so it can be unit-tested; the Accessibility reading lives in the app
/// (`AXDelivery`). One generic rule set for every app: no per-app code.
public enum AXMatch {
    /// What the chat's agent told us about itself (MCP registration and hooks).
    public struct Hint: Equatable, Sendable {
        public var cwd: String
        /// Words that name the chat: folder, herdr tab label, status line.
        public var names: [String]
        /// Text that should be on its screen when it is idle: the last reply, the last prompts.
        public var texts: [String]

        public init(cwd: String, names: [String] = [], texts: [String] = []) {
            self.cwd = cwd; self.names = names; self.texts = texts
        }

        public var folder: String {
            let home = NSHomeDirectory()
            if cwd.isEmpty || cwd == home || cwd + "/" == home { return "" }
            return (cwd as NSString).lastPathComponent
        }
    }

    /// One place a chat could be: a window, or one tab of it.
    public struct Place: Equatable, Sendable {
        public var title: String
        /// AXDocument (Terminal, Ghostty: the shell's folder from OSC 7), as a path or file URL.
        public var document: String
        /// Visible text (terminal screen, web text); empty when the app exposes none or the tab is in the background.
        public var screen: String

        public init(title: String, document: String = "", screen: String = "") {
            self.title = title; self.document = document; self.screen = screen
        }
    }

    public struct Scored: Equatable, Sendable {
        public var score: Double
        public var why: [String]
    }

    public static func path(_ s: String) -> String {
        var p = s
        if p.hasPrefix("file://") { p = URL(string: p)?.path ?? String(p.dropFirst(7)) }
        p = p.removingPercentEncoding ?? p
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        // /private/tmp and /tmp are the same folder.
        if p.hasPrefix("/private/") { p = String(p.dropFirst(8)) }
        return p
    }

    /// A folder as titles write it: full, without /private, with ~ for the home folder.
    static func pathForms(_ cwd: String) -> [String] {
        let p = path(cwd), home = path(NSHomeDirectory())
        var out = [cwd, p, "/private" + p]
        if p.hasPrefix(home + "/") { out.append("~" + p.dropFirst(home.count)) }
        return Array(Set(out.filter { !$0.isEmpty }))
    }

    /// `q` as a whole word (letters, digits, `-` and `_` count as word characters).
    public static func hasWord(_ hay: String, _ q: String) -> Bool {
        guard !q.isEmpty else { return false }
        let esc = NSRegularExpression.escapedPattern(for: q)
        return hay.range(of: "(^|[^A-Za-z0-9_-])" + esc + "($|[^A-Za-z0-9_-])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func squash(_ s: String) -> String {
        s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Pieces of a text worth looking for on screen: lines of 16+ characters,
    /// cut to 60 (terminals wrap long lines, so short pieces survive).
    static func snippets(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { squash($0.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "*", with: "")) }
            .filter { $0.count >= 16 }
            .map { String($0.prefix(60)) }
            .prefix(4).map { $0 }
    }

    public static func score(_ p: Place, _ h: Hint) -> Scored {
        var s = 0.0, why: [String] = []
        let cwd = path(h.cwd)
        let doc = path(p.document)
        if !cwd.isEmpty, !doc.isEmpty, doc == cwd { s += 3; why.append("folder (document)") }
        else if !cwd.isEmpty, cwd != path(NSHomeDirectory()), pathForms(h.cwd).contains(where: { hasWord(p.title, $0) }) { s += 3; why.append("folder (title)") }
        else if h.folder.count >= 3, hasWord(p.title, h.folder) { s += 1.5; why.append("folder name in title") }
        for n in h.names where n.count >= 3 && n.lowercased() != h.folder.lowercased() && hasWord(p.title, n) { s += 0.5; why.append("name \u{201C}\(n)\u{201D}"); break }
        if !p.screen.isEmpty {
            let screen = squash(p.screen)
            if h.texts.flatMap(snippets).contains(where: { screen.contains($0) }) { s += 3; why.append("its text on screen") }
        }
        return Scored(score: s, why: why)
    }

    /// The one place that clearly holds the chat, or nil (then nothing is typed).
    /// `alone`: the only place in the app that owns the chat's process (a strong hint on its own).
    public static func pick(_ scores: [Scored], alone: Bool = false) -> Int? {
        guard let best = scores.indices.max(by: { scores[$0].score < scores[$1].score }) else { return nil }
        let second = scores.indices.filter { $0 != best }.map { scores[$0].score }.max() ?? 0
        if alone && scores.count == 1 { return best }
        guard scores[best].score >= 1.5, scores[best].score - second >= 1 else { return nil }
        return best
    }
}
