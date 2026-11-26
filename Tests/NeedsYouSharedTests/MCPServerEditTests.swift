import XCTest
@testable import NeedsYouShared

/// The Claude app's claude_desktop_config.json (HM-1385): only our entry changes.
final class MCPServerEditTests: XCTestCase {
    let config: [String: Any] = ["preferences": ["sidebarMode": "chat"], "coworkUserFilesPath": "/Users/x/Claude"]

    func testAddKeepsEverythingElse() {
        let on = HookSetup.mcpServerEdit(config, cli: "/bin/needs-you", agent: "claude-app", on: true)
        let s = (on["mcpServers"] as? [String: Any])?["needs-you"] as? [String: Any]
        XCTAssertEqual(s?["command"] as? String, "/bin/needs-you")
        XCTAssertEqual((s?["env"] as? [String: String])?["NEEDS_YOU_AGENT"], "claude-app")
        XCTAssertEqual((on["preferences"] as? [String: String])?["sidebarMode"], "chat")
    }

    func testRemoveRestoresTheFileAndKeepsOtherServers() {
        let on = HookSetup.mcpServerEdit(config, cli: "/bin/needs-you", agent: "claude-app", on: true)
        let off = HookSetup.mcpServerEdit(on, cli: "/bin/needs-you", agent: "claude-app", on: false)
        XCTAssertTrue(NSDictionary(dictionary: off).isEqual(to: config))
        var other = config; other["mcpServers"] = ["linear": ["url": "https://x"]]
        let back = HookSetup.mcpServerEdit(HookSetup.mcpServerEdit(other, cli: "c", agent: "a", on: true), cli: "c", agent: "a", on: false)
        XCTAssertTrue(NSDictionary(dictionary: back).isEqual(to: other))
    }
}
