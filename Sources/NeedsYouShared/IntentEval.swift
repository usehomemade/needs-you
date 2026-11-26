import Foundation

/// The intent evaluation set (HM-1433): natural phrasings with what each should do, read by the
/// real on-device model in `needs-you intent-eval` (the model is not available in `swift test`).
/// Made-up chats only. The scoring here is pure, so it is unit tested.
public enum IntentEval {
    /// One made-up chat the model sees (1-based in the cases).
    public struct Chat: Sendable {
        public var title: String, folder: String, detail: String, label: String, workspace: String
        public var desktop: Bool, focused: Bool
        public init(_ title: String, folder: String = "", detail: String = "", label: String = "", workspace: String = "",
                    desktop: Bool = false, focused: Bool = false) {
            self.title = title; self.folder = folder; self.detail = detail; self.label = label; self.workspace = workspace
            self.desktop = desktop; self.focused = focused
        }
    }

    public static let chats: [Chat] = [
        Chat("recipebox", folder: "recipebox", detail: "importing recipes from web links, ingredient parsing", focused: true),
        Chat("orchard", folder: "orchard", detail: "fruit tree planting calendar app"),
        Chat("docs site", folder: "docs-site", detail: "documentation website: readme, guides and pages"),
        Chat("bakery", folder: "bakery-pos", detail: "point of sale for a bakery: receipts, payments, printer", label: "bakery", workspace: "shops"),
        Chat("Claude", desktop: true),
        Chat("travel-planner", folder: "travel-planner", detail: "trip itinerary planner: flights, trains and hotels"),
    ]

    /// What a case expects when he wants quiet: a length or an end, compared by the date it gives at `reference`.
    public enum Time: Equatable, Sendable {
        case minutes(Int)
        case until(hour: Int?, day: AwayTime.Day?, part: AwayTime.Part?)
        public var expected: AwayTime {
            switch self {
            case .minutes(let m): return AwayTime(minutes: m)
            case .until(let h, let d, let p): return AwayTime(hour: h, day: d, part: p)
            }
        }
    }

    /// Wednesday 25 November 2026, 10:00 local: the "now" times are checked at.
    public static var reference: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10)) ?? Date()
    }

    public static var candidates: [ChatCandidate] {
        chats.map { ChatCandidate(title: $0.title, label: $0.label, folder: $0.folder, focused: $0.focused, isDesktop: $0.desktop) }
    }

    public struct Case: Sendable {
        public var text: String
        /// Any of these actions is right (usually one).
        public var actions: [VoiceIntent.Action]
        /// For send: the 1-based chat it is for (nil: any chat, or asking, is fine).
        public var chat: Int?
        public var time: Time?
        public var summary: Bool?
        public init(_ text: String, _ actions: [VoiceIntent.Action], chat: Int? = nil, time: Time? = nil, summary: Bool? = nil) {
            self.text = text; self.actions = actions; self.chat = chat; self.time = time; self.summary = summary
        }
        /// The action the table counts it under.
        public var group: VoiceIntent.Action { actions[0] }
    }

    public static let cases: [Case] = [
        // away: he will be unavailable; questions wait as voicemails
        Case("I'm gonna be out of home for I think three hours so let everything go to voicemail.", [.away], time: .minutes(180)),
        Case("I'm out for three hours", [.away], time: .minutes(180)),
        Case("back in 20 minutes", [.away], time: .minutes(20)),
        Case("going for lunch, hold everything", [.away]),
        Case("let everything go to voicemail", [.away]),
        Case("I'm stepping out for a bit", [.away]),
        Case("taking a shower, keep my messages for later", [.away]),
        Case("heading to the gym for an hour and a half", [.away], time: .minutes(90)),
        Case("don't let anyone talk to me for the next 45 minutes", [.away], time: .minutes(45)),
        Case("turn on do not disturb", [.away]),
        Case("do not disturb until 3 pm", [.away], time: .until(hour: 15, day: nil, part: nil)),
        Case("do not disturb for one hour", [.away], time: .minutes(60)),
        Case("I'm in a meeting until 4", [.away], time: .until(hour: 4, day: nil, part: nil)),
        Case("hold all the questions until Monday", [.away], time: .until(hour: nil, day: .monday, part: nil)),
        Case("I'll be away until this evening", [.away], time: .until(hour: nil, day: nil, part: .evening)),
        Case("quiet mode please, I need to focus", [.away]),
        Case("do not disturb until 8", [.away], time: .until(hour: 8, day: nil, part: nil)),
        Case("I'm picking up the kids, be back in half an hour", [.away], time: .minutes(30)),
        // good night: he goes to sleep
        Case("good night", [.goodNight]),
        Case("going to sleep", [.goodNight]),
        Case("I'm off to bed, talk tomorrow", [.goodNight]),
        Case("don't bother me till morning", [.goodNight, .away], time: .until(hour: nil, day: nil, part: .morning)),
        Case("night night, see you in the morning", [.goodNight]),
        Case("do not disturb until tomorrow morning", [.away, .goodNight], time: .until(hour: nil, day: .tomorrow, part: .morning)),
        // back
        Case("I'm back", [.back]),
        Case("home again, what did I miss", [.back], summary: true),
        Case("good morning", [.back]),
        Case("okay I'm here again, you can talk to me", [.back]),
        Case("turn off do not disturb", [.back]),
        Case("I'm back, what did you all work on while I was out", [.back], summary: true),
        // voicemails: he wants to hear the held messages now
        Case("play my messages", [.voicemails]),
        Case("what did the agents ask while I was gone", [.voicemails]),
        Case("any voicemails?", [.voicemails]),
        Case("read me the voicemails", [.voicemails]),
        Case("do I have any messages waiting", [.voicemails]),
        Case("play the next voicemail", [.voicemails]),
        // summary
        Case("what did you work on", [.summary]),
        Case("what happened last night", [.summary, .voicemails]),
        Case("give me a summary of what the agents did", [.summary]),
        Case("what got done while I was out", [.summary]),
        // list chats
        Case("which chats are open", [.listChats]),
        Case("list my chats", [.listChats]),
        Case("what chats do I have running", [.listChats]),
        Case("who can I talk to right now", [.listChats]),
        // new chat
        Case("new chat in orchard: add a watering reminder", [.newChat]),
        Case("start a new conversation in Claude about tax deductions", [.newChat]),
        Case("open a new chat in the weather station project and set up the sensors", [.newChat]),
        Case("new chat: plan a birthday party", [.newChat]),
        // send, named (several mention voicemail, away, play, list or summary but are for a chat)
        Case("docs site: add a voicemail section to the readme", [.send], chat: 3),
        Case("tell the bakery chat the receipts look wrong", [.send], chat: 4),
        Case("orchard, I'm going to be away for a while so finish the planting calendar on your own", [.send], chat: 2),
        Case("send to travel planner: book the hotel for three nights", [.send], chat: 6),
        Case("recipebox: when I'm back, show me the import results", [.send], chat: 1),
        Case("docs site, write a page about do not disturb mode", [.send], chat: 3),
        Case("tell orchard that good night mode should dim the screen", [.send], chat: 2),
        Case("bakery: play a sound when a payment comes in", [.send], chat: 4),
        Case("ask the docs chat to list all the open issues", [.send], chat: 3),
        Case("travel planner, summarize what you did on the flight search", [.send], chat: 6),
        Case("tell recipebox I'll be out for an hour, keep going without me", [.send], chat: 1),
        // send, by what it is about or the chat in front
        Case("the recipe import fails on links with emojis, can you fix it", [.send], chat: 1),
        Case("the receipt printer cuts off the last line", [.send], chat: 4),
        Case("add a page to the guides about installing on Windows", [.send], chat: 3),
        Case("the flight search should also show trains", [.send], chat: 6),
        Case("in this chat, make the voicemail list sortable", [.send]),
        Case("tell it to run the tests again", [.send]),
        // more phrasings, added after the model work was done (a check that it was not tuned to the ones above)
        Case("I'm heading out to the store, back in about 40 minutes", [.away], time: .minutes(40)),
        Case("can you hold everything for two hours", [.away], time: .minutes(120)),
        Case("I'm on a call until 5", [.away], time: .until(hour: 5, day: nil, part: nil)),
        Case("time for bed", [.goodNight]),
        Case("I'm home", [.back]),
        Case("you can talk to me again", [.back]),
        Case("read my voicemails", [.voicemails]),
        Case("what did the chats get done today", [.summary]),
        Case("show me the open chats", [.listChats]),
        Case("bakery, list the payments from yesterday", [.send], chat: 4),
        Case("travel planner: I'll be away next week, plan the hotel for that", [.send], chat: 6),
        Case("the ingredient parser drops fractions", [.send], chat: 1),
        Case("start a fresh chat in Claude about my resume", [.newChat]),
        Case("oh sorry, wrong button", [.nothing]),
        // nothing
        Case("never mind", [.nothing]),
        Case("um what was I going to say", [.nothing]),
        Case("the weather is nice today", [.nothing]),
        Case("testing testing one two three", [.nothing]),
    ]

    // MARK: "Which chat?" answers

    public enum Answer: Equatable, Sendable {
        case yes, no, cancel, noneOfThese
        /// He means this chat (1-based).
        case chat(Int)
        /// Not clear: no chat may be picked for sure, and it is no stop.
        case unclear
    }

    public struct ClarifyCase: Sendable {
        /// The chats offered, 1-based, in the order said.
        public var offered: [Int]
        public var answer: String
        public var expect: Answer
        public init(_ offered: [Int], _ answer: String, _ expect: Answer) { self.offered = offered; self.answer = answer; self.expect = expect }
        public var group: String {
            switch expect {
            case .yes: return "yes"
            case .no: return "no"
            case .cancel: return "cancel"
            case .noneOfThese: return "none-of-these"
            case .chat: return "chat"
            case .unclear: return "unclear"
            }
        }
    }

    public static let clarifyCases: [ClarifyCase] = [
        // "Send it to docs site?"
        ClarifyCase([3], "yes", .yes),
        ClarifyCase([3], "yeah go ahead", .yes),
        ClarifyCase([3], "sure, send it", .yes),
        ClarifyCase([3], "yep, that one", .yes),
        ClarifyCase([3], "please do", .yes),
        ClarifyCase([3], "correct", .yes),
        ClarifyCase([3], "no", .no),
        ClarifyCase([3], "nope, not that one", .no),
        ClarifyCase([3], "no, wrong chat", .no),
        ClarifyCase([3], "no, the bakery one", .chat(4)),
        ClarifyCase([3], "cancel", .cancel),
        ClarifyCase([3], "forget it, don't send it", .cancel),
        ClarifyCase([3], "stop, never mind", .cancel),
        // "Which chat? recipebox, docs site or travel-planner?"
        ClarifyCase([1, 3, 6], "the second one", .chat(3)),
        ClarifyCase([1, 3, 6], "travel planner", .chat(6)),
        ClarifyCase([1, 3, 6], "number one", .chat(1)),
        ClarifyCase([1, 3, 6], "the one about flights", .chat(6)),
        ClarifyCase([1, 3, 6], "the documentation one", .chat(3)),
        ClarifyCase([1, 3, 6], "it's the orchard one", .chat(2)),
        ClarifyCase([1, 3, 6], "none of these", .noneOfThese),
        ClarifyCase([1, 3, 6], "none of them", .noneOfThese),
        ClarifyCase([1, 3, 6], "not any of those", .noneOfThese),
        ClarifyCase([1, 3, 6], "none of them, it's for the bakery", .chat(4)),
        ClarifyCase([1, 3, 6], "cancel that", .cancel),
        ClarifyCase([1, 3, 6], "don't send it", .cancel),
        ClarifyCase([1, 3, 6], "hmm I don't know", .unclear),
        ClarifyCase([1, 3, 6], "the one I was using before", .unclear),
    ]

    /// What the conversation does next, in 1-based chats of `chats`.
    public enum Next: Equatable, Sendable {
        case send(Int), confirm(Int), ask, notFound, cancel
    }

    /// Right when it sends to the chat he means (or asks "Send it to X?" about it), stops only
    /// when he says so, and never sends to a chat he did not pick.
    public static func scoreClarify(_ c: ClarifyCase, _ n: Next) -> Bool {
        switch c.expect {
        case .yes: return n == .send(c.offered[0])
        case .no:
            if case .send = n { return false }
            return n != .cancel && n != .confirm(c.offered[0])
        case .cancel: return n == .cancel
        case .noneOfThese:
            if case .send = n { return false }
            if case .confirm(let x) = n, c.offered.contains(x) { return false }
            return n != .cancel
        case .chat(let x): return n == .send(x) || n == .confirm(x)
        case .unclear:
            if case .send = n { return false }
            return n != .cancel
        }
    }

    public static func clarifyTable(_ rows: [(String, Bool)], title: String) -> String {
        var out = "\(title)\n"
        var groups: [String] = []
        for r in rows where !groups.contains(r.0) { groups.append(r.0) }
        for g in groups {
            let r = rows.filter { $0.0 == g }
            out += g.padding(toLength: 14, withPad: " ", startingAt: 0) + String(format: "%5d  %6.0f%%\n", r.count, 100.0 * Double(r.filter(\.1).count) / Double(r.count))
        }
        out += String(format: "total         %5d  %6.0f%%", rows.count, 100.0 * Double(rows.filter(\.1).count) / Double(rows.count))
        return out
    }

    public struct Result: Equatable, Sendable {
        public var actionOK: Bool
        /// nil when the case expects no chat or no time.
        public var chatOK: Bool?
        public var timeOK: Bool?
        public var summaryOK: Bool?
        public var ok: Bool { actionOK && chatOK != false && timeOK != false && summaryOK != false }
    }

    /// Checks one reading. `chat` in the intent is 0-based; a send whose name or pick fits counts.
    public static func score(_ c: Case, _ i: VoiceIntent?) -> Result {
        guard let i else { return Result(actionOK: false) }
        let actionOK = c.actions.contains(i.action)
        var chatOK: Bool?
        if let want = c.chat, c.actions == [.send] {
            let byName = !i.named.isEmpty && {
                let ranked = ChatMatcher.rank(i.named, candidates)
                return ranked.first?.index == want - 1 && (ranked.first?.score ?? 0) >= 0.5
            }()
            chatOK = i.action == .send && (i.chat == want - 1 || byName)
        }
        var timeOK: Bool?
        if let t = c.time {
            let now = reference
            timeOK = i.time.end(now: now) == t.expected.end(now: now)
        } else if [.away, .goodNight].contains(c.group), c.actions.contains(i.action) {
            // No time said: none may be made up (good night may end in the morning).
            timeOK = i.time.isEmpty || (i.action == .goodNight && i.time.end(now: reference) == AwayTime(part: .morning).end(now: reference))
        }
        let summaryOK = c.summary.map { $0 == i.summary }
        return Result(actionOK: actionOK, chatOK: chatOK, timeOK: timeOK, summaryOK: summaryOK)
    }

    /// Per action: right / total, as table rows.
    public static func table(_ rows: [(Case, Result)]) -> String {
        var out = "action        cases  action%  all%\n"
        for a in VoiceIntent.Action.allCases {
            let r = rows.filter { $0.0.group == a }
            guard !r.isEmpty else { continue }
            let act = r.filter { $0.1.actionOK }.count, all = r.filter { $0.1.ok }.count
            out += a.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
                + String(format: "%5d  %6.0f%%  %4.0f%%\n", r.count, 100.0 * Double(act) / Double(r.count), 100.0 * Double(all) / Double(r.count))
        }
        let act = rows.filter { $0.1.actionOK }.count, all = rows.filter { $0.1.ok }.count
        out += String(format: "total         %5d  %6.0f%%  %4.0f%%", rows.count, 100.0 * Double(act) / Double(rows.count), 100.0 * Double(all) / Double(rows.count))
        return out
    }
}
