import XCTest
@testable import NeedsYouShared

final class PillRulesTests: XCTestCase {
    func testEveryStateButIdleHasAWayOut() {
        for m in PillMode.allCases where m != .idle {
            XCTAssertNotNil(PillRules.timeout(m), "\(m) must end on its own")
        }
        XCTAssertNil(PillRules.timeout(.idle))
        XCTAssertLessThan(PillRules.timeout(.thinking, waitingForTake: true)!, PillRules.timeout(.thinking)!)
        XCTAssertEqual(PillRules.timeout(.sending, sendSeconds: 2), 6)
    }

    func testEveryCommandOutcomeFoldsBackOrShowsIt() {
        // From the states a command can be in when it ends.
        for mode in [PillMode.thinking, .sending, .listening, .wake] {
            XCTAssertEqual(PillRules.ending("sent", mode: mode), .done)
            XCTAssertEqual(PillRules.ending("queued", mode: mode), .done, "queued must not leave \(mode) up")
            XCTAssertEqual(PillRules.ending("not_sent", mode: mode), .idle)
            XCTAssertEqual(PillRules.ending("cancelled", mode: mode), .idle)
            XCTAssertEqual(PillRules.ending("error", mode: mode), .error)
        }
        // "Queued for orchard" already showing, or an error with its reason: left alone.
        XCTAssertEqual(PillRules.ending("queued", mode: .done), .keep)
        XCTAssertEqual(PillRules.ending("not_sent", mode: .error), .keep)
        XCTAssertEqual(PillRules.ending("sent", mode: .idle), .keep) // never pops up from idle
        XCTAssertEqual(PillRules.ending("answered", mode: .listening), .thinking)
    }

    func testClosedMicNeverLeavesListeningUp() {
        XCTAssertEqual(PillRules.micClosed(mode: .listening, shownFor: "mac", closed: "mac"), .thinking)
        XCTAssertEqual(PillRules.micClosed(mode: .wake, shownFor: "mac", closed: "mac"), .thinking)
        // The other mic closing does not end this one's turn.
        XCTAssertNil(PillRules.micClosed(mode: .listening, shownFor: "mac", closed: "iphone"))
        // Not listening: nothing to change.
        for m in [PillMode.idle, .thinking, .sending, .speaking, .done, .error] {
            XCTAssertNil(PillRules.micClosed(mode: m, shownFor: "mac", closed: "mac"))
        }
    }

    func testLevelsOnlyWhileAMicIsOpen() {
        XCTAssertTrue(PillRules.showsLevels(.listening, micOpen: true))
        XCTAssertFalse(PillRules.showsLevels(.listening, micOpen: false))
        XCTAssertFalse(PillRules.showsLevels(.thinking, micOpen: true))
    }
}
