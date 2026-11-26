@testable import NeedsYouShared
import XCTest

/// Layouts read from the real apps on 26 Nov 2026 (HM-1394).
final class ChatListFinderTests: XCTestCase {
    func labels(_ items: [AXItem]) -> [String] {
        ChatListFinder.chats(items, messageField: ChatListFinder.messageField(items)).map { items[$0].label }
    }

    func testClaudeAppPinnedAndRecentsNotNavOrHeaders() {
        let items = [AXItem(role: "AXButton", label: "Hide sidebar", depth: 15, x: 1752, y: 329, width: 28, height: 28),
            AXItem(role: "AXButton", label: "New", depth: 18, x: 1676, y: 370, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Search", depth: 18, x: 1676, y: 404, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Projects", depth: 19, x: 1676, y: 438, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Artifacts", depth: 19, x: 1676, y: 472, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Design", depth: 18, x: 1676, y: 540, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Plugins", depth: 18, x: 1676, y: 574, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Pinned", depth: 21, x: 1682, y: 628, width: 239, height: 28),
            AXItem(role: "AXButton", label: "Planning a birthday party", depth: 22, x: 1676, y: 660, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Houseplant watering schedule", depth: 22, x: 1676, y: 694, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Recents", depth: 21, x: 1682, y: 748, width: 211, height: 28),
            AXItem(role: "AXButton", label: "Learning to bake sourdough", depth: 22, x: 1676, y: 780, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Needs-you connection", depth: 22, x: 1676, y: 814, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Comparing bike rental prices", depth: 22, x: 1676, y: 1018, width: 249, height: 32),
            AXItem(role: "AXButton", label: "View all", depth: 19, x: 1676, y: 1460, width: 249, height: 32),
            AXItem(role: "AXButton", label: "Learning to bake sourdough, rename session", depth: 25, x: 1945, y: 329, width: 174, height: 28),
            AXItem(role: "AXButton", label: "Copy", depth: 30, x: 1993, y: 1318, width: 24, height: 25),
            AXItem(role: "AXTextArea", label: "Write your prompt to Claude", depth: 32, x: 1993, y: 1577, width: 710, height: 21)]
        XCTAssertTrue(ChatListFinder.isChatLayout(items))
        XCTAssertEqual(labels(items), ["Planning a birthday party", "Houseplant watering schedule", "Learning to bake sourdough", "Needs-you connection", "Comparing bike rental prices"])
    }

    func testChatGPTAppChatRows() {
        let items = [AXItem(role: "AXButton", label: "Home", depth: 18, x: 1566, y: 477, width: 36, height: 36),
            AXItem(role: "AXButton", label: "New chat", depth: 20, x: 1618, y: 518, width: 272, height: 30),
            AXItem(role: "AXButton", label: "Projects", depth: 22, x: 1622, y: 563, width: 243, height: 25),
            AXItem(role: "AXButton", label: "Recents", depth: 22, x: 1622, y: 643, width: 243, height: 25),
            AXItem(role: "AXButton", label: "Reply OK", depth: 27, x: 1618, y: 674, width: 261, height: 30),
            AXItem(role: "AXButton", label: "Pin chat", depth: 29, x: 1825, y: 679, width: 20, height: 20),
            AXItem(role: "AXButton", label: "Rename photo files", depth: 27, x: 1618, y: 705, width: 261, height: 30),
            AXItem(role: "AXButton", label: "Fix a squeaky door", depth: 27, x: 1618, y: 798, width: 261, height: 30),
            AXItem(role: "AXButton", label: "best pasta for lasagna?", depth: 27, x: 1618, y: 1263, width: 261, height: 30),
            AXItem(role: "AXButton", label: "Copy message", depth: 27, x: 2678, y: 603, width: 26, height: 26),
            AXItem(role: "AXButton", label: "Upgrade", depth: 16, x: 2640, y: 432, width: 103, height: 34),
            AXItem(role: "AXTextArea", label: "Ask ChatGPT", depth: 36, x: 2069, y: 1240, width: 538, height: 36)]
        XCTAssertEqual(labels(items), ["Reply OK", "Rename photo files", "Fix a squeaky door", "best pasta for lasagna?"])
        XCTAssertTrue(ChatListFinder.isChatLayout(items))
    }

    func testSearchAboveAListIsNotAChatApp() {
        let items = [
            AXItem(role: "AXTextField", label: "Search", depth: 8, x: 300, y: 60, width: 400, height: 28),
            AXItem(role: "AXRow", label: "GitHub", depth: 10, x: 300, y: 120, width: 400, height: 44),
            AXItem(role: "AXRow", label: "Google", depth: 10, x: 300, y: 164, width: 400, height: 44),
            AXItem(role: "AXRow", label: "Dropbox", depth: 10, x: 300, y: 208, width: 400, height: 44),
        ]
        XCTAssertFalse(ChatListFinder.isChatLayout(items))
    }

    func testNoColumnNoChats() {
        XCTAssertEqual(labels([AXItem(role: "AXButton", label: "OK", depth: 3, x: 0, y: 0, width: 200, height: 30)]), [])
    }

    func testChatTitle() {
        XCTAssertEqual(ChatListFinder.chatTitle("Learning to bake sourdough - Claude", appName: "Claude"), "Learning to bake sourdough")
        XCTAssertEqual(ChatListFinder.chatTitle("Reply OK", appName: "ChatGPT"), "Reply OK")
        XCTAssertNil(ChatListFinder.chatTitle("Claude", appName: "Claude"))
    }
}
