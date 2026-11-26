@testable import NeedsYouShared
import XCTest

final class EscapeKeysTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testOnceClosesTwiceResets() {
        var k = EscapeKeys()
        XCTAssertEqual(k.press(at: t0), .close)
        XCTAssertEqual(k.press(at: t0 + 0.3), .reset)
        // A third press starts over: a new close.
        XCTAssertEqual(k.press(at: t0 + 0.5), .close)
    }

    func testSlowPressesAreTwoCloses() {
        var k = EscapeKeys()
        XCTAssertEqual(k.press(at: t0), .close)
        XCTAssertEqual(k.press(at: t0 + 0.6), .close)
        XCTAssertEqual(k.press(at: t0 + 1.4), .close)
    }

    func testCloseIsFinalOnlyAfterTheWindow() {
        var k = EscapeKeys()
        _ = k.press(at: t0)
        XCTAssertNil(k.outcome(of: t0, at: t0 + 0.2))
        XCTAssertEqual(k.outcome(of: t0, at: t0 + 0.5), .close)
        XCTAssertEqual(k.outcome(of: t0, at: t0 + 5), .close)
    }

    func testResetWinsOverTheClose() {
        var k = EscapeKeys()
        _ = k.press(at: t0)
        _ = k.press(at: t0 + 0.4)
        XCTAssertEqual(k.outcome(of: t0, at: t0 + 0.41), .reset)
        XCTAssertEqual(k.outcome(of: t0, at: t0 + 10), .reset)
    }

    func testAnOldResetDoesNotUndoANewClose() {
        var k = EscapeKeys()
        _ = k.press(at: t0)
        _ = k.press(at: t0 + 0.2) // reset
        _ = k.press(at: t0 + 3)   // close
        XCTAssertEqual(k.outcome(of: t0 + 3, at: t0 + 3.6), .close)
    }
}
