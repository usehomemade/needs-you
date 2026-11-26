import Foundation

/// Every message that found its chat (HM-1408, the owner: "every successful match = save
/// this as a router so it will have weighted tendency to pick that chat"): its sentence
/// vector, its first words and the chat's stable key (folder, else name). A new message
/// close in meaning to earlier ones votes for their chats, weighted by how close and how
/// recent; only chats open now count. Replaces the word-keyed routing memory (HM-1364).
public struct RouteLearning: Codable, Equatable {
    public struct Match: Codable, Equatable {
        /// The message, shortened (shown in Router Debug and to the model as an example).
        public var text: String
        public var key: String
        public var name: String
        /// How it was matched: "named", "meaning", "model", "front", "picked", "confirmed", "kept", "earlier".
        public var source: String
        public var at: Date
        /// The embedding language; vectors of different languages are never compared.
        public var lang: String
        public var vector: [Float]
    }

    public static let limit = 500
    /// Similarity under which an earlier message says nothing about the new one.
    public static let floor = 0.45
    /// A match loses half its weight in this many days.
    public static let halfLifeDays = 14.0
    /// Votes that may confirm the model or meaning, and that may decide with meaning silent.
    public static let leadWeight = 0.2
    public static let veryClearWeight = 0.6

    public var version = 2
    public private(set) var matches: [Match] = []

    public init(matches: [Match] = []) { self.matches = matches }

    public mutating func add(text: String, key: String, name: String, source: String, lang: String, vector: [Float], at: Date = Date()) {
        guard !key.isEmpty, !vector.isEmpty else { return }
        let short = text.split(separator: " ").prefix(14).joined(separator: " ")
        matches.append(Match(text: short, key: key, name: name, source: source, at: at, lang: lang, vector: vector))
        if matches.count > Self.limit { matches.removeFirst(matches.count - Self.limit) }
    }

    /// One earlier match's vote: 0 below `floor`, up to 1 for the same sentence today.
    public static func weight(sim: Double, age: TimeInterval) -> Double {
        guard sim > floor else { return 0 }
        let closeness = (sim - floor) / (1 - floor)
        let recency = pow(0.5, max(0, age) / (halfLifeDays * 86_400))
        return closeness * recency
    }

    public struct Vote: Equatable, Sendable {
        public var key: String
        public var weight: Double
        public var count: Int
        /// The closest earlier message for this chat.
        public var example: String
        public var bestSim: Double
    }

    /// Votes per chat key among `keys` (the chats open now), strongest first.
    public func votes(_ vector: [Float], lang: String, among keys: Set<String>, now: Date = Date()) -> [Vote] {
        var out: [String: Vote] = [:]
        for m in matches where m.lang == lang && keys.contains(m.key) && m.vector.count == vector.count {
            let sim = Meaning.cosine(vector, m.vector)
            let w = Self.weight(sim: sim, age: now.timeIntervalSince(m.at))
            guard w > 0 else { continue }
            var v = out[m.key] ?? Vote(key: m.key, weight: 0, count: 0, example: m.text, bestSim: sim)
            v.weight += w; v.count += 1
            if sim > v.bestSim { v.bestSim = sim; v.example = m.text }
            out[m.key] = v
        }
        return out.values.sorted { $0.weight > $1.weight || ($0.weight == $1.weight && $0.key < $1.key) }
    }

    /// The chat the votes clearly point to: at least `min` and twice the next one.
    public static func leader(_ votes: [Vote], min: Double = leadWeight) -> String? {
        guard let best = votes.first, best.weight >= min else { return nil }
        if votes.count > 1, votes[1].weight * 2 > best.weight { return nil }
        return best.key
    }

    /// Recent matches for open chats, newest first, one per text (examples for the model).
    public func examples(among keys: Set<String>, max: Int = 6) -> [Match] {
        var seen = Set<String>(), out: [Match] = []
        for m in matches.reversed() where keys.contains(m.key) && !seen.contains(m.text) {
            seen.insert(m.text); out.append(m)
            if out.count == max { break }
        }
        return out
    }

    public static func load(_ url: URL) -> RouteLearning? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? LineIO.decoder.decode(RouteLearning.self, from: d)
    }

    public func save(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? LineIO.encoder.encode(self) { try? d.write(to: url, options: .atomic) }
    }

    /// The old word-keyed memory (routing-memory.json): its words and chat keys, for migration.
    public struct Legacy: Decodable {
        public struct Entry: Decodable { public var words: String; public var key: String; public var name: String; public var source: String; public var at: Date }
        public var entries: [Entry]
        public static func load(_ url: URL) -> [Entry] {
            guard let d = try? Data(contentsOf: url), let l = try? LineIO.decoder.decode(Legacy.self, from: d) else { return [] }
            return l.entries
        }
    }
}
