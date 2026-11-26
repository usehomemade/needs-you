import XCTest
@testable import NeedsYouShared

/// HM-1412: a chat idle at its prompt gets voice messages typed in; only one mid-turn queues.
final class ChatStateTests: XCTestCase {
    private func update(_ event: String, subtype: String? = nil) -> ChatUpdate {
        var u = ChatUpdate(event: event, agent: "claude", agentPid: 7); u.notificationType = subtype; return u
    }
    private func chat(_ events: [ChatUpdate]) -> ChatInfo {
        var c = ChatInfo(id: "pid:7", agent: "claude", agentPid: 7, cwd: "/tmp/demo-app")
        for u in events { c.apply(u) }
        return c
    }

    func testIdleReminderAfterStopKeepsChatIdle() {
        let c = chat([update("UserPromptSubmit"), update("Stop"), update("Notification", subtype: "idle_prompt")])
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(ChatInfo.typing(c.state), .typeNow)
    }

    func testOlderHookWithoutTypeAfterStopStaysIdle() {
        XCTAssertEqual(chat([update("Stop"), update("Notification")]).state, .idle)
        XCTAssertEqual(chat([update("UserPromptSubmit"), update("Notification")]).state, .waiting)
    }

    func testDialogsAreWaitingAndNeverTyped() {
        for sub in ["permission_prompt", "elicitation_dialog"] {
            let c = chat([update("Stop"), update("Notification", subtype: sub)])
            XCTAssertEqual(c.state, .waiting, sub)
            if case .typeNow = ChatInfo.typing(c.state) { XCTFail(sub) }
        }
        XCTAssertEqual(chat([update("Stop"), update("Notification", subtype: "auth_success")]).state, .idle)
    }

    func testOwnToolCallMeansWorkingAgain() {
        let c = chat([update("UserPromptSubmit"), update("Notification", subtype: "permission_prompt"), update("PostToolUse")])
        XCTAssertEqual(c.state, .working)
        if case .typeNow = ChatInfo.typing(c.state) { XCTFail() }
    }

    func testOnlyIdleTypes() {
        XCTAssertEqual(ChatInfo.typing(.idle), .typeNow)
        for s in [ChatInfo.State.working, .waiting, .unknown] {
            if case .typeNow = ChatInfo.typing(s) { XCTFail(s.rawValue) }
        }
    }

    func testStopHandsQueuedMessagesOverAsTheNextPrompt() {
        XCTAssertTrue(HookSetup.delivers("Stop"))
        let out = HookSetup.output(event: "Stop", messages: ["one", "two"], agent: "claude")
        XCTAssertEqual(out?["decision"] as? String, "block")
        XCTAssertEqual(out?["reason"] as? String, "one\n\ntwo")
    }
}
