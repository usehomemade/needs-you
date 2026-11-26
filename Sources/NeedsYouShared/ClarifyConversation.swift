import Foundation

/// "Which chat?" as a conversation (HM-1408, the owner: "just keep searching"): no round
/// limit. It keeps his message, every question and every answer. "None of them" or pointing
/// at another chat is not a cancel; only an explicit stop (the model reads it), Escape twice,
/// or silence ends it without a chat. After each answer every chat is searched again, by
/// meaning and by the model, with the whole conversation as context.
public struct ClarifyConversation: Equatable, Sendable {
    public struct Exchange: Equatable, Sendable {
        public var question: String
        public var answer: String?
    }

    /// His answer as the model read it (or, without a model, as the names matched it).
    public struct Reading: Equatable, Sendable {
        public enum YesNo: String, Sendable { case yes, no, unclear }
        /// Index into all chats he means, by number, name or what it is about.
        public var chat: Int?
        /// He clearly said to stop and send nothing.
        public var cancel: Bool
        /// His answer to "Send it to ...?".
        public var yesNo: YesNo
        /// None of the chats offered is right.
        public var noneOfThese: Bool
        /// What he says the chat is about, in his words.
        public var about: String
        /// The model is sure his last answer picks `chat` (HM-1425): an unsure pick never sends.
        public var sure: Bool
        /// He picked it by its number or place in the list ("two", "the second one").
        public var byNumber: Bool
        /// The name he called the chat by, in his words; empty when he named none.
        public var named: String
        public init(chat: Int? = nil, cancel: Bool = false, yesNo: YesNo = .unclear, noneOfThese: Bool = false, about: String = "",
                    sure: Bool = false, byNumber: Bool = false, named: String = "") {
            self.chat = chat; self.cancel = cancel; self.yesNo = yesNo; self.noneOfThese = noneOfThese; self.about = about
            self.sure = sure; self.byNumber = byNumber; self.named = named
        }
    }

    public enum Step: Equatable, Sendable {
        /// Send it there now (he picked an offered chat or said yes).
        case send(Int)
        /// One clear fit: ask "Send it to ...?".
        case confirm(Int)
        /// Unclear: ask again, offering these (closest first).
        case ask([Int])
        /// He called the chat by a name no chat has (HM-1425): say so and ask again.
        case notFound(String)
        case cancel
    }

    public var message: String
    public private(set) var exchanges: [Exchange] = []
    /// Indices (into all chats) offered in the last question, in the order said.
    public private(set) var offered: [Int]
    /// The chat in "Send it to ...?", while that question is open.
    public private(set) var confirming: Int?
    /// Chats he said no to, or "none of these" about.
    public private(set) var rejected: Set<Int> = []
    /// What he has said about the chat he means, all answers together (meaning searches this).
    public private(set) var described: [String] = []

    /// One chat offered ("needs-you?") is a yes-or-no question, like "Send it to ...?".
    public init(message: String, offered: [Int]) {
        self.message = message; self.offered = offered
        if offered.count == 1 { confirming = offered[0] }
    }

    public mutating func asked(_ question: String) { exchanges.append(Exchange(question: question, answer: nil)) }

    public mutating func answered(_ answer: String) {
        if exchanges.isEmpty { exchanges.append(Exchange(question: "", answer: answer)) } else { exchanges[exchanges.count - 1].answer = answer }
        described.append(answer)
    }

    /// The text meaning searches after his answers: what he said about the chat, then the model's summary of it.
    public func searchText(about: String = "") -> String {
        (described + [about]).filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// The conversation so far, for the model.
    public var transcript: String {
        (["His message: \u{201C}\(message)\u{201D}"] + exchanges.flatMap { e -> [String] in
            ["You asked: \u{201C}\(e.question)\u{201D}"] + (e.answer.map { ["He answered: \u{201C}\($0)\u{201D}"] } ?? [])
        }).joined(separator: "\n")
    }

    /// What to do after his latest answer. `pressed`: the number key he pressed (1-based) for an
    /// offered chat. `meaning`: all chats ranked by meaning against `searchText`. `byName`: a chat
    /// whose name he said. `missingName`: a name he said that no chat has.
    ///
    /// Nothing is sent without his number, his yes, or two signals that agree (HM-1425): the
    /// model's sure pick and his name for it or the meaning leader. Words that point at another
    /// chat (a name that ranks it, or meaning leading elsewhere) or at no chat keep it open.
    public mutating func next(_ r: Reading, pressed: Int? = nil, meaning: [Meaning.Score], byName: Int? = nil,
                              missingName: String? = nil) -> Step {
        if let n = pressed, offered.indices.contains(n - 1) { return finish(.send(offered[n - 1])) }
        if r.cancel { return finish(.cancel) }
        let wasConfirming = confirming
        let lead0 = Meaning.leader(meaning.filter { !rejected.contains($0.index) })
        /// His words point somewhere else than `c`: another chat by name or meaning, or a name no chat has.
        func pointsElsewhere(_ c: Int) -> Bool {
            missingName != nil || (byName.map { $0 != c } ?? false) || (lead0.map { $0 != c } ?? false)
        }
        /// The model's sure pick of `c`, backed by his number, his name for it, or meaning.
        func agreed(_ c: Int) -> Bool {
            r.chat == c && r.sure && !pointsElsewhere(c) && (r.byNumber || byName == c || lead0 == c)
        }
        if let c = confirming {
            // His own words naming another chat (or one that does not exist) outweigh a yes.
            let namesOther = missingName != nil || (byName.map { $0 != c } ?? false) || (r.chat.map { $0 != c } ?? false)
            switch r.yesNo {
            case .yes where !namesOther: return finish(.send(c))
            case .yes: break // "yes, the bakery one": look again
            case .no: rejected.insert(c)
            case .unclear:
                // "The orchard one": the model and his name for it agree.
                if agreed(c) || (r.chat == c && byName == c && missingName == nil) { return finish(.send(c)) }
            }
            confirming = nil
        }
        if r.noneOfThese { rejected.formUnion(offered) }
        let open = meaning.filter { !rejected.contains($0.index) }
        let lead = Meaning.leader(open)
        let pick = r.chat.flatMap { rejected.contains($0) ? nil : $0 }
        let named = byName.flatMap { rejected.contains($0) ? nil : $0 }
        // An offered chat he picks by voice counts as said (as the number key does), only when the
        // model is sure and his number, his name for it or the meaning backs it (HM-1425).
        if wasConfirming == nil, !r.noneOfThese, let p = pick, offered.contains(p), agreed(p) { return finish(.send(p)) }
        // Sure, but nothing backs it: ask "Send it to ...?" rather than send.
        if let p = pick, r.sure, !pointsElsewhere(p), p != wasConfirming { return confirm(p) }
        // A name no chat has: say so, never fall back to the chat offered. Two other signals that
        // agree on one chat (model, his words, meaning) still offer it: "Send it to ...?".
        if let m = missingName {
            let backed = [pick, named].compactMap { $0 }.first { $0 == lead } ?? (pick != nil && pick == named ? pick : nil)
            if let b = backed { return confirm(b) }
            offered = []
            return .notFound(m)
        }
        if let p = pick, p == lead || p == named { return confirm(p) }
        if let n = named, lead == nil || lead == n { return confirm(n) }
        if pick == nil, let v = Meaning.veryClear(open) { return confirm(v) }
        var seen = Set<Int>(), out: [Int] = []
        for i in [pick, named].compactMap({ $0 }) + open.prefix(3).map(\.index) where seen.insert(i).inserted { out.append(i) }
        offered = Array(out.prefix(4))
        return .ask(offered)
    }

    /// The model's name, if he really said it: its words, in order, in his answer.
    public static func spokenName(_ named: String, in answer: String) -> String {
        let n = ChatMatcher.words(named), said = ChatMatcher.words(answer)
        guard !n.isEmpty, n.count <= said.count else { return "" }
        for start in 0...(said.count - n.count) where Array(said[start..<(start + n.count)]) == n {
            return n.joined(separator: " ")
        }
        return ""
    }

    public enum NameMatch: Equatable, Sendable {
        /// One chat clearly has that name.
        case chat(Int)
        /// Several chats share part of it.
        case unclear
        /// No chat has anything like it.
        case missing
    }

    /// Which chat a name he said is (tab label, workspace, folder, title). Words no chat has at
    /// all (a mishearing like "in herdr" as "inherder") are dropped when most of the name is known.
    public static func nameMatch(_ named: String, _ chats: [ChatCandidate]) -> NameMatch {
        func clear(_ heard: String) -> Int? {
            let ranked = ChatMatcher.rank(heard, chats)
            guard let best = ranked.first, best.score >= 0.5, (ranked.dropFirst().first?.score ?? 0) <= best.score - 0.2 else { return nil }
            return best.index
        }
        let words = ChatMatcher.words(named)
        guard !words.isEmpty, !chats.isEmpty else { return .unclear }
        if let i = clear(named) { return .chat(i) }
        let known = words.filter { w in chats.contains { c in
            ChatMatcher.words(([c.label, c.folder, c.title] + c.aliases).joined(separator: " ").replacingOccurrences(of: "-", with: " "))
                .contains { ChatMatcher.similar(w, $0) }
        } }
        if known.isEmpty { return .missing }
        if known.count < words.count, Double(known.count) >= Double(words.count) / 2, let i = clear(known.joined(separator: " ")) { return .chat(i) }
        return .unclear
    }

    private mutating func confirm(_ c: Int) -> Step {
        confirming = c
        offered = [c]
        return .confirm(c)
    }

    private mutating func finish(_ s: Step) -> Step { confirming = nil; return s }
}
