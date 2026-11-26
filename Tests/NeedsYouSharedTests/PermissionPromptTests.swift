@testable import NeedsYouShared
import XCTest

final class PermissionPromptTests: XCTestCase {
    func testLimiterLetsEachPermissionThroughOncePerInterval() {
        var l = PromptLimiter(interval: 600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(l.allow("accessibility", now: t0))
        XCTAssertFalse(l.allow("accessibility", now: t0.addingTimeInterval(1)))
        XCTAssertFalse(l.allow("accessibility", now: t0.addingTimeInterval(599)))
        XCTAssertTrue(l.allow("microphone", now: t0.addingTimeInterval(2)))   // its own clock
        XCTAssertTrue(l.allow("accessibility", now: t0.addingTimeInterval(600)))
        XCTAssertFalse(l.allow("accessibility", now: t0.addingTimeInterval(700)))
    }

    func testAccessibilityAdvice() {
        XCTAssertEqual(AccessibilityAdvice.advice(trustedBuild: "aa", build: "aa"), .turnOn)
        XCTAssertEqual(AccessibilityAdvice.advice(trustedBuild: "aa", build: "bb"), .toggle)
        XCTAssertEqual(AccessibilityAdvice.advice(trustedBuild: nil, build: "bb"), .turnOnOrToggle)
        XCTAssertEqual(AccessibilityAdvice.advice(trustedBuild: "aa", build: nil), .turnOnOrToggle)
        XCTAssertTrue(AccessibilityAdvice.toggle.line.contains("off and on"))
    }
}
