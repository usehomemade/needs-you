import Foundation
import NeedsYouShared
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Picks the chat a voice message is for with Apple's on-device model (HM-1364).
/// Nothing leaves the Mac. It starts on the partial transcript while he is still
/// talking, so the pick is usually ready when he stops (about half a second on an
/// M-series Mac). It only names a chat; the message text comes from the matcher.
@MainActor final class ModelRouter {
    static let shared = ModelRouter()

    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    private struct Key: Hashable { let text: String; let ids: [String] }
    private var cache: [Key: Int?] = [:]
    private var running: [Key: Task<Int?, Never>] = [:]
    private var debounce: Task<Void, Never>?
    private var warmed: Any?

    /// He said the wake word (and once at launch): load the model now.
    func wake() {
        guard warmed == nil else { return }
        guard Self.available else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let s = Self.session()
            s.prewarm()
            warmed = s
        }
        #endif
    }

    /// Live text while he talks: guess early, so the final pick is already cached.
    func partial(_ transcript: String) {
        guard Self.available, let rest = Wake.afterWakeWord(transcript), rest.split(separator: " ").count >= 3 else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let targets = await Router.voiceTargets()
            guard targets.count >= 2 else { return }
            _ = await self.pick(rest, targets)
        }
    }

    /// The model's pick (index into `targets`) or nil (none fits, no model, or too slow).
    func pick(_ rest: String, _ targets: [ChatTarget]) async -> Int? {
        guard Self.available, targets.count >= 2 else { return nil }
        let key = Key(text: Self.norm(rest), ids: targets.map(\.id))
        if let hit = cache[key] { return hit }
        // A partial that already covered the whole sentence counts.
        if let (k, v) = cache.first(where: { $0.key.ids == key.ids && key.text.hasPrefix($0.key.text) && key.text.count - $0.key.text.count <= 12 }) {
            _ = k; return v
        }
        if let t = running[key] { return await t.value }
        // A session warmed on "Hey Claude" (instructions already loaded) is used once.
        let warm = warmed; warmed = nil
        let t = Task { await Self.ask(rest, targets, warm: warm) }
        running[key] = t
        let v = await t.value
        running[key] = nil
        cache[key] = v
        if cache.count > 40 { cache.removeAll() }
        return v
    }

    func reset() { cache.removeAll(); debounce?.cancel() }

    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The chat list as the model sees it: one line each.
    static func describe(_ targets: [ChatTarget]) -> String {
        targets.enumerated().map { i, t in
            var parts = ["\(i + 1). \(t.title)"]
            if !t.folder.isEmpty { parts.append("folder: \(t.folder)") }
            if !t.detail.isEmpty, t.detail != t.title { parts.append("working on: \(String(t.detail.prefix(140)))") }
            if t.focused { parts.append("used last") }
            return parts.joined(separator: "; ")
        }.joined(separator: "\n")
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    @Generable struct Pick {
        @Guide(description: "The number of the chat the message is for, or 0 when the words name no chat")
        var chat: Int
    }

    @available(macOS 26, *)
    private static func session() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            The user speaks a message for one of their open AI coding chats. Pick the chat the message is for: \
            by the name, project or folder he says, or by what the message is about. \
            Answer 0 when he names no chat and the topic fits none clearly.
            """)
    }
    #endif

    private static func ask(_ rest: String, _ targets: [ChatTarget], warm: Any?) async -> Int? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let start = Date()
            var prompt = "Chats:\n\(describe(targets))\n\n"
            // His earlier picks, as examples (routing memory).
            let ex = RoutingMemoryStore.shared.examples().compactMap { e -> String? in
                guard let i = targets.firstIndex(where: { $0.memoryKey == e.key }) else { return nil }
                return "\u{201C}\(e.words)\u{201D} meant chat \(i + 1)"
            }
            if !ex.isEmpty { prompt += "Earlier:\n" + ex.joined(separator: "\n") + "\n\n" }
            prompt += "He said: \u{201C}\(rest)\u{201D}"
            do {
                let s = (warm as? LanguageModelSession) ?? session()
                let r = try await s.respond(to: prompt, generating: Pick.self,
                                                    options: GenerationOptions(sampling: .greedy))
                let n = r.content.chat
                Isolation.note(String(format: "model route: %d in %.0f ms", n, Date().timeIntervalSince(start) * 1000))
                return (1...targets.count).contains(n) ? n - 1 : nil
            } catch {
                Isolation.note("model route failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }
}
