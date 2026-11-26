import XCTest
@testable import NeedsYouShared

/// The intent evaluation set and its scoring (HM-1433). The model itself runs in
/// `needs-you intent-eval`; here the checks around it.
final class IntentEvalTests: XCTestCase {
    func testTheSetCoversEveryAction() {
        XCTAssertGreaterThanOrEqual(IntentEval.cases.count, 60)
        for a in VoiceIntent.Action.allCases { XCTAssertTrue(IntentEval.cases.contains { $0.group == a }, a.rawValue) }
        for c in IntentEval.cases { if let n = c.chat { XCTAssertTrue(IntentEval.chats.indices.contains(n - 1), c.text) } }
        for c in IntentEval.clarifyCases { XCTAssertTrue(c.offered.allSatisfy { IntentEval.chats.indices.contains($0 - 1) }) }
    }

    func testTheReportedBugIsAMiss() {
        let c = IntentEval.cases[0]
        XCTAssertTrue(c.text.contains("voicemail"))
        XCTAssertFalse(IntentEval.score(c, VoiceIntent(action: .voicemails)).ok)
        XCTAssertFalse(IntentEval.score(c, VoiceIntent(action: .away)).ok, "three hours were said")
        XCTAssertTrue(IntentEval.score(c, VoiceIntent(action: .away, time: AwayTime(minutes: 180))).ok)
    }

    func testTimesAreComparedByTheirEnd() {
        let c = IntentEval.Case("do not disturb until 3 pm", [.away], time: .until(hour: 15, day: nil, part: nil))
        XCTAssertTrue(IntentEval.score(c, VoiceIntent(action: .away, time: AwayTime(hour: 3, pm: true, day: .today))).ok)
        XCTAssertFalse(IntentEval.score(c, VoiceIntent(action: .away, time: AwayTime(minutes: 15))).ok)
    }

    func testAMadeUpTimeIsAMiss() {
        let c = IntentEval.Case("going for lunch, hold everything", [.away])
        XCTAssertTrue(IntentEval.score(c, VoiceIntent(action: .away)).ok)
        XCTAssertFalse(IntentEval.score(c, VoiceIntent(action: .away, time: AwayTime(minutes: 60))).ok)
    }

    func testSendNeedsTheRightChat() {
        let c = IntentEval.Case("docs site: add a voicemail section to the readme", [.send], chat: 3)
        XCTAssertTrue(IntentEval.score(c, VoiceIntent(action: .send, chat: 2)).ok)
        XCTAssertTrue(IntentEval.score(c, VoiceIntent(action: .send, named: "docs site")).ok)
        XCTAssertFalse(IntentEval.score(c, VoiceIntent(action: .send, chat: 0)).ok)
        XCTAssertFalse(IntentEval.score(c, VoiceIntent(action: .voicemails)).ok)
    }

    func testACommandThatNamesAChatIsForThatChat() {
        let chats = IntentEval.candidates
        let rest = "orchard, I'm going to be away for a while so finish the planting calendar on your own"
        let i = VoiceIntent(action: .away, named: "orchard", time: AwayTime(minutes: 60)).forNamedChat(chats, rest: rest)
        XCTAssertEqual(i.action, .send)
        XCTAssertEqual(i.chat, 1)
        XCTAssertEqual(i.time, AwayTime())
        XCTAssertEqual(i.message, "I'm going to be away for a while so finish the planting calendar on your own")
        // A name that is no chat's leaves the command alone.
        let dnd = VoiceIntent(action: .away, named: "do not disturb").forNamedChat(chats, rest: "do not disturb until 8")
        XCTAssertEqual(dnd.action, .away)
        // A send stays as it is.
        let s = VoiceIntent(action: .send, chat: 2, named: "orchard", message: "hi there")
        XCTAssertEqual(s.forNamedChat(chats, rest: "orchard: hi there"), s)
    }

    func testClarifyScoring() {
        let yes = IntentEval.ClarifyCase([3], "yes", .yes)
        XCTAssertTrue(IntentEval.scoreClarify(yes, .send(3)))
        XCTAssertFalse(IntentEval.scoreClarify(yes, .ask))
        let stop = IntentEval.ClarifyCase([3], "cancel", .cancel)
        XCTAssertTrue(IntentEval.scoreClarify(stop, .cancel))
        XCTAssertFalse(IntentEval.scoreClarify(stop, .ask))
        let none = IntentEval.ClarifyCase([1, 3, 6], "none of these", .noneOfThese)
        XCTAssertTrue(IntentEval.scoreClarify(none, .ask))
        XCTAssertFalse(IntentEval.scoreClarify(none, .confirm(3)))
        XCTAssertFalse(IntentEval.scoreClarify(none, .cancel))
        let chat = IntentEval.ClarifyCase([1, 3, 6], "it's the orchard one", .chat(2))
        XCTAssertTrue(IntentEval.scoreClarify(chat, .confirm(2)))
        XCTAssertFalse(IntentEval.scoreClarify(chat, .send(4)))
    }

    func testPresenceCarriesTheTime() {
        let i = VoiceIntent(action: .away, time: AwayTime(minutes: 180))
        XCTAssertEqual(IntentJudge.decide(i, IntentEval.candidates, RouteEvidence()).0, .presence(.away, summary: false, time: AwayTime(minutes: 180)))
    }
}
