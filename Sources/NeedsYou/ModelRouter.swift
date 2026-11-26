import Foundation
import NeedsYouShared
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Picks the chat a voice message is for with Apple's on-device model (HM-1364).
/// Nothing leaves the Mac. It starts on the partial transcript while he is still
/// talking, so the pick is usually ready when he stops (about half a second on an
/// M-series Mac). It names a chat, says whether he asked for a new chat, and gives the
/// message without the words that name the chat (HM-1383); the caller checks both.
struct ModelPick: Hashable {
    var index: Int
    var newChat: Bool
    var message: String
}

@MainActor final class ModelRouter {
    static let shared = ModelRouter()

    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    private struct Key: Hashable { let text: String; let ids: [String] }
    private var cache: [Key: ModelPick?] = [:]
    private var running: [Key: Task<ModelPick?, Never>] = [:]
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
            guard !targets.isEmpty else { return }
            _ = await self.pick(rest, targets)
        }
    }

    /// The model's pick (index into `targets`) or nil (none fits, no model, or too slow).
    func pick(_ rest: String, _ targets: [ChatTarget]) async -> ModelPick? {
        guard Self.available, !targets.isEmpty else { return nil }
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

    /// The model's message, if it is really his words: most of its words are in what he
    /// said (the model may not add or rephrase anything).
    nonisolated static func trusted(_ message: String, in rest: String) -> String? {
        let said = Set(ChatMatcher.words(rest))
        let w = ChatMatcher.words(message)
        guard w.count >= 2 else { return nil }
        return Double(w.filter(said.contains).count) / Double(w.count) >= 0.85 ? message : nil
    }

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
            if t.kind == .desktop {
                parts.append(t.appChat == nil ? "a chat app; can start a new chat" : "an earlier chat in \(Router.runningChatApps().first { $0.bundle == t.id }?.title ?? "a chat app") (opens it)")
            }
            if t.focused { parts.append("used last") }
            return parts.joined(separator: "; ")
        }.joined(separator: "\n")
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    @Generable struct Pick {
        @Guide(description: "The number of the chat or app the message is for, or 0 when the words name none and the topic fits none")
        var chat: Int
        @Guide(description: "true only when he asks to start a new chat or conversation")
        var newChat: Bool
        @Guide(description: "The message to send, in his exact words, without the part that names the chat or app or asks for a new chat (e.g. drop 'use ChatGPT to ask')")
        var message: String
    }

    @available(macOS 26, *)
    private static func session() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            The user speaks a message for one of their AI chats: coding chats in a terminal or editor, \
            and chat apps such as the Claude app or ChatGPT. Pick the chat the message is for: \
            by the name, project, folder or app he says, or by what the message is about \
            (a chat whose "working on" matches the topic). \
            Answer 0 when he names no chat and the topic fits none clearly. \
            Copy his message word for word, leaving out only the words that pick the chat.
            """)
    }
    #endif

    private static func ask(_ rest: String, _ targets: [ChatTarget], warm: Any?) async -> ModelPick? {
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
                Isolation.note(String(format: "model route: %d%@ in %.0f ms", n, r.content.newChat ? " (new chat)" : "", Date().timeIntervalSince(start) * 1000))
                guard (1...targets.count).contains(n) else { return nil }
                return ModelPick(index: n - 1, newChat: r.content.newChat, message: r.content.message)
            } catch {
                Isolation.note("model route failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }
}
