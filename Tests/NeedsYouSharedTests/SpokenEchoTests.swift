import XCTest
@testable import NeedsYouShared

final class SpokenEchoTests: XCTestCase {
    let line = "Okay, I'm ready. Tell me the bugs one by one: what you did, what you expected, and what happened instead."

    func testOwnVoiceIsEcho() {
        XCTAssertTrue(SpokenEcho.isEcho("Tell me the bugs", spoken: line))
        XCTAssertTrue(SpokenEcho.isEcho("what you expected", spoken: line))
        XCTAssertTrue(SpokenEcho.isEcho("Tell me the bug one by one", spoken: line)) // one word misheard
        XCTAssertTrue(SpokenEcho.isEcho("what you did, what you", spoken: line))
    }

    func testStopPhraseInsideTheSpokenTextIsEcho() {
        let s = "If it talks too long, say Stop, Mac and it stops."
        XCTAssertTrue(SpokenEcho.isEcho("Stop, Mac", spoken: s))
        XCTAssertTrue(SpokenEcho.isEcho("stop ma", spoken: s))
    }

    func testUserWordsAreNotEcho() {
        XCTAssertFalse(SpokenEcho.isEcho("Stop, Mac", spoken: line))
        XCTAssertFalse(SpokenEcho.isEcho("Stop", spoken: line))
        XCTAssertFalse(SpokenEcho.isEcho("Hey Mac", spoken: line))
        XCTAssertFalse(SpokenEcho.isEcho("Stop Mack", spoken: "The Mack build for orchard is green."))
    }

    func testOrderMatters() {
        XCTAssertFalse(SpokenEcho.isEcho("instead happened what", spoken: line))
    }

    func testEmpty() {
        XCTAssertTrue(SpokenEcho.isEcho(" . ", spoken: line))
        XCTAssertFalse(SpokenEcho.isEcho("stop", spoken: ""))
    }
}
