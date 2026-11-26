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
    /// The model sometimes hands back a chat's title from the list, or a mix of his words and
    /// the list ("Claude; working on: ..."), as "the name he said". A name counts only when it
    /// is a phrase he really said, word for word (case and punctuation aside); a "name" that is
    /// most of his sentence is none (HM-1408: no salvaging single words out of it).
    public static func spokenName(_ named: String, in rest: String) -> String {
        let n = ChatMatcher.words(named), said = ChatMatcher.words(rest)
        guard !n.isEmpty, n.count < said.count, Double(n.count) < Double(said.count) * 0.8 else { return "" }
        for start in 0...(said.count - n.count) where Array(said[start..<(start + n.count)]) == n {
            return n.joined(separator: " ")
        }
        return ""
    }
}

/// What points at a chat besides the model (HM-1408): the words he shares with a chat's
/// names (`topic`), what the message means next to what each chat works on (`meaning`),
/// and the chats earlier messages like it went to (`learned`).
public struct RouteEvidence: Equatable, Sendable {
    public struct Learned: Equatable, Sendable {
        public var index: Int
        public var weight: Double
        public init(index: Int, weight: Double) { self.index = index; self.weight = weight }
    }
    /// Rare-word overlap with the chats' names and status: the leader, and a lead of two words or more.
    public var topic: Int?
    public var clearTopic: Int?
    /// Every chat with something known about it, closest first.
    public var meaning: [Meaning.Score]
    /// Votes of earlier matches, strongest first.
    public var learned: [Learned]
    /// The chats to offer when nothing points anywhere (most recent first).
    public var recent: [Int]

    public init(topic: Int? = nil, clearTopic: Int? = nil, meaning: [Meaning.Score] = [], learned: [Learned] = [], recent: [Int] = []) {
        self.topic = topic; self.clearTopic = clearTopic; self.meaning = meaning; self.learned = learned; self.recent = recent
    }

    public var meaningLead: Int? { Meaning.leader(meaning) }
    public var meaningVeryClear: Int? { Meaning.veryClear(meaning) }
    public var learnedLead: Int? { leader(RouteLearning.leadWeight) }
    public var learnedVeryClear: Int? { leader(RouteLearning.veryClearWeight) }

    private func leader(_ min: Double) -> Int? {
        guard let best = learned.first, best.weight >= min else { return nil }
        if learned.count > 1, learned[1].weight * 2 > best.weight { return nil }
        return best.index
    }

    /// What backs chat `c` (empty when nothing does).
    public func backing(_ c: Int) -> [String] {
        var out: [String] = []
        if c == meaningLead { out.append("meaning") }
        if c == learnedLead { out.append("learned") }
        if c == topic { out.append("topic") }
        return out
    }

    /// The 3 closest by meaning first, then `extra`, then the recent chats; 4 at most.
    public func offer(_ extra: [Int?]) -> [Int] {
        var seen = Set<Int>(), out: [Int] = []
        let close = meaning.filter { $0.sim >= Meaning.minSim }.prefix(3).map(\.index)
        for i in close + extra.compactMap({ $0 }) + recent where seen.insert(i).inserted { out.append(i) }
        return Array(out.prefix(4))
    }
}

/// Turns the model's reading into what happens. Never a guess (26 Nov): a message is sent
/// only when the chat he named matches one chat, he pointed at the chat in front, the model's
/// pick agrees with meaning, learned votes or the words he said, or meaning and learned
/// votes clearly agree with the model not disagreeing. Everything else asks, closest first.
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

    /// `intent.named` must already be a phrase he said (`VoiceIntent.spokenName`).
    public static func decide(_ intent: VoiceIntent?, _ chats: [ChatCandidate], _ ev: RouteEvidence,
                              isProject: (String) -> Bool = { _ in false }) -> (Outcome, String) {
        func ask(_ extra: [Int?], _ why: String) -> (Outcome, String) { (.ask(ev.offer(extra), heard: ""), why) }
        /// No model pick (or no model): the data decides only when it clearly agrees.
        func dataOnly(_ prefix: String) -> (Outcome, String)? {
            let m = ev.meaningLead, l = ev.learnedLead
            if let m, m == l { return (.send(m, byFocus: false), prefix + "meaning and learned -> \(m)") }
            if let m = ev.meaningVeryClear, l == nil || l == m, ev.topic == nil || ev.topic == m {
                return (.send(m, byFocus: false), prefix + "meaning very clear -> \(m)")
            }
            if let v = ev.learnedVeryClear, m == nil || m == v { return (.send(v, byFocus: false), prefix + "learned very clear -> \(v)") }
            if let t = ev.clearTopic, m == nil || m == t, l == nil || l == t { return (.send(t, byFocus: false), prefix + "clear topic -> \(t)") }
            return nil
        }
        guard let i = intent else { return dataOnly("no model; ") ?? ask([], "no model -> ask") }
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
            // The model may have read part of the message as a name: its pick still counts when the data backs it.
            if let c = i.chat, !ev.backing(c).isEmpty { return (.send(c, byFocus: false), log + "; model \(c) agrees with \(ev.backing(c).joined(separator: "+"))") }
            return (.notFound(named), log + "; no such chat")
        }
        let front = chats.firstIndex(where: { $0.isDesktop && $0.focused }) ?? chats.firstIndex(where: { $0.focused && !$0.isDesktop })
        if i.meansFront, let f = front, i.chat == nil || i.chat == f { return (.send(f, byFocus: true), "the chat in front -> \(f)") }
        if let c = i.chat {
            let b = ev.backing(c)
            if !b.isEmpty { return (.send(c, byFocus: false), "model \(c) agrees with \(b.joined(separator: "+"))") }
            return ask([c, ev.learnedLead, ev.topic], "model \(c), meaning \(ev.meaningLead.map(String.init) ?? "-"), learned \(ev.learnedLead.map(String.init) ?? "-") -> ask")
        }
        return dataOnly("") ?? ask([ev.learnedLead, ev.topic], "no chat named or clear -> ask")
    }
}
