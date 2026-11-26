import XCTest
@testable import NeedsYouShared

final class DuckStateTests: XCTestCase {
    func testIdleDoesNotDuck() {
        let s = DuckState()
        XCTAssertFalse(s.wantsDuck(now: 0))
        XCTAssertFalse(s.engineOn(now: 0))
        XCTAssertNil(s.nextChange(now: 0))
    }

    func testHoldDucksAndReleaseLingers() {
        var s = DuckState(linger: 1)
        s.hold("command:mac", now: 0)
        XCTAssertTrue(s.engineOn(now: 0.5))
        s.release("command:mac", now: 2)
        XCTAssertTrue(s.engineOn(now: 2.5), "stays low through the linger")
        XCTAssertFalse(s.engineOn(now: 3))
        s.expire(now: 3)
        XCTAssertNil(s.lingerUntil)
    }

    func testSameHolderTwiceCountsOnce() {
        var s = DuckState(linger: 0)
        s.hold("answer", now: 0)
        s.hold("answer", now: 1)
        XCTAssertEqual(s.holders.count, 1)
        s.release("answer", now: 2)
        XCTAssertFalse(s.wantsDuck(now: 2))
    }

    func testAudioReturnsOnlyAfterTheLastHolder() {
        var s = DuckState(linger: 0)
        s.hold("command:mac", now: 0)
        s.hold("command:iphone", now: 0)
        s.release("command:mac", now: 1)
        XCTAssertTrue(s.wantsDuck(now: 1))
        s.release("command:iphone", now: 2)
        XCTAssertFalse(s.wantsDuck(now: 2))
    }

    func testReleaseWithoutHoldDoesNothing() {
        var s = DuckState(linger: 5)
        s.release("answer", now: 0)
        XCTAssertNil(s.lingerUntil)
        XCTAssertFalse(s.wantsDuck(now: 0))
    }

    func testHoldDuringLingerCancelsIt() {
        var s = DuckState(linger: 1)
        s.hold("command:mac", now: 0)
        s.release("command:mac", now: 1)
        s.hold("answer", now: 1.5) // "which chat?" answer right after the command
        XCTAssertNil(s.lingerUntil)
        XCTAssertTrue(s.wantsDuck(now: 10))
    }

    func testVoiceTakesOverAndHandsBack() {
        var s = DuckState(linger: 0)
        s.hold("answer", now: 0)
        s.voice(true) // barge-in: the voice player ducks on its own
        XCTAssertTrue(s.wantsDuck(now: 0))
        XCTAssertFalse(s.engineOn(now: 0))
        s.voice(false)
        XCTAssertTrue(s.engineOn(now: 0), "he still talks: the ducker takes over again")
        s.release("answer", now: 1)
        XCTAssertFalse(s.engineOn(now: 1))
    }

    func testVoiceAloneDoesNotStartTheEngine() {
        var s = DuckState()
        s.voice(true)
        s.voice(false)
        XCTAssertFalse(s.engineOn(now: 0))
    }

    func testStaleHolderExpires() {
        var s = DuckState(linger: 0, maxHold: 60)
        s.hold("command:mac", now: 0)
        XCTAssertEqual(s.nextChange(now: 1), 60)
        s.expire(now: 59)
        XCTAssertTrue(s.wantsDuck(now: 59))
        s.expire(now: 60)
        XCTAssertFalse(s.wantsDuck(now: 60))
    }

    func testReleaseAllIsImmediate() {
        var s = DuckState(linger: 5)
        s.hold("answer", now: 0)
        s.hold("command:mac", now: 0)
        s.releaseAll()
        XCTAssertFalse(s.wantsDuck(now: 0))
    }

    func testNextChangeIsTheLingerEnd() {
        var s = DuckState(linger: 1.2, maxHold: 300)
        s.hold("answer", now: 0)
        s.release("answer", now: 10)
        XCTAssertEqual(s.nextChange(now: 10)!, 11.2, accuracy: 1e-9)
    }
}
