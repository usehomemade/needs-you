import CryptoKit
import Foundation

/// The app's own agent instructions (HM-1355). Needs You writes them to
/// `~/.claude/needs-you.md` and keeps one import line, `@needs-you.md`, in
/// `~/.claude/CLAUDE.md` inside a marked block. Claude Code expands `@path`
/// imports relative to the file that holds them, and loads imports in
/// user-scope memory files without asking.
///
/// The user may edit needs-you.md. The app only overwrites it while it still holds
/// exactly what the app last wrote; otherwise the new default goes to
/// needs-you.default.md and Settings → Agents offers the choice.
///
/// Nothing outside the marked block in CLAUDE.md is changed automatically. The
/// old hand-written "## Needs You: ask … out loud" section is removed only
/// by `removeLegacySection()`, which the app calls after they click Remove.
public struct AgentInstructions {
    /// Bump when `defaultText` changes.
    public static let version = 3

    public static let fileName = "needs-you.md"
    public static let defaultFileName = "needs-you.default.md"
    public static let beginMarker = "<!-- needs-you:begin -->"
    public static let endMarker = "<!-- needs-you:end -->"
    /// The heading of the old hand-written section ("## Needs You: ask <name> out loud").
    public static let legacyHeadingPrefix = "## Needs You: ask "
    public static let legacyHeadingSuffix = " out loud"
    public static var block: String { "\(beginMarker)\n@\(fileName)\n\(endMarker)" }

    /// The instructions for agents. `name` is the user's name from Settings →
    /// General; without one they say "the user".
    public static func defaultText(name: String? = nil) -> String {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let who = n.isEmpty ? "the user" : n
        let Who = n.isEmpty ? "The user" : n
        return """
        ## Needs You: ask \(who) out loud

        This file is installed and kept up to date by the Needs You app (Settings → Agents). \(Who) may edit it; the app then keeps their version.

        - When you need \(who) (a decision, approval, login or 2FA tap, anything blocking), run `needs-you ask "<one or two spoken sentences>" --title "<short title>" --context <file or text with the exact steps/commands>` (Bash timeout 600000). Never put secrets in the text or context.
        - It speaks on their Mac, listens, and prints JSON. Exit 0: their words are in `transcript`. Exit 2 with `status: "voicemail"`: they did not answer, or Do Not Disturb is on (then nothing was spoken). Your request is kept as a voicemail; they hear it when they are back and their answer arrives in your chat as a voice message. It asks once: carry on with other work and do not ask again.
        - Follow-ups: answer them with `needs-you say "<reply>"` (it speaks, then listens and returns their next words). Keep looping while they talk; end with `needs-you done "<short closing>"`. `--no-listen` speaks without waiting.
        - Anything that needs an answer (a question, a choice, "now or later?") must listen: use `ask`, or `say` without `--no-listen` inside a conversation. `--no-listen` is only for news that needs no reply; never end a `--no-listen` line with a question.
        - `status: "interrupted"` means they said "Stop, Mac" or pressed their turn shortcut while you were talking: `spoken_until` is what they heard, `transcript` is what they said after. Take that into account and reply with `say`. If they pressed Escape instead, `transcript` is empty, `state` says so and the conversation is closed: do not repeat it.
        - One conversation at a time; your ask waits its turn. Pass `--project <label>` when the folder name does not say which project it is.
        - Voice messages: a message from \(who) that ends with `(sent by voice: reply by voice with needs-you)` came from their voice ("Hey Mac, <chat name>: <message>" or their turn shortcut). Reply out loud with `needs-you ask "<reply>"` when you need an answer from them, or `needs-you say "<reply>" --no-listen` when you don't. Keep the spoken reply brief and to the point, but give enough detail that they don't need to read the screen, and ask anything they need to decide. Also write the full answer in text as usual. If they keep asking follow-ups by voice, go deeper.
        - Only the main agent talks to \(who). Subagents never run needs-you: they put the question in their report and the main agent asks.
        - Never run `needs-you wake-test` against real chats; tests use an armed throwaway herdr pane only.

        """
    }

    /// What the app remembers between launches (per target folder).
    public struct Record: Codable, Equatable {
        /// Hash of the text the app last wrote to needs-you.md.
        public var writtenHash: String?
        /// A new default he chose to ignore ("Keep Mine").
        public var dismissedDefaultHash: String?
        public init(writtenHash: String? = nil, dismissedDefaultHash: String? = nil) {
            self.writtenHash = writtenHash
            self.dismissedDefaultHash = dismissedDefaultHash
        }
    }

    public struct Status: Equatable {
        public var enabled: Bool
        /// The import block is in CLAUDE.md.
        public var imported: Bool
        /// needs-you.md differs from what the app last wrote.
        public var edited: Bool
        /// He edited it and the bundled default has changed since: offer the choice.
        public var newDefaultWaiting: Bool
        /// The old hand-written section is still in CLAUDE.md, outside the block.
        public var legacySection: String?
    }

    public let dir: URL
    public var defaultText: String
    public var record: Record

    public init(dir: URL, defaultText: String = AgentInstructions.defaultText(), record: Record = Record()) {
        self.dir = dir
        self.defaultText = defaultText
        self.record = record
    }

    /// `NEEDS_YOU_CLAUDE_DIR` overrides `~/.claude` (tests, the UI demo).
    public static func targetDir(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let d = env["NEEDS_YOU_CLAUDE_DIR"], !d.isEmpty { return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    public var fileURL: URL { dir.appendingPathComponent(Self.fileName) }
    public var defaultFileURL: URL { dir.appendingPathComponent(Self.defaultFileName) }
    public var claudeMDURL: URL { dir.appendingPathComponent("CLAUDE.md") }
    public var backupURL: URL { dir.appendingPathComponent("CLAUDE.md.needs-you-backup") }

    public static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Sync

    /// Install or update needs-you.md and the import block. Safe to run on every launch.
    @discardableResult
    public mutating func sync() throws -> Status {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaultHash = Self.hash(defaultText)
        if let current = read(fileURL) {
            let h = Self.hash(current)
            if h == defaultHash {
                record.writtenHash = defaultHash
                try? FileManager.default.removeItem(at: defaultFileURL)
            } else if h == record.writtenHash {
                // Unchanged since the app wrote it: an older default. Update it.
                try write(defaultText, to: fileURL)
                record.writtenHash = defaultHash
                try? FileManager.default.removeItem(at: defaultFileURL)
            } else if defaultHash != record.writtenHash && defaultHash != record.dismissedDefaultHash {
                // His edits: keep them, park the new default next to it.
                try write(defaultText, to: defaultFileURL)
            }
        } else {
            try write(defaultText, to: fileURL)
            record.writtenHash = defaultHash
        }
        try ensureImport()
        return status(enabled: true)
    }

    /// Takes the import block out of CLAUDE.md (needs-you.md stays).
    public func disable() throws {
        guard let md = read(claudeMDURL), let r = Self.blockRange(in: md) else { return }
        var out = md
        out.removeSubrange(r)
        try backupOnce()
        try write(Self.tidy(out), to: claudeMDURL)
    }

    public func status(enabled: Bool) -> Status {
        let md = read(claudeMDURL) ?? ""
        let current = read(fileURL)
        let defaultHash = Self.hash(defaultText)
        let edited = current.map { Self.hash($0) != record.writtenHash && Self.hash($0) != defaultHash } ?? false
        let waiting = edited && defaultHash != record.writtenHash && defaultHash != record.dismissedDefaultHash
        return Status(enabled: enabled, imported: Self.blockRange(in: md) != nil, edited: edited,
                      newDefaultWaiting: waiting, legacySection: Self.legacySection(in: md).map { String(md[$0]) })
    }

    /// "Use New Default": replace his file with the bundled text.
    public mutating func useNewDefault() throws {
        try write(defaultText, to: fileURL)
        record.writtenHash = Self.hash(defaultText)
        try? FileManager.default.removeItem(at: defaultFileURL)
    }

    /// "Keep Mine": stop offering this default.
    public mutating func keepMine() {
        record.dismissedDefaultHash = Self.hash(defaultText)
        try? FileManager.default.removeItem(at: defaultFileURL)
    }

    /// Removes the old hand-written section from CLAUDE.md. Call only after he clicked Remove.
    public func removeLegacySection() throws {
        guard let md = read(claudeMDURL), let r = Self.legacySection(in: md) else { return }
        var out = md
        out.removeSubrange(r)
        try backupOnce()
        try write(Self.tidy(out), to: claudeMDURL)
    }

    /// A unified-style line diff of his file against the bundled default.
    public func diff() -> String {
        Self.lineDiff(old: read(fileURL) ?? "", new: defaultText, oldName: Self.fileName, newName: "new default")
    }

    // MARK: Text helpers (pure, tested)

    /// The marked block, including its markers and one trailing newline.
    public static func blockRange(in md: String) -> Range<String.Index>? {
        guard let b = md.range(of: beginMarker), let e = md.range(of: endMarker, range: b.upperBound..<md.endIndex) else { return nil }
        var end = e.upperBound
        if end < md.endIndex, md[end] == "\n" { end = md.index(after: end) }
        return b.lowerBound..<end
    }

    /// Adds or repairs the import block; returns nil when CLAUDE.md is already right.
    public static func withImport(_ md: String) -> String? {
        if let r = blockRange(in: md) {
            let existing = md[r].trimmingCharacters(in: .newlines)
            if existing == block { return nil }
            var out = md
            out.replaceSubrange(r, with: block + "\n")
            return out
        }
        var out = md
        if !out.isEmpty {
            while out.hasSuffix("\n\n") { out.removeLast() }
            if !out.hasSuffix("\n") { out += "\n" }
            out += "\n"
        }
        return out + block + "\n"
    }

    /// The old "## Needs You: ask … out loud" section outside the marked block:
    /// from its heading to the next heading of level 1 or 2 (or the end), with
    /// the blank lines after it.
    public static func legacySection(in md: String) -> Range<String.Index>? {
        let block = blockRange(in: md)
        var searchFrom = md.startIndex
        while let h = md.range(of: legacyHeadingPrefix, range: searchFrom..<md.endIndex) {
            searchFrom = h.upperBound
            let atLineStart = h.lowerBound == md.startIndex || md[md.index(before: h.lowerBound)] == "\n"
            if !atLineStart { continue }
            if let block, block.contains(h.lowerBound) { continue }
            let lineEnd = md[h.upperBound...].firstIndex(of: "\n") ?? md.endIndex
            let title = md[h.upperBound..<lineEnd].trimmingCharacters(in: .whitespaces)
            if !title.hasSuffix(legacyHeadingSuffix.trimmingCharacters(in: .whitespaces)) || title.count <= legacyHeadingSuffix.count { continue }
            var end = md.endIndex
            var i = lineEnd
            while i < md.endIndex {
                let next = md.index(after: i)
                if next >= md.endIndex { break }
                let rest = md[next...]
                if rest.hasPrefix("## ") || rest.hasPrefix("# ") || rest.hasPrefix(beginMarker) { end = next; break }
                i = md[next...].firstIndex(of: "\n") ?? md.endIndex
            }
            return h.lowerBound..<end
        }
        return nil
    }

    /// Collapses runs of 3+ newlines left by a removal and ends with one newline.
    static func tidy(_ s: String) -> String {
        var out = s
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        while out.hasSuffix("\n\n") { out.removeLast() }
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Small LCS line diff ("-" his, "+" new default, "  " same).
    public static func lineDiff(old: String, new: String, oldName: String, newName: String, context: Int = 2) -> String {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var lines: [String] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { lines.append("  " + a[i]); i += 1; j += 1 }
            else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] { lines.append("+ " + b[j]); j += 1 }
            else { lines.append("- " + a[i]); i += 1 }
        }
        // Keep two lines of context around each change; "…" for the rest.
        let changed = lines.indices.filter { !lines[$0].hasPrefix("  ") }
        var out = ["--- \(oldName)", "+++ \(newName)"]
        var lastKept = -1
        for k in lines.indices where changed.contains(where: { abs($0 - k) <= context }) {
            if k > lastKept + 1 { out.append("  \u{2026}") }
            out.append(lines[k])
            lastKept = k
        }
        if lastKept < lines.count - 1 && lastKept >= 0 { out.append("  \u{2026}") }
        return out.joined(separator: "\n")
    }

    // MARK: Files

    private func ensureImport() throws {
        let md = read(claudeMDURL) ?? ""
        guard let out = Self.withImport(md) else { return }
        if !md.isEmpty { try backupOnce() }
        try write(out, to: claudeMDURL)
    }

    /// Keeps a copy of CLAUDE.md as it was before the app first changed it.
    private func backupOnce() throws {
        guard !FileManager.default.fileExists(atPath: backupURL.path),
              FileManager.default.fileExists(atPath: claudeMDURL.path) else { return }
        try FileManager.default.copyItem(at: claudeMDURL, to: backupURL)
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Atomic write; follows a symlinked CLAUDE.md so the link stays a link.
    private func write(_ text: String, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        try Data(text.utf8).write(to: target, options: .atomic)
    }
}
