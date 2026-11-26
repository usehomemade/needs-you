import XCTest
@testable import NeedsYouShared

final class ChatTopicTests: XCTestCase {
    let chats: [ChatCandidate] = [
        .init(title: "Needs You voice router", folder: "needs-you", focused: true),
        .init(title: "orchard lint rules for the repo doctor", folder: "orchard"),
        .init(title: "orchard staging deploy", folder: "orchard"),
        .init(title: "ChatGPT", aliases: ["chatgpt"], isDesktop: true),
    ]

    func testTheChatOpenInTheClaudeAppCountsForTheTopic() {
        var app = ChatCandidate(title: "Claude app", isDesktop: true); app.detail = "Learning to bake sourdough"
        let chats = [ChatCandidate(title: "Font picker standalone app", folder: "font-picker"), app]
        XCTAssertEqual(ChatMatcher.topic("what did the agent say on learning to bake sourdough", chats), 1)
        XCTAssertNil(ChatMatcher.topic("what did the agent say on learning to bake sourdough", [chats[0], ChatCandidate(title: "Claude app", isDesktop: true)]))
    }

    func testTopicPicksTheChatTheWordsPointTo() {
        XCTAssertEqual(ChatMatcher.topic("how does the orchard linter going", chats), 1)
        XCTAssertEqual(ChatMatcher.topic("is the staging deploy done", chats), 2)
    }

    func testTopicTiesAndNothingGiveNil() {
        XCTAssertNil(ChatMatcher.topic("how is orchard going", chats)) // two orchard chats
        XCTAssertNil(ChatMatcher.topic("how are you doing", chats, minScore: 2)) // "you" alone is not a clear topic
    }

    /// 26 Nov: "request" is in several chats; the rare words pick the chat.
    func testSharedWordsCountLittle() {
        let chats: [ChatCandidate] = ["Spreadsheet formula request", "Printer setup request", "Meeting notes request", "Claude Code in your home folder"].map {
            var c = ChatCandidate(title: $0, aliases: [], isDesktop: true); c.detail = $0; return c
        }
        XCTAssertEqual(ChatMatcher.topic("what did the spreadsheet formula request say", chats), 0)
        XCTAssertEqual(ChatMatcher.topic("can you ask what the printer setup request said", chats, minScore: 2), 1)
        XCTAssertNil(ChatMatcher.topic("what did the request say", chats))
    }
}
