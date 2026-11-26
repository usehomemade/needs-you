import Foundation
import NeedsYouShared
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads every voice command with Apple's on-device model (HM-1364, HM-1399): what he
/// wants (a message for a chat, a new chat, do not disturb, ...), which chat, and the message.
/// When he goes away or to sleep a second, small read finds how long or until when (HM-1433).
/// `needs-you intent-eval` runs the evaluation set (`IntentEval`) through it.
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
        // A session warmed on "Hey Mac" (instructions already loaded) is used once.
        let warm = warmed; warmed = nil
        let t = Task { await Self.ask(rest, targets, warm: warm, examples: true) }
        running[key] = t
        let v = await t.value
        running[key] = nil
        cache[key] = v
        if cache.count > 40 { cache.removeAll() }
        return v
    }

    func reset() { cache.removeAll(); debounce?.cancel() }

    // MARK: Evaluation (HM-1433)

    /// Test hook: `needs-you intent-eval [--title intent|clarify|all]`. Runs the evaluation set
    /// through the real model (made-up chats, no routing memory, nothing sent) and returns the
    /// table (state) and every miss (turns).
    func eval(_ which: String) async -> Response {
        var r = Response(status: "measured")
        guard Self.available else { r.status = "error"; r.error = "the on-device model is not available"; return r }
        var report: [String] = [], misses: [Turn] = []
        if which == "intent" || which == "all" {
            let targets = Self.evalTargets
            var rows: [(IntentEval.Case, IntentEval.Result)] = []
            var ms: [Double] = []
            for c in IntentEval.cases {
                let t0 = Date()
                var i = await Self.ask(c.text, targets, warm: nil, examples: false)
                ms.append(Date().timeIntervalSince(t0) * 1000)
                if let x = i { i?.named = VoiceIntent.spokenName(x.named, in: c.text) }
                i = i?.forNamedChat(IntentEval.candidates, rest: c.text)
                let s = IntentEval.score(c, i)
                rows.append((c, s))
                if !s.ok {
                    let got = i.map { "\($0.action.rawValue) chat \($0.chat.map { String($0 + 1) } ?? "-") named \u{201C}\($0.named)\u{201D} time \($0.time)\($0.summary ? " +summary" : "")" } ?? "no answer"
                    misses.append(Turn(role: .agent, text: "MISS \u{201C}\(c.text)\u{201D} want \(c.actions.map(\.rawValue).joined(separator: "/"))\(c.chat.map { " chat \($0)" } ?? "")\(c.time.map { " \($0)" } ?? "") got \(got)"))
                }
            }
            ms.sort()
            report.append(IntentEval.table(rows) + String(format: "\nmedian %.0f ms, slowest %.0f ms", ms[ms.count / 2], ms.last ?? 0))
        }
        if which == "clarify" || which == "all" {
            let (table, m) = await clarifyEval()
            report.append(table); misses += m
        }
        r.state = report.joined(separator: "\n\n")
        r.turns = misses
        return r
    }

    /// The "which chat?" answers, read the way `askWhichChat` and `choose` read them.
    private func clarifyEval() async -> (String, [Turn]) {
        let all = Self.evalTargets
        var rows: [(String, Bool)] = [], choiceRows: [(String, Bool)] = [], misses: [Turn] = []
        for c in IntentEval.clarifyCases {
            // Offered first, in the order said, then every other chat (as askWhichChat does).
            let offered = c.offered.map { all[$0 - 1] }
            let everyone = offered + all.filter { a in !offered.contains { $0.key == a.key } }
            let back: (Int?) -> Int? = { i in i.flatMap { everyone.indices.contains($0) ? Int(everyone[$0].id.dropFirst(5))! + 1 : nil } }
            let names = offered.map { VoiceCommands.short($0.title) }
            let question = c.offered.count == 1 ? "Send it to \(names[0])?" : VoiceCommands.whichChatQuestion(names, heardName: "", again: false)
            var convo = ClarifyConversation(message: "the import button should be bigger", offered: Array(offered.indices))
            convo.asked(question)
            let (step, _) = await VoiceCommands.readAnswer(c.answer, pressed: nil, convo: &convo, question: question,
                                                           offeredNames: names, allNames: everyone.map { VoiceCommands.short($0.title) }, everyone: everyone)
            let next: IntentEval.Next
            switch step {
            case .send(let i): next = .send(back(i)!)
            case .confirm(let i): next = .confirm(back(i)!)
            case .ask: next = .ask
            case .notFound: next = .notFound
            case .cancel: next = .cancel
            }
            let ok = IntentEval.scoreClarify(c, next)
            rows.append((c.group, ok))
            if !ok { misses.append(Turn(role: .agent, text: "MISS clarify \u{201C}\(c.answer)\u{201D} to \u{201C}\(question)\u{201D} want \(c.expect) got \(next)")) }
            // The kept message's "Hey Mac, <chat>" answer (choose): chats and stops only.
            switch c.expect {
            case .chat, .cancel:
                if c.offered.count > 1, let ch = await choose(c.answer, question: question, chats: everyone) {
                    let pick = back(ch.index)
                    let ok2 = c.expect == .cancel ? ch.cancel : (c.expect == .chat(pick ?? -1) && !ch.cancel)
                    choiceRows.append((c.group, ok2))
                    if !ok2 { misses.append(Turn(role: .agent, text: "MISS choose \u{201C}\(c.answer)\u{201D} want \(c.expect) got \(pick.map(String.init) ?? "-")\(ch.cancel ? " cancel" : "")")) }
                }
            default: break
            }
        }
        return (IntentEval.clarifyTable(rows, title: "which chat? answers (converse)") + "\n\n" + IntentEval.clarifyTable(choiceRows, title: "kept message pick (choose)"), misses)
    }

    static var evalTargets: [ChatTarget] {
        IntentEval.chats.enumerated().map { n, c in
            var t = ChatTarget(kind: c.desktop ? .desktop : .registered, id: "eval-\(n)", title: c.title, aliases: [], focused: c.focused)
            t.folder = c.folder; t.detail = c.detail; t.label = c.label; t.workspace = c.workspace
            if c.desktop { t.appChat = nil }
            return t
        }
    }


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
            if !t.folder.isEmpty { parts.append("folder: \(t.folder)") } else if t.home { parts.append("folder: his home folder") }
            // herdr names he gave it (HM-1425): "the bakery one in general".
            if !t.label.isEmpty { parts.append("herdr tab: \(t.label)") }
            if !t.workspace.isEmpty { parts.append("herdr workspace: \(t.workspace)") }
            if !t.detail.isEmpty, t.detail != t.title { parts.append("working on: \(String(t.detail.prefix(200)))") }
            if t.kind == .desktop {
                parts.append(t.appChat == nil ? "a chat app; can start a new chat" : "an earlier chat in \(Router.runningChatApps().first { $0.bundle == t.id }?.title ?? "a chat app") (opens it)")
            }
            if t.focused { parts.append("used last") }
            return parts.joined(separator: "; ")
        }.joined(separator: "\n")
    }

    #if canImport(FoundationModels)
    /// What he wants (HM-1399, HM-1433). The instructions say what each action means.
    @available(macOS 26, *)
    @Generable struct Intent {
        @Guide(description: "true when he asks to start a new chat or a new conversation (in an app, a project or a folder)")
        var wantsNewChat: Bool
        @Guide(description: "What he wants", .anyOf(["send", "start_new_chat", "away", "good_night", "back_or_quiet_off", "play_voicemails", "summary", "list_chats", "nothing"]))
        var action: String
        @Guide(description: "For send or new_chat: the number of the chat the message is about or names (compare it with each chat's title, folder and working on), or 0 when no listed chat clearly fits")
        var chat: Int
        @Guide(description: "The words he used to call a chat, app, project or folder by its name, copied word for word from what he said (never from the chat list), like X in 'send it to the X chat' or 'X: ...'. What the message talks about is not a name. Empty when he named none")
        var named: String
        @Guide(description: "true only when he points at the chat in front of him instead of naming one or saying what it is about")
        var meansChatInFront: Bool
        @Guide(description: "true when he says he is back, home or here again, also when he asks for something else in the same breath")
        var saysHeIsBack: Bool
        @Guide(description: "For back_or_quiet_off: true when he also asks what he missed or what was done while he was away")
        var wantsSummary: Bool
        @Guide(description: "For send or new_chat: the message in his exact words, without the words that name the chat or ask for a new chat; empty otherwise")
        var message: String
    }

    /// The model's label as an action (two labels say what they do: HM-1433).
    static func action(_ label: String) -> VoiceIntent.Action {
        switch label {
        case "start_new_chat": return .newChat
        case "play_voicemails": return .voicemails
        case "back_or_quiet_off": return .back
        default: return VoiceIntent.Action(rawValue: label) ?? .nothing
        }
    }

    /// How long he will be away (HM-1433), read only when he goes away or to sleep. Code turns
    /// the parts into a date (`AwayTime.end`).
    @available(macOS 26, *)
    @Generable struct Quiet {
        @Guide(description: "The words he used for how long or until when, copied exactly from what he said. Empty when he said no length and no end")
        var words: String
        @Guide(description: "length: those words say how long (for three hours, back in 20 minutes, half an hour). until: they say when it ends (until 4, until 3 pm, until this evening, till morning, until Monday). none: no words", .anyOf(["none", "length", "until"]))
        var kind: String
        @Guide(description: "For length: the minutes (twenty minutes = 20, half an hour = 30, an hour = 60, an hour and a half = 90, three hours = 180), else 0", .range(0...10080))
        var minutes: Int
        @Guide(description: "For until with a clock time: its hour as he said it (until 4 = 4, until 3 pm = 15, until 8:30 = 8). -1 when he said no clock time", .range(-1...23))
        var hour: Int
        @Guide(description: "For until with a clock time: its minutes (8:30 = 30), else 0", .range(0...59))
        var minute: Int
        @Guide(description: "For until with a clock time: am or pm only when he said it, else unsaid", .anyOf(["am", "pm", "unsaid"]))
        var meridiem: String
        @Guide(description: "For until: the day he names (tomorrow, Monday), else none", .anyOf(["none", "today", "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]))
        var day: String
        @Guide(description: "For until: the part of the day he names (this evening, morning, noon), else none", .anyOf(["none", "morning", "noon", "afternoon", "evening", "night"]))
        var part: String
    }

    /// The model's time, kept only when its words are words he said (no made-up times).
    @available(macOS 26, *)
    static func time(_ q: Quiet, said rest: String) -> AwayTime {
        let said = Set(ChatMatcher.words(rest)), w = ChatMatcher.words(q.words)
        guard !w.isEmpty, w.allSatisfy(said.contains) else { return AwayTime() }
        switch q.kind {
        case "length": return AwayTime(minutes: q.minutes)
        case "until":
            let part = AwayTime.Part(rawValue: q.part)
            // Midnight next to a part of the day is the model's blank, not his "until 12".
            let hour = q.hour < 0 || (q.hour == 0 && part != nil) ? nil : q.hour
            return AwayTime(hour: hour, minute: hour == nil ? nil : q.minute,
                            pm: q.meridiem == "pm" ? true : q.meridiem == "am" ? false : nil,
                            day: AwayTime.Day(rawValue: q.day), part: part)
        default: return AwayTime()
        }
    }

    @available(macOS 26, *)
    @Generable struct Choice {
        @Guide(description: "The number of the chat he chose, or 0 when he chose none of them or it is unclear")
        var chat: Int
        @Guide(description: "true only when he says to cancel, stop or not send it at all. Choosing another chat, or saying none of these, is not cancel")
        var cancel: Bool
    }

    @available(macOS 26, *)
    @Generable struct ClarifyAnswer {
        @Guide(description: "What his last answer does (HM-1433: one choice, so a plain stop is never read as no). stop: he says to cancel, stop, forget it or not send the message at all. yes or no: his answer when your last question offered one chat ('Send it to ...?'). none_of_these: none of the chats you offered last is right. a_chat: he names, numbers or describes a chat. unclear: none of these", .anyOf(["stop", "yes", "no", "none_of_these", "a_chat", "unclear"]))
        var reply: String
        @Guide(description: "The number of the chat he means now (by its number, its name, or what he says it is about), or 0 when it is unclear")
        var chat: Int
        @Guide(description: "What he says the chat he means is about or works on, in his words; empty when he said nothing about it")
        var about: String
        @Guide(description: "true only when his last answer clearly picks that chat number. false when he describes a chat that is not clearly one in the list, or the chat is unclear")
        var sure: Bool
        @Guide(description: "true when he picked the chat by its number or place in your list (two, the second one)")
        var byNumber: Bool
        @Guide(description: "The words he used to call the chat by a name (its tab, workspace, folder or project), copied word for word from his last answer. Empty when he named none")
        var named: String
    }

    @available(macOS 26, *)
    private static func session() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            The user talks to his Mac after a wake phrase. The Mac passes his words to his AI chats, and while he is away \
            it keeps the chats' questions as voicemails, to play them to him when he is back. Decide what he means:
            send: words for one of his AI chats (listed: coding chats in a terminal or editor, and chats in chat apps): \
            a task, a change to make, a question, a reply. When he starts with a chat's name, tells a chat something, \
            or asks for a change to an app, a page or code, it is send, whatever the words are about \
            (but a new chat he asks for is start_new_chat).
            start_new_chat: he asks for a new chat or conversation, in a chat app or in a project folder, \
            also in a project that has a chat open already.
            away: he is leaving or will be busy for a while, or wants do not disturb on, \
            or wants the questions to go to voicemail instead of being asked now. \
            Saying how long he will be gone, or when he will be back, means he is leaving now: away.
            good_night: he goes to sleep.
            back_or_quiet_off: he has returned or is free again, says good morning, is reachable again, \
            or wants do not disturb off. \
            Turning do not disturb on is away; turning it off is back_or_quiet_off. When he says he is back and also asks \
            what was done, it is back_or_quiet_off (not summary) with wantsSummary.
            play_voicemails: he asks to hear the kept voicemails or messages (or whether any wait for him), \
            or the questions the chats asked.
            summary: he asks what work was done. list_chats: he asks which chats are open, or which ones he can reach.
            nothing: none of these, like small talk, a microphone test, thinking out loud, a mistake, or he changes his mind.
            For send, pick the chat by the name, project, folder or app he says, or else by what the message is ABOUT: \
            the chat whose title, folder or "working on" is about the same thing as his message. \
            Answer 0 when he names no chat and the message is about none of them clearly. \
            Never pick a chat only because it was used last. "named" is only words he said himself.
            """)
    }

    @available(macOS 26, *)
    private static func quietSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            The user goes away or to sleep. Read how long, or until when, from his own words: a length \
            ("for two hours" is 120 minutes, "back in ten minutes" is 10), or an end: a clock time ("until 7" is hour 7), \
            a day ("until Friday"), a part of the day ("till the afternoon"), or several of them ("until tomorrow at 9"). \
            Leave out anything he did not say.
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

    /// One answer in the "which chat?" conversation (HM-1408), read with the whole
    /// conversation and every chat. nil when there is no model.
    func converse(_ convo: ClarifyConversation, chats: [ChatTarget]) async -> ClarifyConversation.Reading? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), Self.available, !chats.isEmpty {
            let offered = convo.offered.map { String($0 + 1) }.joined(separator: ", ")
            let prompt = """
                His chats:
                \(Self.describe(chats))

                \(convo.transcript)

                The chats you offered last: \(offered.isEmpty ? "none" : offered).
                The microphone may have heard your own question before his answer; only his words count.
                """
            do {
                let s = LanguageModelSession(instructions: """
                    You help the user send a voice message to the right AI chat. You asked him which chat it is for, \
                    and you keep talking until it is clear. Read his last answer with the whole conversation: \
                    which chat he means (by number, name, or what it is about), whether he said yes or no to your last question, \
                    and whether he wants to stop. "None of them" or pointing at another chat is never stop.
                    """)
                let r = try await s.respond(to: prompt, generating: ClarifyAnswer.self, options: GenerationOptions(sampling: .greedy))
                let c = r.content
                Isolation.note("model clarify: \(c.reply), chat \(c.chat)\(c.sure ? " sure" : " unsure")\(c.byNumber ? " by number" : "") named \u{201C}\(c.named)\u{201D} about \u{201C}\(c.about)\u{201D}")
                return ClarifyConversation.Reading(chat: (1...chats.count).contains(c.chat) ? c.chat - 1 : nil, cancel: c.reply == "stop",
                                                   yesNo: .init(rawValue: c.reply) ?? .unclear, noneOfThese: c.reply == "none_of_these", about: c.about,
                                                   sure: c.sure, byNumber: c.byNumber, named: c.named)
            } catch {
                Isolation.note("model clarify failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    static func ask(_ rest: String, _ targets: [ChatTarget], warm: Any?, examples: Bool) async -> VoiceIntent? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let start = Date()
            var prompt = "Chats:\n\(describe(targets))\n\n"
            // Earlier messages that found their chat, as examples (HM-1408).
            let ex = (examples ? RouteLearningStore.shared.examples(targets) : []).compactMap { e -> String? in
                guard let i = targets.firstIndex(where: { $0.memoryKey == e.key }) else { return nil }
                return "\u{201C}\(e.text)\u{201D} went to chat \(i + 1)"
            }
            if !ex.isEmpty { prompt += "Earlier:\n" + ex.joined(separator: "\n") + "\n\n" }
            prompt += "He said: \u{201C}\(rest)\u{201D}"
            let options = GenerationOptions(sampling: .greedy)
            do {
                let s = (warm as? LanguageModelSession) ?? session()
                let c = try await s.respond(to: prompt, generating: Intent.self, options: options).content
                var action = Self.action(c.action)
                if c.wantsNewChat && (action == .send || action == .newChat) { action = .newChat }
                var time = AwayTime()
                var summary = c.wantsSummary
                // "I'm back, what did you work on?": back first, then the summary (HM-1433).
                if c.saysHeIsBack && (action == .summary || action == .voicemails) { summary = action == .summary; action = .back }
                if action == .away || action == .goodNight {
                    // Step 2: how long, read with a small schema of its own (fast, and only when he goes away).
                    let q = try await quietSession().respond(to: "He said: \u{201C}\(rest)\u{201D}", generating: Quiet.self, options: options).content
                    time = Self.time(q, said: rest)
                    if action == .goodNight { time = time.forSleep }
                }
                Isolation.note(String(format: "model: %@ %d \u{201C}%@\u{201D}%@ in %.0f ms", action.rawValue, c.chat, c.named, time.isEmpty ? "" : " \(time)",
                                      Date().timeIntervalSince(start) * 1000))
                let i = VoiceIntent(action: action, chat: (1...targets.count).contains(c.chat) ? c.chat - 1 : nil,
                                    named: c.named, meansFront: c.meansChatInFront, summary: summary, message: c.message, time: time)
                return i
            } catch {
                Isolation.note("model route failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }
}
