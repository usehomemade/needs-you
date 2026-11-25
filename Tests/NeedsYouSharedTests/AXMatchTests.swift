import XCTest
@testable import NeedsYouShared

/// Which window or tab holds a chat (HM-1374), from what the AX proof saw on 25 Nov.
final class AXMatchTests: XCTestCase {
    let scratch = "/private/tmp/claude-501/x/scratchpad/hm1374"

    func testTerminalTabsByFolderInTitle() {
        let h = AXMatch.Hint(cwd: scratch + "/term-a")
        let places = [
            AXMatch.Place(title: scratch + "/term-a2 — axproof-term-a2 — cat"),
            AXMatch.Place(title: "~ — -zsh"),
            AXMatch.Place(title: scratch + "/term-a — axproof-term-a — cat"),
            AXMatch.Place(title: scratch + "/term-b — axproof-term-b — cat"),
        ]
        let s = places.map { AXMatch.score($0, h) }
        XCTAssertEqual(AXMatch.pick(s), 2, "term-a, not term-a2: \(s)")
    }

    func testDocumentURLAndTmpAlias() {
        let h = AXMatch.Hint(cwd: "/tmp/axtest/ghostty-a")
        let p = AXMatch.Place(title: "axproof", document: "file:///private/tmp/axtest/ghostty-a/")
        XCTAssertEqual(AXMatch.score(p, h).score, 3)
    }

    func testSameTitlesNeedScreenText() {
        // Ghostty with a fixed `title`: both tabs look the same; only the visible one has text.
        var h = AXMatch.Hint(cwd: "/Users/x")
        h.texts = ["Done. The deploy finished and staging is green again."]
        let a = AXMatch.Place(title: "axproof-ghostty-a", screen: "…\n⏺ Done. The deploy finished and staging is green again.\n> ")
        let b = AXMatch.Place(title: "axproof-ghostty-a")
        XCTAssertEqual(AXMatch.pick([a, b].map { AXMatch.score($0, h) }), 0)
        XCTAssertNil(AXMatch.pick([b, b].map { AXMatch.score($0, h) }), "two equal tabs: ask, don't guess")
    }

    func testWrappedScreenTextStillMatches() {
        let h = AXMatch.Hint(cwd: "", texts: ["The which-chat question now numbers the chats and waits before it listens."])
        let p = AXMatch.Place(title: "MBP: general", screen: "⏺ The which-chat question now numbers the chats and\n  waits before it listens.")
        XCTAssertGreaterThanOrEqual(AXMatch.score(p, h).score, 3)
    }

    func testHomeFolderNeverMatchesByFolder() {
        let h = AXMatch.Hint(cwd: NSHomeDirectory())
        let p = AXMatch.Place(title: "alex — -zsh", document: "")
        XCTAssertEqual(AXMatch.score(p, h).score, 0)
        XCTAssertNil(AXMatch.pick([AXMatch.score(p, h)]))
        XCTAssertEqual(AXMatch.pick([AXMatch.score(p, h)], alone: true), 0, "the only window of the owning app")
    }

    func testFolderWordOnly() {
        let h = AXMatch.Hint(cwd: "/Users/x/Projects/needs-you")
        XCTAssertEqual(AXMatch.score(AXMatch.Place(title: "AXDelivery.swift — needs-you"), h).score, 1.5)
        XCTAssertEqual(AXMatch.score(AXMatch.Place(title: "needs-you-old — Cursor"), h).score, 0)
    }

    func testCloseScoresAreNotPicked() {
        let s = [AXMatch.Scored(score: 3, why: []), AXMatch.Scored(score: 2.5, why: [])]
        XCTAssertNil(AXMatch.pick(s))
    }
}
