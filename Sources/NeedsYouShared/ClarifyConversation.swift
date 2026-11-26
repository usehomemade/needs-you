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
        public init(chat: Int? = nil, cancel: Bool = false, yesNo: YesNo = .unclear, noneOfThese: Bool = false, about: String = "") {
            self.chat = chat; self.cancel = cancel; self.yesNo = yesNo; self.noneOfThese = noneOfThese; self.about = about
        }
    }

    public enum Step: Equatable, Sendable {
        /// Send it there now (he picked an offered chat or said yes).
        case send(Int)
        /// One clear fit: ask "Send it to ...?".
        case confirm(Int)
        /// Unclear: ask again, offering these (closest first).
        case ask([Int])
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

    public init(message: String, offered: [Int]) {
        self.message = message; self.offered = offered
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
    /// whose name's rare words he said.
    public mutating func next(_ r: Reading, pressed: Int? = nil, meaning: [Meaning.Score], byName: Int? = nil) -> Step {
        if let n = pressed, offered.indices.contains(n - 1) { return finish(.send(offered[n - 1])) }
        if r.cancel { return finish(.cancel) }
        let wasConfirming = confirming
        if let c = confirming {
            switch r.yesNo {
            case .yes: return finish(.send(c))
            case .no: rejected.insert(c)
            case .unclear: if r.chat == c || byName == c { return finish(.send(c)) }
            }
            confirming = nil
        }
        if r.noneOfThese { rejected.formUnion(offered) }
        let open = meaning.filter { !rejected.contains($0.index) }
        let lead = Meaning.leader(open)
        let pick = r.chat.flatMap { rejected.contains($0) ? nil : $0 }
        let named = byName.flatMap { rejected.contains($0) ? nil : $0 }
        // An offered chat he picks by voice counts as said (as the number key does).
        if wasConfirming == nil, !r.noneOfThese, let p = pick, offered.contains(p) { return finish(.send(p)) }
        if let p = pick, p == lead || p == named { return confirm(p) }
        if let n = named, lead == nil || lead == n { return confirm(n) }
        if pick == nil, let v = Meaning.veryClear(open) { return confirm(v) }
        var seen = Set<Int>(), out: [Int] = []
        for i in [pick, named].compactMap({ $0 }) + open.prefix(3).map(\.index) where seen.insert(i).inserted { out.append(i) }
        offered = Array(out.prefix(4))
        return .ask(offered)
    }

    private mutating func confirm(_ c: Int) -> Step {
        confirming = c
        offered = [c]
        return .confirm(c)
    }

    private mutating func finish(_ s: Step) -> Step { confirming = nil; return s }
}
