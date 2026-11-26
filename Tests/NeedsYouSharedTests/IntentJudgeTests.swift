import XCTest
@testable import NeedsYouShared

/// The model's reading, checked against meaning, learned matches and his words (HM-1399, HM-1408).
final class IntentJudgeTests: XCTestCase {
    let chats: [ChatCandidate] = [
        .init(title: "Lisbon and Porto trip planner", label: "summer-trips"),
        .init(title: "Shop business plan", label: "bakery", focused: true),
        .init(title: "Reviving an old Game Boy", folder: "gameboy"),
        .init(title: "Space Llama Racer save file", folder: "gameboy"),
        .init(title: "Claude app", isDesktop: true),
    ]
    static func scores(_ s: [(Int, Double)]) -> [Meaning.Score] { s.map { Meaning.Score(index: $0.0, sim: $0.1) } }
    /// Meaning with chat 2 clearly first, and with no lead at all.
    let clearMeaning = scores([(2, 0.55), (0, 0.38), (1, 0.30)])
    let leadMeaning = scores([(2, 0.40), (0, 0.35), (1, 0.30)])
    let flatMeaning = scores([(0, 0.40), (3, 0.39), (2, 0.38), (1, 0.30)])

    func decide(_ i: VoiceIntent?, topic: Int? = nil, clear: Int? = nil, meaning: [Meaning.Score] = [], learned: [RouteEvidence.Learned] = []) -> IntentJudge.Outcome {
        IntentJudge.decide(i, chats, RouteEvidence(topic: topic, clearTopic: clear, meaning: meaning, learned: learned, recent: [1, 0, 2]),
                           isProject: { $0 == "needs-you" }).0
    }

    func testNamedChatSends() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, chat: 0, named: "trip planner", message: "book it")), .send(0, byFocus: false))
    }
    func testNameForTwoChatsAsksModelPickFirst() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, chat: 3, named: "gameboy", message: "hi")), .ask([3, 2], heard: "gameboy"))
    }
    func testUnknownNameSaysSo() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, chat: 1, named: "banana", message: "hi")), .notFound("banana"))
    }
    func testUnknownNameThatIsAProjectStartsAChat() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, named: "needs-you", message: "look at the log")), .newChat(named: "needs-you"))
    }
    func testModelAloneAsksClosestByMeaningFirst() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, chat: 3, message: "hi"), meaning: flatMeaning), .ask([0, 3, 2, 1], heard: ""))
        XCTAssertEqual(decide(VoiceIntent(action: .send, chat: 3, message: "hi")), .ask([3, 1, 0, 2], heard: ""))
    }
    func testModelAndMeaningAgreeSends() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, chat: 2, message: "hi"), meaning: leadMeaning), .send(2, byFocus: false))
    }
    func testModelAndMeaningDisagreeAsks() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, chat: 0, message: "hi"), meaning: clearMeaning), .ask([2, 0, 1], heard: ""))
    }
    func testModelAndLearnedAgreeSends() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, chat: 0, message: "hi"), learned: [.init(index: 0, weight: 0.5)]), .send(0, byFocus: false))
    }
    func testModelAndTopicAgreeSends() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, chat: 3, message: "hi"), topic: 3), .send(3, byFocus: false))
    }
    func testVeryClearMeaningSendsWhenModelHasNoPick() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, message: "hi"), meaning: clearMeaning), .send(2, byFocus: false))
        // A lead that is not very clear asks, closest first.
        XCTAssertEqual(decide(VoiceIntent(action: .send, message: "hi"), meaning: leadMeaning), .ask([2, 0, 1], heard: ""))
    }
    func testVeryClearMeaningDoesNotSendAgainstLearnedVotes() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, message: "hi"), meaning: clearMeaning, learned: [.init(index: 0, weight: 0.5)]),
                       .ask([2, 0, 1], heard: ""))
    }
    func testMeaningAndLearnedTogetherSend() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, message: "hi"), meaning: leadMeaning, learned: [.init(index: 2, weight: 0.3)]), .send(2, byFocus: false))
    }
    func testVeryClearLearnedSends() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, message: "hi"), learned: [.init(index: 3, weight: 1.2), .init(index: 0, weight: 0.2)]), .send(3, byFocus: false))
        // Two chats with similar votes: no lead.
        XCTAssertEqual(decide(VoiceIntent(action: .send, message: "hi"), learned: [.init(index: 3, weight: 1.2), .init(index: 0, weight: 0.9)]), .ask([1, 0, 2], heard: ""))
    }
    func testClearTopicSendsUnlessMeaningPointsElsewhere() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, message: "hi"), topic: 2, clear: 2), .send(2, byFocus: false))
        XCTAssertEqual(decide(VoiceIntent(action: .send, message: "hi"), topic: 0, clear: 0, meaning: leadMeaning), .ask([2, 0, 1], heard: ""))
        XCTAssertEqual(decide(VoiceIntent(action: .send, message: "hi"), topic: 2), .ask([2, 1, 0], heard: ""))
    }
    func testNothingPointsAnywhereAsksRecent() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, message: "hi")), .ask([1, 0, 2], heard: ""))
    }
    func testChatInFront() {
        XCTAssertEqual(decide(VoiceIntent(action: .send, meansFront: true, message: "hi")), .send(1, byFocus: true))
    }
    func testUsedLastIsNeverAFallback() {
        if case .send = decide(VoiceIntent(action: .send, chat: 1, message: "hi")) { XCTFail("sent to the chat in front without being asked") }
    }
    func testNoModelUsesOnlyData() {
        XCTAssertEqual(decide(nil, topic: 0, clear: 0), .send(0, byFocus: false))
        XCTAssertEqual(decide(nil, meaning: clearMeaning), .send(2, byFocus: false))
        XCTAssertEqual(decide(nil), .ask([1, 0, 2], heard: ""))
    }
    func testOtherActions() {
        XCTAssertEqual(decide(VoiceIntent(action: .back, summary: true)), .presence(.back, summary: true, time: AwayTime()))
        XCTAssertEqual(decide(VoiceIntent(action: .newChat, named: "ChatGPT", message: "weather")), .newChat(named: "ChatGPT"))
        XCTAssertEqual(decide(VoiceIntent(action: .nothing)), .nothing)
    }
}

/// A name the model hands back counts only when he said it, word for word (HM-1408).
final class SpokenNameTests: XCTestCase {
    func testContiguousPhraseCounts() {
        XCTAssertEqual(VoiceIntent.spokenName("Game Boy", in: "how is the game boy going"), "game boy")
        XCTAssertEqual(VoiceIntent.spokenName("banana", in: "send it to the Banana chat"), "banana")
        XCTAssertEqual(VoiceIntent.spokenName("summer-trips", in: "summer trips: book the hotel"), "summer trips")
    }
    func testWordsFromTheChatListDoNotCount() {
        // The model copied a chat's line from the list: none of it is a name he said.
        XCTAssertEqual(VoiceIntent.spokenName("Claude; working on: garden sketches; a chat app",
                                              in: "when you ask me which chat and I tell you another chat, it needs to be a conversation"), "")
        XCTAssertEqual(VoiceIntent.spokenName("Reviving an old Game Boy", in: "how is the game boy going"), "")
        // Words he said, but not together: no salvaging.
        XCTAssertEqual(VoiceIntent.spokenName("boy game", in: "how is the game boy going"), "")
    }
    func testHisWholeSentenceIsNoName() {
        XCTAssertEqual(VoiceIntent.spokenName("how are you doing?", in: "how are you doing?"), "")
        XCTAssertEqual(VoiceIntent.spokenName("", in: "hi"), "")
    }
}
