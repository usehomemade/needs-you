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

/// The model's reading, checked against his words and earlier picks (HM-1399).
final class IntentJudgeTests: XCTestCase {
    let chats: [ChatCandidate] = [
        .init(title: "Lisbon and Porto trip planner", label: "summer-trips"),
        .init(title: "Shop business plan", label: "bakery", focused: true),
        .init(title: "Reviving an old Game Boy", folder: "gameboy"),
        .init(title: "Space Llama Racer save file", folder: "gameboy"),
        .init(title: "Claude app", isDesktop: true),
    ]
    func send(_ i: VoiceIntent?, topic: Int? = nil, clear: Int? = nil, memory: Int? = nil) -> IntentJudge.Outcome {
        IntentJudge.decide(i, chats, topic: topic, clearTopic: clear, memory: memory, recent: [1, 0, 2], isProject: { $0 == "needs-you" }).0
    }

    func testNamedChatSends() {
        XCTAssertEqual(send(VoiceIntent(action: .send, chat: 0, named: "trip planner", message: "book it")), .send(0, byFocus: false))
    }
    func testNameForTwoChatsAsksModelPickFirst() {
        XCTAssertEqual(send(VoiceIntent(action: .send, chat: 3, named: "gameboy", message: "hi")), .ask([3, 2], heard: "gameboy"))
    }
    func testUnknownNameSaysSo() {
        XCTAssertEqual(send(VoiceIntent(action: .send, chat: 1, named: "banana", message: "hi")), .notFound("banana"))
    }
    func testUnknownNameThatIsAProjectStartsAChat() {
        XCTAssertEqual(send(VoiceIntent(action: .send, named: "needs-you", message: "look at the log")), .newChat(named: "needs-you"))
    }
    func testModelAloneAsks() {
        XCTAssertEqual(send(VoiceIntent(action: .send, chat: 3, message: "hi")), .ask([3, 1, 0, 2], heard: ""))
    }
    func testModelAndTopicAgreeSends() {
        XCTAssertEqual(send(VoiceIntent(action: .send, chat: 3, message: "hi"), topic: 3), .send(3, byFocus: false))
    }
    func testModelAndMemoryAgreeSends() {
        XCTAssertEqual(send(VoiceIntent(action: .send, chat: 0, message: "hi"), memory: 0), .send(0, byFocus: false))
    }
    func testNoChatButClearTopicSends() {
        XCTAssertEqual(send(VoiceIntent(action: .send, message: "hi"), topic: 2, clear: 2), .send(2, byFocus: false))
        XCTAssertEqual(send(VoiceIntent(action: .send, message: "hi"), topic: 2), .ask([1, 0, 2], heard: ""))
    }
    func testNothingPointsAnywhereAsksRecent() {
        XCTAssertEqual(send(VoiceIntent(action: .send, message: "hi")), .ask([1, 0, 2], heard: ""))
    }
    func testChatInFront() {
        XCTAssertEqual(send(VoiceIntent(action: .send, meansFront: true, message: "hi")), .send(1, byFocus: true))
    }
    func testUsedLastIsNeverAFallback() {
        if case .send = send(VoiceIntent(action: .send, chat: 1, message: "hi")) { XCTFail("sent to the chat in front without being asked") }
    }
    func testNoModelUsesOnlyData() {
        XCTAssertEqual(send(nil, topic: 0, clear: 0), .send(0, byFocus: false))
        XCTAssertEqual(send(nil), .ask([1, 0, 2], heard: ""))
    }
    func testOtherActions() {
        XCTAssertEqual(send(VoiceIntent(action: .back, summary: true)), .presence(.back, summary: true))
        XCTAssertEqual(send(VoiceIntent(action: .newChat, named: "ChatGPT", message: "weather")), .newChat(named: "ChatGPT"))
        XCTAssertEqual(send(VoiceIntent(action: .nothing)), .nothing)
    }
    func testOnlyHisOwnWordsName() {
        XCTAssertEqual(VoiceIntent.ownWords("Reviving an old Game Boy; folder: gameboy", in: "how is the game boy going"), "game boy")
        XCTAssertEqual(VoiceIntent.ownWords("how are you doing?", in: "how are you doing?"), "")
        XCTAssertEqual(VoiceIntent.ownWords("", in: "hi"), "")
    }
}
