import XCTest
@testable import NeedsYouShared

/// Spoken answers are read by the on-device model (HM-1399). Code only drops our own
/// question from the mic and, with no model, finds a chat by the rare words of its name.
final class ChoicePickTests: XCTestCase {
    /// 26 Nov 12:33: the answer named a chat that was not offered.
    func testAnswerNamesAChatByItsRareWords() {
        let all = ["Spreadsheet formula request", "Printer setup request", "Lisbon and Porto trip planner", "needs-you"]
        XCTAssertEqual(ChoicePick.name("None of them. There is a chat called Printer Setup Request in Cloud Desktop App.", names: all), 1)
    }

    /// 26 Nov 12:24: "Cloud Code needs you chat." went to the home-folder chat.
    func testWordsEveryChatSharesDoNotPick() {
        let all = ["Claude Code in your home folder", "Claude Code: needs-you", "Claude Code: trip planner"]
        XCTAssertEqual(ChoicePick.name("Claude Code needs you chat.", names: all), 1)
    }

    let names = ["recipebox", "Portuguese bakery business plan"]
    let q = "Which chat? 1, recipebox. Or 2, Portuguese bakery business plan?"

    func testNames() {
        XCTAssertEqual(ChoicePick.name("the Portuguese one", names: names), 1)
        XCTAssertEqual(ChoicePick.name("recipebox", names: names), 0)
        XCTAssertNil(ChoicePick.name("I want to go to the store", names: names))
    }

    func testOwnQuestionInTheMicIsDropped() {
        XCTAssertEqual(ChoicePick.stripEcho("Which chat? One recipebox", question: q, names: names), "")
        XCTAssertEqual(ChoicePick.stripEcho("Portuguese bakery business plan", question: q, names: names), "Portuguese bakery business plan")
    }
}
