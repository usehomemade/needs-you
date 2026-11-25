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

    // 25 Nov 12:07 and 11:45: opened new chats in the home folder.
    func testUnmatchedColonPhraseGoesToChatInFront() {
        let rest = "two questions: first, how do I communicate with different agents?"
        let (route, log) = ChatMatcher.route(rest, chats)
        XCTAssertEqual(route, .front(bakery, rest))
        XCTAssertTrue(log.contains("no such chat"), log)

        let rest2 = "one more thing: Can you try to speak Turkish and German so I hear your voice in Turkish and German?"
        XCTAssertEqual(ChatMatcher.route(rest2, chats).0, .front(bakery, rest2))
    }

    func testUnmatchedColonPhraseThatIsAProjectStartsAChatThere() {
        let (route, _) = ChatMatcher.route("needs-you: look at the wake log", chats, isProject: { $0 == "needs-you" })
        XCTAssertEqual(route, .newChat("needs-you", " look at the wake log"))
    }

    // 25 Nov 11:52: named, matched right, then refused because focus moved.
    func testNamedChatInFrontIsNamedNotThisOne() {
        let (route, log) = ChatMatcher.route("Bakery. It asked me if I want to use the dark theme from the old app", chats)
        XCTAssertEqual(route, .named(bakery, " It asked me if I want to use the dark theme from the old app"))
        XCTAssertTrue(log.contains("(label)"), log)
    }

    func testThisOneAndNoNameGoToChatInFront() {
        XCTAssertEqual(ChatMatcher.route("this one: run the tests", chats).0, .front(bakery, "run the tests"))
        XCTAssertEqual(ChatMatcher.route("also do we support, let's say, Codex", chats).0, .front(bakery, "also do we support, let's say, Codex"))
    }

    func testTabLabelBeatsTitle() {
        var cs = chats
        cs.append(.init(title: "Bakery deploy checks", label: "1", folder: ""))
        let (route, _) = ChatMatcher.route("bakery: check the deploy", cs)
        XCTAssertEqual(route, .named(bakery, " check the deploy"))
    }

    func testTripPlannerByTitleAndByLabel() {
        XCTAssertEqual(ChatMatcher.route("trip planner: book the hotel", chats).0, .named(0, " book the hotel"))
        XCTAssertEqual(ChatMatcher.route("summer trips: book the hotel", chats).0, .named(0, " book the hotel"))
    }

    func testJunkAndDuplicateLabelsAreNotNames() {
        let labels = ChatMatcher.usableLabels(chats)
        XCTAssertEqual(labels[2], "")   // "voice", twice
        XCTAssertEqual(labels[5], "")   // "continue"
        XCTAssertEqual(labels[6], "")   // "1"
        XCTAssertEqual(labels[9], "install")
        // "voice: needs-you" (a chat Needs You started) names needs-you.
        XCTAssertEqual(ChatMatcher.usableLabels([.init(title: "x", label: "voice: needs-you")]), ["needs-you"])
        // "voice" alone no longer picks one of the two voice tabs by label.
        let ranked = ChatMatcher.rank("voice", chats)
        XCTAssertEqual(ranked.first?.field, "title")
    }

    func testTwoChatsInOneFolderAsk() {
        let (route, _) = ChatMatcher.route("gameboy: is the install done", chats)
        guard case .choose(let options, _, let heard) = route else { return XCTFail("\(route)") }
        XCTAssertEqual(Set(options.prefix(2)), [8, 9])
        XCTAssertEqual(heard, "gameboy")
    }

    func testFolderMatch() {
        XCTAssertEqual(ChatMatcher.route("recipebox: run the tests", chats).0, .named(5, " run the tests"))
    }

    func testNewChat() {
        XCTAssertEqual(ChatMatcher.route("new chat in orchard: look at the failing deploy", chats).0,
                       .newChat("orchard", "look at the failing deploy"))
    }

    func testDesktopInFrontIsThisOne() {
        var cs = chats
        cs.append(.init(title: "Claude desktop app", aliases: ["desktop", "claude app", "app"], focused: true, isDesktop: true))
        XCTAssertEqual(ChatMatcher.route("this one: hi", cs).0, .front(cs.count - 1, "hi"))
    }
}

final class RouteJudgeTests: XCTestCase {
    func testNamedStays() {
        if case .named(2, _) = RouteJudge.decide(.named(2, "hi"), model: 0).0 {} else { XCTFail() }
    }
    func testFrontAgreementSends() {
        if case .front(1, _) = RouteJudge.decide(.front(1, "hi"), model: 1).0 {} else { XCTFail() }
    }
    func testFrontDisagreementAsksModelFirst() {
        guard case .choose(let idx, _, _) = RouteJudge.decide(.front(1, "hi"), model: 3).0 else { return XCTFail() }
        XCTAssertEqual(idx, [3, 1])
    }
    func testThisOneIgnoresModel() {
        if case .front(1, _) = RouteJudge.decide(.front(1, "hi"), model: 3, explicitFront: true).0 {} else { XCTFail() }
    }
    func testChooseAgreesWithTopSends() {
        if case .named(2, _) = RouteJudge.decide(.choose([2, 0], "hi", heardName: "home"), model: 2).0 {} else { XCTFail() }
    }
    func testMemoryConfirmsModel() {
        if case .named(0, _) = RouteJudge.decide(.choose([2, 0], "hi", heardName: "home"), model: 0, memory: 0).0 {} else { XCTFail() }
        if case .named(3, _) = RouteJudge.decide(.front(1, "hi"), model: 3, memory: 3).0 {} else { XCTFail() }
    }
    func testNoModelNoMemoryUnchanged() {
        if case .choose([2, 0], _, _) = RouteJudge.decide(.choose([2, 0], "hi", heardName: "x"), model: nil).0 {} else { XCTFail() }
    }
}
