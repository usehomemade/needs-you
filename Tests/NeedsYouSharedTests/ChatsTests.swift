import XCTest
@testable import NeedsYouShared

final class ChatsTests: XCTestCase {
    func testPaneFromEnv() {
        XCTAssertEqual(PaneRef.from(env: ["HERDR_PANE_ID": "w2:p13", "TMUX_PANE": "%3"]), PaneRef(kind: .herdr, id: "w2:p13"))
        XCTAssertEqual(PaneRef.from(env: ["TMUX_PANE": "%3", "TMUX": "/private/tmp/tmux-501/default,123,0"]),
                       PaneRef(kind: .tmux, id: "%3", socket: "/private/tmp/tmux-501/default"))
        XCTAssertNil(PaneRef.from(env: [:]))
    }

    func testApplyTracksStateAndPrompts() {
        var c = ChatInfo(id: "pid:1", agent: "claude", agentPid: 1, cwd: "/x/needs-you")
        var u = ChatUpdate(event: "mcp", agent: "claude", agentPid: 1)
        c.apply(u)
        XCTAssertTrue(c.hasMCP); XCTAssertFalse(c.hasHooks)
        for i in 1...4 {
            u = ChatUpdate(event: "UserPromptSubmit", agent: "claude", agentPid: 1); u.prompt = "p\(i)"
            c.apply(u)
        }
        XCTAssertEqual(c.prompts, ["p2", "p3", "p4"])
        XCTAssertEqual(c.state, .working)
        XCTAssertTrue(c.hasHooks)
        XCTAssertNotNil(c.lastPromptAt)
        u = ChatUpdate(event: "status", agent: "claude", agentPid: 1); u.status = "island sounds"
        c.apply(u)
        u = ChatUpdate(event: "Stop", agent: "claude", agentPid: 1); u.reply = "done"
        c.apply(u)
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(c.folder, "needs-you")
        XCTAssertEqual(c.summary, "island sounds; last asked: p4")
    }

    func testHomeFolderHasNoFolderName() {
        let c = ChatInfo(id: "pid:1", agent: "claude", agentPid: 1, cwd: NSHomeDirectory())
        XCTAssertEqual(c.folder, "")
    }

    func testAgentProcessFindsAncestor() {
        let a = AgentProcess.agent(from: getpid())
        XCTAssertEqual(a.pid, getpid()) // the test runner is not a shell
        XCTAssertTrue(AgentProcess.alive(getpid()))
        XCTAssertEqual(AgentProcess.kind(comm: "claude"), "claude")
        XCTAssertEqual(AgentProcess.kind(comm: "node", hint: "gemini"), "gemini")
    }

    func testCodexBlockAddReplaceRemove() {
        let base = "model = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"
        let one = AgentSetup.withBlock(base, block: AgentSetup.codexBlock(cli: "/u/needs-you"))
        XCTAssertTrue(one.hasPrefix(base))
        XCTAssertTrue(one.contains("[mcp_servers.needs-you]\ncommand = \"/u/needs-you\""))
        let two = AgentSetup.withBlock(one, block: AgentSetup.codexBlock(cli: "/v/needs-you"))
        XCTAssertEqual(two.components(separatedBy: AgentSetup.begin).count, 2)
        XCTAssertTrue(two.contains("/v/needs-you"))
        XCTAssertEqual(AgentSetup.without(two), base + "\n")
        XCTAssertFalse(AgentSetup.hasBlock(AgentSetup.without(two)))
    }
}

final class HookSetupTests: XCTestCase {
    let existing: [String: Any] = ["model": "x", "hooks": [
        "SessionStart": [["matcher": "startup", "hooks": [["type": "command", "command": "bash herdr.sh session"]]]],
        "Notification": [["hooks": [["type": "command", "command": "python3 voice-notify.py"]]]],
    ]]

    func testInstallKeepsOtherHooksAndRemoveRestores() throws {
        let on = HookSetup.install(existing, cli: "/u/needs-you", agent: "claude", events: HookSetup.claudeEvents)
        XCTAssertTrue(HookSetup.isInstalled(on))
        let hooks = on["hooks"] as! [String: Any]
        XCTAssertEqual((hooks["SessionStart"] as! [[String: Any]]).count, 2)
        XCTAssertEqual((hooks["Stop"] as! [[String: Any]]).count, 1)
        // Installing twice does not duplicate.
        let twice = HookSetup.install(on, cli: "/u/needs-you", agent: "claude", events: HookSetup.claudeEvents)
        XCTAssertEqual(((twice["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count, 1)
        let off = HookSetup.remove(twice)
        XCTAssertFalse(HookSetup.isInstalled(off))
        let a = try JSONSerialization.data(withJSONObject: off, options: .sortedKeys)
        let b = try JSONSerialization.data(withJSONObject: existing, options: .sortedKeys)
        XCTAssertEqual(a, b)
    }

    func testCommandQuotesPath() {
        XCTAssertEqual(HookSetup.command(cli: "/Users/a b/needs-you", event: "Stop", agent: "codex"), "'/Users/a b/needs-you' hook Stop --agent codex")
    }

    func testOutputs() {
        XCTAssertNil(HookSetup.output(event: "Stop", messages: []))
        XCTAssertEqual(HookSetup.output(event: "Stop", messages: ["a", "b"])?["decision"] as? String, "block")
        XCTAssertEqual(HookSetup.output(event: "Stop", messages: ["a", "b"])?["reason"] as? String, "a\n\nb")
        let ctx = HookSetup.output(event: "PostToolUse", messages: ["hi"])?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(ctx?["additionalContext"] as? String, "hi")
        XCTAssertNil(HookSetup.output(event: "Notification", messages: ["hi"]))
    }
}
