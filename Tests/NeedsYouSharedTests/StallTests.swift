import XCTest
@testable import NeedsYouShared

final class StallWatchTests: XCTestCase {
    func testQuietMainThreadReportsNothing() {
        var w = StallWatch()
        for t in [0, 0.4, 1.2, 1.9, 0] { XCTAssertNil(w.check(waited: t)) }
    }

    func testReportsEachThresholdOnceThenRecovery() {
        var w = StallWatch(thresholds: [2, 10])
        XCTAssertNil(w.check(waited: 1))
        XCTAssertEqual(w.check(waited: 2.1), .blocked(seconds: 2.1, report: 1))
        XCTAssertNil(w.check(waited: 2.6))
        XCTAssertNil(w.check(waited: 9.5))
        XCTAssertEqual(w.check(waited: 10.2), .blocked(seconds: 10.2, report: 2))
        XCTAssertNil(w.check(waited: 11))
        XCTAssertEqual(w.check(waited: 0), .recovered(seconds: 11))
        XCTAssertNil(w.check(waited: 0))
    }

    func testStuckForeverKeepsLeavingATrail() {
        var w = StallWatch(thresholds: [2, 10])
        var reports: [Int] = []
        var t = 0.0
        while t < 41 {
            if case .blocked(_, let n)? = w.check(waited: t) { reports.append(n) }
            t += 0.5
        }
        // 2 s, 10 s, then every 10 s more: 20, 30, 40.
        XCTAssertEqual(reports, [1, 2, 3, 4, 5])
    }

    func testAShortStallIsForgotten() {
        var w = StallWatch(thresholds: [2])
        XCTAssertNotNil(w.check(waited: 3))
        XCTAssertEqual(w.check(waited: 0.1), .recovered(seconds: 3))
        XCTAssertEqual(w.check(waited: 2.5), .blocked(seconds: 2.5, report: 1))
    }
}

final class WalkBudgetTests: XCTestCase {
    func testStopsAtTheElementCount() {
        var b = WalkBudget(nodes: 3, seconds: 10, now: 0)
        XCTAssertTrue(b.take(now: 0)); XCTAssertTrue(b.take(now: 0)); XCTAssertTrue(b.take(now: 0))
        XCTAssertFalse(b.take(now: 0))
        XCTAssertFalse(b.timedOut)
    }

    func testStopsAtTheDeadlineAndStaysStopped() {
        var b = WalkBudget(nodes: 5000, seconds: 2, now: 100)
        XCTAssertTrue(b.take(now: 101))
        XCTAssertFalse(b.take(now: 102))
        XCTAssertTrue(b.timedOut)
        XCTAssertFalse(b.take(now: 101)) // a hung app: no more reads, even if the clock says otherwise
    }

    func testNextWindowKeepsTheDeadline() {
        var b = WalkBudget(nodes: 1, seconds: 2, now: 0)
        XCTAssertTrue(b.take(now: 0))
        var n = b.next(nodes: 10)
        XCTAssertTrue(n.take(now: 1))
        XCTAssertFalse(n.take(now: 2.5))
        XCTAssertTrue(n.timedOut)
    }
}
