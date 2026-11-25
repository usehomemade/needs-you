import Foundation

/// The last 200 times he said which chat he meant (HM-1364): when Needs You asked
/// and he picked one, or a named message he let go out. The words that pointed at
/// the chat are kept with the chat's stable key (its folder, else its name), so the
/// same words find the same chat next time, even after the chat was restarted.
public struct RoutingMemory: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var words: String
        public var key: String
        public var name: String
        /// "asked": he answered "which chat?"; "sent": a message went out unchanged.
        public var source: String
        public var at: Date
    }

    public static let limit = 200
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = entries }

    /// The words that point at a chat: the heard name, else the first six words.
    public static func words(rest: String, heardName: String = "") -> String {
        let base = heardName.isEmpty ? rest : heardName
        return Array(tokens(base).prefix(6)).joined(separator: " ")
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    public mutating func add(words: String, key: String, name: String, source: String, at: Date = Date()) {
        guard !words.isEmpty, !key.isEmpty else { return }
        entries.append(Entry(words: words, key: key, name: name, source: source, at: at))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// The chat key these words went to most recently, among `keys` (the open chats).
    /// Words match when most of them are the same (Jaccard >= 0.6).
    public func lookup(_ words: String, among keys: Set<String>) -> String? {
        let a = Set(Self.tokens(words))
        guard !a.isEmpty else { return nil }
        for e in entries.reversed() where keys.contains(e.key) {
            let b = Set(Self.tokens(e.words))
            let j = Double(a.intersection(b).count) / Double(a.union(b).count)
            if j >= 0.6 { return e.key }
        }
        return nil
    }

    /// Recent picks for open chats, as examples for the on-device model (newest first).
    public func examples(among keys: Set<String>, max: Int = 6) -> [Entry] {
        var seen = Set<String>(), out: [Entry] = []
        for e in entries.reversed() where keys.contains(e.key) && !seen.contains(e.words) {
            seen.insert(e.words); out.append(e)
            if out.count == max { break }
        }
        return out
    }

    public static func load(_ url: URL) -> RoutingMemory {
        guard let d = try? Data(contentsOf: url), let m = try? LineIO.decoder.decode(RoutingMemory.self, from: d) else { return RoutingMemory() }
        return m
    }

    public func save(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? LineIO.encoder.encode(self) { try? d.write(to: url, options: .atomic) }
    }
}
