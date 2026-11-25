import XCTest
@testable import NeedsYouShared

final class ChoicePickTests: XCTestCase {
    let names = ["recipebox", "Portuguese bakery business plan"]
    let q = "Which chat? 1, recipebox. Or 2, Portuguese bakery business plan?"

    func testNumbers() {
        for s in ["Two.", "2", "number two", "the second", "the second one", "iki", "ikinci", "zwei", "To.", "two please"] {
            XCTAssertEqual(ChoicePick.pick(s, question: q, names: names), 1, s)
        }
        for s in ["One.", "the first one", "bir", "number 1"] {
            XCTAssertEqual(ChoicePick.pick(s, question: q, names: names), 0, s)
        }
        XCTAssertNil(ChoicePick.pick("three", question: q, names: names))
        XCTAssertNil(ChoicePick.pick("I want to go to the store for a while", question: q, names: names))
    }

    func testYesForOneOption() {
        XCTAssertEqual(ChoicePick.pick("Yes.", question: "Which chat? orchard?", names: ["orchard"]), 0)
        XCTAssertNil(ChoicePick.pick("Yes.", question: q, names: names))
    }

    func testNames() {
        XCTAssertEqual(ChoicePick.pick("the Portuguese one", question: q, names: names), 1)
        XCTAssertEqual(ChoicePick.pick("recipebox", question: q, names: names), 0)
        XCTAssertEqual(ChoicePick.pick("bakery business", question: q, names: names), 1)
    }

    func testOwnQuestionInTheMicIsNotHisAnswer() {
        XCTAssertNil(ChoicePick.pick("Which?", question: q, names: names))
        XCTAssertNil(ChoicePick.pick("Which chat", question: q, names: names))
        XCTAssertEqual(ChoicePick.pick("Which chat? One, recipebox. Or two, Portuguese bakery business plan? Two.", question: q, names: names), 1)
        XCTAssertEqual(ChoicePick.pick("Or two, Portuguese bakery business plan. Two.", question: q, names: names), 1)
        XCTAssertEqual(ChoicePick.stripEcho("Which chat? One recipebox", question: q), "")
    }
}
