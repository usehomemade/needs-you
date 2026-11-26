import XCTest
@testable import NeedsYouShared

/// Spoken commands for chat apps (HM-1383), as the owner said them on 26 Nov.
final class AppCommandTests: XCTestCase {
    let apps = [["claude desktop", "claude app", "claude for desktop", "desktop"], ["chatgpt", "chat gpt", "codex app"]]

    func m(_ s: String) -> AppCommand.Match? { AppCommand.parse(s, apps: apps) }

    func testNewChatOnClaudeDesktop() {
        XCTAssertEqual(m("create new chat on claude desktop, ask whats the weather like"), .init(app: 0, message: "whats the weather like"))
        XCTAssertEqual(m("Create a new chat in the Claude app and ask what's the weather like."), .init(app: 0, message: "what's the weather like."))
        XCTAssertEqual(m("new chat on ChatGPT: plan my week"), .init(app: 1, message: "plan my week"))
    }

    func testUseAppToAsk() {
        XCTAssertEqual(m("use chatgpt to ask how my business doing"), .init(app: 1, message: "how my business doing"))
        XCTAssertEqual(m("Use ChatGPT to ask how my business is doing."), .init(app: 1, message: "how my business is doing."))
        XCTAssertEqual(m("ask chat GPT whether it will rain"), .init(app: 1, message: "whether it will rain"))
        XCTAssertEqual(m("open ChatGPT and start a new chat, tell it to summarize my inbox"), .init(app: 1, message: "summarize my inbox"))
        XCTAssertEqual(m("could you open the Claude app, new chat: hi"), .init(app: 0, message: "hi"))
        XCTAssertEqual(m("start a ChatGPT conversation about my weekend plans"), .init(app: 1, message: "about my weekend plans"))
    }

    func testNotAnAppCommand() {
        XCTAssertNil(m("how is the orchard linter going"))
        XCTAssertNil(m("ChatGPT: what's up"))           // name and colon: the open chat (ChatMatcher)
        XCTAssertNil(m("open desktop and clean it up")) // the Finder's desktop
        XCTAssertNil(m("new chat in orchard: look at the deploy"))
        XCTAssertNil(m("tell the team we use chatgpt"))
    }
}

/// 26 Nov 10:00: "send a text message to Game Boy terminal, say hi to Claude" went to the chat in front.
final class ToChatTests: XCTestCase {
    let chats: [ChatCandidate] = [
        .init(title: "Portuguese bakery business plan", focused: true),
        .init(title: "Reviving an old Game Boy", label: "1", folder: "gameboy"),
        .init(title: "Space Llama Racer save file", label: "install", folder: "gameboy"),
        .init(title: "Font picker standalone app", folder: "font-picker"),
    ]

    func testNamedAsATerminalAsksBetweenTheTwoGameBoyChats() {
        let (r, _) = ChatMatcher.route("send a text message to Game Boy terminal, say hi to Claude.", chats)
        guard case .choose(let idx, let m, let heard) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(Set(idx.prefix(2)), [1, 2]); XCTAssertEqual(m, "say hi to Claude."); XCTAssertEqual(heard, "Game Boy")
    }

    func testNamedAsATerminalSends() {
        XCTAssertEqual(ChatMatcher.route("tell the font picker chat to run the build", chats).0, .named(3, "to run the build"))
    }

    func testUnknownNameAsksInsteadOfTheChatInFront() {
        guard case .choose = ChatMatcher.route("send a message to the recipebox terminal: hi", chats).0 else { return XCTFail() }
    }
}

final class AppTopicTests: XCTestCase {
    func testTheChatOpenInTheClaudeAppCountsForTheTopic() {
        var app = ChatCandidate(title: "Claude app", isDesktop: true); app.detail = "Learning to bake sourdough"
        let chats = [ChatCandidate(title: "Font picker standalone app", folder: "font-picker"), app]
        XCTAssertEqual(ChatMatcher.topic("what did the agent say on learning to bake sourdough", chats), 1)
        XCTAssertNil(ChatMatcher.topic("what did the agent say on learning to bake sourdough", [chats[0], ChatCandidate(title: "Claude app", isDesktop: true)]))
    }
}

final class TopicTests: XCTestCase {
    let chats: [ChatCandidate] = [
        .init(title: "Needs You voice router", folder: "needs-you", focused: true),
        .init(title: "orchard lint rules for the repo doctor", folder: "orchard"),
        .init(title: "orchard staging deploy", folder: "orchard"),
        .init(title: "ChatGPT", aliases: ["chatgpt"], isDesktop: true),
    ]

    func testTopicPicksTheChatTheWordsPointTo() {
        XCTAssertEqual(ChatMatcher.topic("how does the orchard linter going", chats), 1)
        XCTAssertEqual(ChatMatcher.topic("is the staging deploy done", chats), 2)
    }

    func testTopicTiesAndNothingGiveNil() {
        XCTAssertNil(ChatMatcher.topic("how is orchard going", chats)) // two orchard chats
        XCTAssertNil(ChatMatcher.topic("how are you doing", chats))
    }

    func testClearTopicSendsWithoutAsking() {
        // "ask orchard lint how it's doing": one chat clearly matches.
        if case .named(1, _) = RouteJudge.decide(.front(0, "x"), model: nil, topic: ChatMatcher.topic("ask orchard lint how its doing", chats)).0 {} else { XCTFail() }
    }

    func testModelAndTopicAgreeSends() {
        if case .named(1, _) = RouteJudge.decide(.front(0, "hi"), model: 1, topic: 1).0 {} else { XCTFail() }
        guard case .choose = RouteJudge.decide(.front(0, "hi"), model: 1, topic: 2).0 else { return XCTFail() }
    }
}
