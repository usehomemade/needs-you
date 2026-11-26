import Foundation

/// What he wants, as the on-device model read his words (HM-1399, the owner: "no regex,
/// hardcode or command phrases; the LLM decides"). No phrase or word list decides
/// anything here: the model reads the command, and `IntentJudge` checks its pick against
/// data (word rarity across his chat names, routing memory) before anything is sent.
public struct VoiceIntent: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case send, newChat = "new_chat", away, goodNight = "good_night", back, voicemails, summary, listChats = "list_chats", nothing
    }
    public var action: Action
    /// 0-based index into the chat list; nil when no listed chat fits.
    public var chat: Int?
    /// The words he used to name a chat, app, project or folder; empty when he named none.
    public var named: String
    /// He points at the chat in front of him instead of naming one.
    public var meansFront: Bool
    /// With `back`: he also asked what was done while he was away.
    public var summary: Bool
    /// The message for the chat, in his words.
    public var message: String

    public init(action: Action, chat: Int? = nil, named: String = "", meansFront: Bool = false, summary: Bool = false, message: String = "") {
        self.action = action; self.chat = chat; self.named = named
        self.meansFront = meansFront; self.summary = summary; self.message = message
    }
}

extension VoiceIntent {
    /// The model sometimes hands back a chat's full title, or his whole sentence, as "the name
    /// he said". Only his own words count, and a "name" that is most of the sentence is none.
    public static func ownWords(_ named: String, in rest: String) -> String {
        let said = ChatMatcher.words(rest)
        let kept = ChatMatcher.words(named).filter { Set(said).contains($0) }
        guard !kept.isEmpty, Double(kept.count) < Double(said.count) * 0.8 else { return "" }
        return kept.joined(separator: " ")
    }
}

/// Turns the model's reading into what happens. Never a guess (26 Nov): a message is
/// sent only when the chat he named matches one chat, he pointed at the chat in front, or
/// the model's pick agrees with the words he said (`topic`) or with what he picked before
/// for the same words (`memory`). Everything else asks; a name that matches nothing says so.
public enum IntentJudge {
    public enum Outcome: Equatable, Sendable {
        case send(Int, byFocus: Bool)
        case ask([Int], heard: String)
        case notFound(String)
        /// A new chat: `named` is the app or project he said ("" = none).
        case newChat(named: String)
        case presence(VoiceIntent.Action, summary: Bool)
        case nothing
    }

    /// `topic`: the chat his words point to, enough to confirm the model's pick.
    /// `clearTopic`: the same with at least two rare words shared, enough to send on its own.
    /// `recent`: the chats to offer when nothing points anywhere (most recent first).
    public static func decide(_ intent: VoiceIntent?, _ chats: [ChatCandidate], topic: Int?, clearTopic: Int? = nil, memory: Int?, recent: [Int],
                              isProject: (String) -> Bool = { _ in false }) -> (Outcome, String) {
        func ask(_ first: [Int?], _ why: String, heard: String = "") -> (Outcome, String) {
            var seen = Set<Int>(), out: [Int] = []
            for i in (first.compactMap { $0 } + recent) where seen.insert(i).inserted { out.append(i) }
            return (.ask(Array(out.prefix(4)), heard: heard), why)
        }
        // No model (not available, failed or too slow): only the data can send.
        guard let i = intent else {
            if let t = clearTopic { return (.send(t, byFocus: false), "no model; clear topic -> \(t)") }
            if let m = memory { return (.send(m, byFocus: false), "no model; memory -> \(m)") }
            return ask([], "no model -> ask")
        }
        switch i.action {
        case .nothing: return (.nothing, "model: nothing to do")
        case .newChat: return (.newChat(named: i.named.trimmingCharacters(in: .whitespacesAndNewlines)), "model: new chat")
        case .send: break
        default: return (.presence(i.action, summary: i.summary), "model: \(i.action.rawValue)")
        }
        let named = i.named.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty {
            let ranked = ChatMatcher.rank(named, chats)
            let log = "named \"\(named)\": " + ChatMatcher.describe(ranked, chats)
            if let best = ranked.first, best.score >= 0.5, (ranked.dropFirst().first?.score ?? 0) <= best.score - 0.2 {
                return (.send(best.index, byFocus: false), log)
            }
            let options = ranked.filter { $0.score >= 0.3 }.prefix(3).map(\.index)
            if !options.isEmpty {
                let first = i.chat.flatMap { options.contains($0) ? $0 : nil }
                var seen = Set<Int>(), out: [Int] = []
                for x in ([first].compactMap { $0 } + options) where seen.insert(x).inserted { out.append(x) }
                return (.ask(out, heard: named), log + " -> ask")
            }
            if isProject(named) { return (.newChat(named: named), log + "; project folder -> new chat") }
            // The model may have read part of the message as a name: its pick still counts
            // when his words or his earlier picks back it.
            if let c = i.chat, c == topic || c == memory { return (.send(c, byFocus: false), log + "; model \(c) agrees with topic/memory") }
            return (.notFound(named), log + "; no such chat")
        }
        let front = chats.firstIndex(where: { $0.isDesktop && $0.focused }) ?? chats.firstIndex(where: { $0.focused && !$0.isDesktop })
        if i.meansFront, let f = front, i.chat == nil || i.chat == f { return (.send(f, byFocus: true), "the chat in front -> \(f)") }
        if let c = i.chat {
            if c == topic || c == memory { return (.send(c, byFocus: false), "model \(c) agrees with \(c == topic ? "topic" : "memory")") }
            return ask([c, topic, memory], "model \(c), topic \(topic.map(String.init) ?? "-") -> ask")
        }
        if let t = clearTopic { return (.send(t, byFocus: false), "clear topic -> \(t)") }
        if let m = memory { return (.send(m, byFocus: false), "memory -> \(m)") }
        return ask([], "no chat named or clear -> ask")
    }
}
