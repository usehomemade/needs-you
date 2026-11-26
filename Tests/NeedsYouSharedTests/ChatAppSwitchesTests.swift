import XCTest
@testable import NeedsYouShared

final class ChatAppSwitchesTests: XCTestCase {
    typealias App = ChatAppSwitches.App
    let term = App(id: "com.example.term", name: "Example Term", kind: .host)
    let chat = App(id: "com.example.chat", name: "Example Chat", kind: .chatApp)

    func testPaneOwnsTheChatBeforeItsHostApp() {
        XCTAssertEqual(ChatAppSwitches.owner(pane: .herdr, host: term)?.id, "herdr")
        XCTAssertEqual(ChatAppSwitches.owner(pane: .tmux, host: nil)?.id, "tmux")
        XCTAssertEqual(ChatAppSwitches.owner(pane: nil, host: term), term)
        XCTAssertNil(ChatAppSwitches.owner(pane: nil, host: nil))
    }

    func testDisabledAppsAreBlockedUnknownOnesAreNot() {
        let off: Set<String> = ["com.example.chat", "herdr"]
        XCTAssertFalse(ChatAppSwitches.allows("com.example.chat", disabled: off))
        XCTAssertFalse(ChatAppSwitches.allows("herdr", disabled: off))
        XCTAssertTrue(ChatAppSwitches.allows("com.example.term", disabled: off))
        XCTAssertTrue(ChatAppSwitches.allows(nil, disabled: off))
        XCTAssertTrue(ChatAppSwitches.allows("com.example.chat", disabled: []))
    }

    func testListKeepsEachAppOnceMuxFirstThenHostsThenChatApps() {
        let alsoHost = App(id: "com.example.chat", name: "Example Chat", kind: .host)
        let list = ChatAppSwitches.list([chat, term, ChatAppSwitches.mux(.tmux), alsoHost, ChatAppSwitches.mux(.herdr), App(id: "x", name: "", kind: .host)])
        XCTAssertEqual(list.map(\.id), ["herdr", "tmux", "com.example.chat", "com.example.term"])
        XCTAssertEqual(list[2].kind, .host) // seen as the app a chat runs in: listed there, once
    }
}
