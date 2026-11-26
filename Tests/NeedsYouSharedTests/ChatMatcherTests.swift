import XCTest
@testable import NeedsYouShared

/// Routing cases from real use on 25 Nov (HM-1364), chat titles changed.
final class ChatMatcherTests: XCTestCase {
    // herdr agent list + tab list, 25 Nov 13:00. The chat in front is "bakery".
    let chats: [ChatCandidate] = [
        .init(title: "Lisbon and Porto trip planner", label: "summer-trips"),
        .init(title: "Shop business plan", label: "bakery", focused: true),
        .init(title: "Turkish and German voice replies", label: "voice"),
        .init(title: "Agent communication and app publishing", label: "voice"),
        .init(title: "Inbox cleanup, photo backup, notes audit", label: "notes-app reread all notes", folder: "notesapp"),
        .init(title: "Claude Code in recipebox", label: "continue", folder: "recipebox"),
        .init(title: "Font picker standalone app", label: "1", folder: "font-picker"),
        .init(title: "Podcast stats dashboard", label: "1", folder: "podcast-stats"),
        .init(title: "Reviving an old Game Boy", label: "1", folder: "gameboy"),
        .init(title: "Space Llama Racer save file", label: "install", folder: "gameboy"),
        .init(title: "Garden planner cards and photos", label: "1", folder: "garden"),
    ]
    let bakery = 1


    func testJunkAndDuplicateLabelsAreNotNames() {
        let labels = ChatMatcher.usableLabels(chats)
        XCTAssertEqual(labels[2], "")   // "voice", twice
        XCTAssertEqual(labels[6], "")   // "1"
        XCTAssertEqual(labels[9], "install")
        // "voice: needs-you" (a chat Needs You started) names needs-you.
        XCTAssertEqual(ChatMatcher.usableLabels([.init(title: "x", label: "voice: needs-you")]), ["needs-you"])
        // "voice" alone no longer picks one of the two voice tabs by label.
        let ranked = ChatMatcher.rank("voice", chats)
        XCTAssertEqual(ranked.first?.field, "title")
    }

    /// Words most chats share do not pick a chat; the rare ones do (HM-1399).
    func testRankWeighsRareWords() {
        let cs: [ChatCandidate] = [.init(title: "Claude Code in your home folder"), .init(title: "Claude Code: needs-you"), .init(title: "Claude Code: trip planner")]
        let r = ChatMatcher.rank("claude code needs you", cs)
        XCTAssertEqual(r.first?.index, 1)
        XCTAssertGreaterThan(r[0].score - r[1].score, 0.2)
    }
}
