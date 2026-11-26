import Foundation
import NeedsYouShared
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads every voice command with Apple's on-device model (HM-1364, HM-1399): what he
/// wants (a message for a chat, a new chat, do not disturb, ...), which chat, and the message.
/// Nothing leaves the Mac. It starts on the partial transcript while he is still
/// talking, so the pick is usually ready when he stops (about half a second on an
/// M-series Mac). `IntentJudge` checks its pick before anything is sent.

@MainActor final class ModelRouter {
    static let shared = ModelRouter()

    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    private struct Key: Hashable { let text: String; let ids: [String] }
    private var cache: [Key: VoiceIntent?] = [:]
    private var running: [Key: Task<VoiceIntent?, Never>] = [:]
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
    func pick(_ rest: String, _ targets: [ChatTarget]) async -> VoiceIntent? {
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
    @Generable struct Intent {
        @Guide(description: "What he wants", .anyOf(["send", "new_chat", "away", "good_night", "back", "voicemails", "summary", "list_chats", "nothing"]))
        var action: String
        @Guide(description: "For send or new_chat: the number of the chat or app it is for, or 0 when no listed chat clearly fits")
        var chat: Int
        @Guide(description: "The words he used to name a chat, app, project or folder, exactly as he said them; empty when he named none")
        var named: String
        @Guide(description: "true only when he points at the chat in front of him instead of naming one or saying what it is about")
        var meansChatInFront: Bool
        @Guide(description: "For back: true when he also asks what was done while he was away")
        var wantsSummary: Bool
        @Guide(description: "For send or new_chat: the message in his exact words, without the words that name the chat or ask for a new chat; empty otherwise")
        var message: String
    }

    @available(macOS 26, *)
    @Generable struct Choice {
        @Guide(description: "The number of the chat he chose, or 0 when he chose none of them or it is unclear")
        var chat: Int
        @Guide(description: "true when he wants to stop and send nothing")
        var cancel: Bool
    }

    @available(macOS 26, *)
    private static func session() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            The user talks to his Mac after a wake phrase. Decide what he wants:
            send: a message for one of his AI chats (listed: coding chats in a terminal or editor, and chats in chat apps).
            new_chat: he asks to start a new chat or conversation, in a chat app or in a project folder.
            away: he goes away for a while and wants quiet. good_night: he goes to sleep.
            back: he is back, or it is morning. voicemails: he wants his waiting voice messages played.
            summary: he asks what was done while he was away. list_chats: he asks which chats are open.
            nothing: none of these.
            For send, pick the chat by the name, project, folder or app he says, or by what the message is about \
            (a chat whose title or "working on" matches). Answer 0 when he names no chat and the topic fits none clearly. \
            Never pick a chat only because it was used last.
            """)
    }
    #endif

    /// His answer to "Which chat?": an index into `chats` (the offered ones first, in the
    /// order they were said), nil for none or unclear, and whether he wants to stop.
    /// nil when there is no model.
    func choose(_ answer: String, question: String, chats: [ChatTarget]) async -> (index: Int?, cancel: Bool)? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), Self.available, !chats.isEmpty {
            let prompt = """
                You asked him: \u{201C}\(question)\u{201D}
                His chats (the ones you offered come first, in the order you said them):
                \(Self.describe(chats))

                He answered: \u{201C}\(answer)\u{201D}
                The microphone may have heard your own question before his answer; only his words count.
                """
            do {
                let s = LanguageModelSession(instructions: "Read which chat the user chose from a list. Answer with its number.")
                let r = try await s.respond(to: prompt, generating: Choice.self, options: GenerationOptions(sampling: .greedy))
                Isolation.note("model choice: \(r.content.chat)\(r.content.cancel ? " (cancel)" : "")")
                let n = r.content.chat
                return ((1...chats.count).contains(n) ? n - 1 : nil, r.content.cancel)
            } catch {
                Isolation.note("model choice failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    private static func ask(_ rest: String, _ targets: [ChatTarget], warm: Any?) async -> VoiceIntent? {
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
                let r = try await s.respond(to: prompt, generating: Intent.self,
                                                    options: GenerationOptions(sampling: .greedy))
                let c = r.content
                Isolation.note(String(format: "model: %@ %d \u{201C}%@\u{201D} in %.0f ms", c.action, c.chat, c.named, Date().timeIntervalSince(start) * 1000))
                return VoiceIntent(action: VoiceIntent.Action(rawValue: c.action) ?? .nothing,
                                   chat: (1...targets.count).contains(c.chat) ? c.chat - 1 : nil,
                                   named: c.named, meansFront: c.meansChatInFront, summary: c.wantsSummary, message: c.message)
            } catch {
                Isolation.note("model route failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }
}
