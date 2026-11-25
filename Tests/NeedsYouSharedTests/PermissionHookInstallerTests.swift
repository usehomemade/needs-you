@testable import NeedsYouShared
import XCTest

final class PermissionHookInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ny-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let existing = """
    {
      "env": {
        "A": "1"
      },
      "permissions": {
        "allow": [
          "Bash(artifact:*)",
          "Bash(ssh host 'docker exec * x *')"
        ],
        "defaultMode": "auto"
      },
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "AskUserQuestion",
            "hooks": [
              {
                "type": "command",
                "command": "python3 /x/voice-ask.py",
                "timeout": 130,
                "statusMessage": "Asking out loud — say \\"keyboard\\""
              }
            ]
          }
        ]
      },
      "theme": "dark",
      "emptyList": [],
      "emptyObject": {},
      "n": 1.5e3,
      "unicode": "Zoë ✓ \\u0001",
      "flag": false,
      "nothing": null
    }

    """

    func testRoundTripIsByteForByte() throws {
        let v = try JSONValue.parse(existing)
        XCTAssertEqual(v.serialized() + "\n", existing)
    }

    func testInstallAndRemoveKeepTheRest() throws {
        let url = dir.appendingPathComponent("settings.json")
        try existing.write(to: url, atomically: true, encoding: .utf8)
        let inst = PermissionHookInstaller(dir: dir)
        XCTAssertFalse(inst.isInstalled)

        XCTAssertTrue(try inst.install(cli: "/Apps/Needs You.app/Contents/Helpers/needs-you"))
        XCTAssertTrue(inst.isInstalled)
        // Backup is the file as it was.
        XCTAssertEqual(try String(contentsOf: inst.backupURL, encoding: .utf8), existing)
        let after = try String(contentsOf: url, encoding: .utf8)
        let head = String(existing[..<existing.range(of: "\"hooks\": {")!.lowerBound])
        XCTAssertTrue(after.hasPrefix(head))
        XCTAssertTrue(after.hasSuffix(String(existing[existing.range(of: "  \"theme\"")!.lowerBound...])))
        XCTAssertTrue(after.contains(#""PermissionRequest": ["#))
        XCTAssertTrue(after.contains(#""command": "'/Apps/Needs You.app/Contents/Helpers/needs-you' permission-hook # needs-you:permission-voice""#))
        XCTAssertTrue(after.contains(#""matcher": "Bash|mcp__.*""#))
        // Claude Code can read it.
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(after.utf8)))

        // Same path again: nothing to do. New path: updated in place, one entry.
        XCTAssertFalse(try inst.install(cli: "/Apps/Needs You.app/Contents/Helpers/needs-you"))
        XCTAssertTrue(try inst.install(cli: "/Other/needs-you"))
        let moved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(moved.components(separatedBy: PermissionHookInstaller.marker).count, 2)
        XCTAssertTrue(moved.contains("'/Other/needs-you' permission-hook"))

        XCTAssertTrue(try inst.remove())
        XCTAssertFalse(inst.isInstalled)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), existing)
        XCTAssertFalse(try inst.remove())
    }

    func testKeepsOtherPermissionRequestHooks() throws {
        let url = dir.appendingPathComponent("settings.json")
        let mine = """
        {
          "hooks": {
            "PermissionRequest": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "other-hook"
                  }
                ]
              }
            ]
          }
        }

        """
        try mine.write(to: url, atomically: true, encoding: .utf8)
        let inst = PermissionHookInstaller(dir: dir)
        try inst.install(cli: "/x/needs-you")
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.contains("other-hook"))
        try inst.remove()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), mine)
    }

    func testNoFileAndBadFile() throws {
        let inst = PermissionHookInstaller(dir: dir)
        try inst.install(cli: "/x/needs-you")
        XCTAssertTrue(inst.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inst.backupURL.path))
        try inst.remove()
        XCTAssertEqual(try String(contentsOf: inst.settingsURL, encoding: .utf8), "{}\n")

        try "{ not json".write(to: inst.settingsURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try inst.install(cli: "/x/needs-you"))
        XCTAssertEqual(try String(contentsOf: inst.settingsURL, encoding: .utf8), "{ not json")
    }

    func testPreview() {
        let p = PermissionHookInstaller.preview(cli: "/x/needs-you")
        XCTAssertTrue(p.contains(#""PermissionRequest""#))
        XCTAssertTrue(p.contains(#""timeout": 60"#))
    }
}
