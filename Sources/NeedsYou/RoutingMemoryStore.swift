import Foundation
import NeedsYouShared

/// routing-memory.json in Application Support: the last 200 chat picks (HM-1364).
@MainActor final class RoutingMemoryStore {
    static let shared = RoutingMemoryStore()
    private let url = Wire.supportDir.appendingPathComponent("routing-memory.json")
    private(set) lazy var memory = RoutingMemory.load(url)
    /// Keys of the chats open now (set by the router before a lookup).
    var openKeys: Set<String> = []

    func lookup(_ words: String) -> String? { memory.lookup(words, among: openKeys) }

    func remember(words: String, target: ChatTarget, source: String) {
        memory.add(words: words, key: target.memoryKey, name: target.title, source: source)
        memory.save(url)
        Isolation.note("route memory: \u{201C}\(words)\u{201D} -> \(target.memoryKey) (\(source))")
    }

    func examples() -> [RoutingMemory.Entry] { memory.examples(among: openKeys) }
}
