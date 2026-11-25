@testable import NeedsYouShared
import XCTest

final class AgentInstructionsTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ny-agents-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    private func write(_ name: String, _ s: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try s.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testFreshInstallCreatesFileAndImport() throws {
        var a = AgentInstructions(dir: dir, defaultText: "v1\n")
        let s = try a.sync()
        XCTAssertEqual(read("needs-you.md"), "v1\n")
        XCTAssertEqual(read("CLAUDE.md"), AgentInstructions.block + "\n")
        XCTAssertTrue(s.imported)
        XCTAssertFalse(s.edited)
        XCTAssertNil(read("CLAUDE.md.needs-you-backup"), "nothing to back up")
    }

    func testAppendsBlockKeepsContentAndBacksUpOnce() throws {
        let mine = "# Mine\n\n- rule\n"
        try write("CLAUDE.md", mine)
        var a = AgentInstructions(dir: dir, defaultText: "v1\n")
        try a.sync()
        XCTAssertEqual(read("CLAUDE.md"), mine + "\n" + AgentInstructions.block + "\n")
        XCTAssertEqual(read("CLAUDE.md.needs-you-backup"), mine)
        try a.sync() // idempotent
        XCTAssertEqual(read("CLAUDE.md"), mine + "\n" + AgentInstructions.block + "\n")
        try a.disable()
        XCTAssertEqual(read("CLAUDE.md"), mine)
        XCTAssertEqual(read("CLAUDE.md.needs-you-backup"), mine)
    }

    func testUpdatesUneditedFile() throws {
        var a = AgentInstructions(dir: dir, defaultText: "v1\n")
        try a.sync()
        var b = AgentInstructions(dir: dir, defaultText: "v2\n", record: a.record)
        let s = try b.sync()
        XCTAssertEqual(read("needs-you.md"), "v2\n")
        XCTAssertNil(read("needs-you.default.md"))
        XCTAssertFalse(s.newDefaultWaiting)
    }

    func testKeepsEditedFileAndOffersNewDefault() throws {
        var a = AgentInstructions(dir: dir, defaultText: "v1\n")
        try a.sync()
        try write("needs-you.md", "mine\n")
        // Same default: his edit just stays, no notice.
        var same = AgentInstructions(dir: dir, defaultText: "v1\n", record: a.record)
        var s = try same.sync()
        XCTAssertTrue(s.edited)
        XCTAssertFalse(s.newDefaultWaiting)
        // New default: keep his, park the default, offer the choice.
        var b = AgentInstructions(dir: dir, defaultText: "v2\n", record: a.record)
        s = try b.sync()
        XCTAssertEqual(read("needs-you.md"), "mine\n")
        XCTAssertEqual(read("needs-you.default.md"), "v2\n")
        XCTAssertTrue(s.newDefaultWaiting)
        XCTAssertTrue(b.diff().contains("- mine"))
        XCTAssertTrue(b.diff().contains("+ v2"))
        var keep = b
        keep.keepMine()
        XCTAssertFalse(keep.status(enabled: true).newDefaultWaiting)
        XCTAssertNil(read("needs-you.default.md"))
        try keep.sync()
        XCTAssertNil(read("needs-you.default.md"), "a dismissed default is not offered again")
        try b.useNewDefault()
        XCTAssertEqual(read("needs-you.md"), "v2\n")
        XCTAssertFalse(b.status(enabled: true).edited)
    }

    func testLegacySectionIsOnlyFoundNotRemovedBySync() throws {
        let md = "# Top\n\n## Other\n- a\n\n## Needs You: ask Alex out loud\n\n- old line\n- old 2\n\n## Next\n- b\n"
        try write("CLAUDE.md", md)
        var a = AgentInstructions(dir: dir, defaultText: "v1\n")
        let s = try a.sync()
        XCTAssertEqual(s.legacySection, "## Needs You: ask Alex out loud\n\n- old line\n- old 2\n\n")
        XCTAssertTrue(read("CLAUDE.md")!.contains("- old line"), "sync never removes it")
        try a.removeLegacySection()
        XCTAssertEqual(read("CLAUDE.md"), "# Top\n\n## Other\n- a\n\n## Next\n- b\n\n" + AgentInstructions.block + "\n")
        XCTAssertEqual(read("CLAUDE.md.needs-you-backup"), md)
        XCTAssertNil(a.status(enabled: true).legacySection)
    }

    func testLegacySectionAtEndAndRepairsBlock() {
        let md = "# A\n\n## Needs You: ask Alex out loud\n- x\n"
        XCTAssertEqual(AgentInstructions.legacySection(in: md).map { String(md[$0]) }, "## Needs You: ask Alex out loud\n- x\n")
        let broken = "x\n\n<!-- needs-you:begin -->\n@old.md\n<!-- needs-you:end -->\ny\n"
        XCTAssertEqual(AgentInstructions.withImport(broken), "x\n\n" + AgentInstructions.block + "\ny\n")
        XCTAssertNil(AgentInstructions.withImport("x\n\n" + AgentInstructions.block + "\n"))
    }

    func testDefaultTextIsCurrent() {
        let t = AgentInstructions.defaultText()
        XCTAssertTrue(t.hasPrefix("## Needs You: ask the user out loud\n"))
        XCTAssertTrue(AgentInstructions.defaultText(name: "Alex").hasPrefix("## Needs You: ask Alex out loud\n"))
        XCTAssertTrue(AgentInstructions.defaultText(name: "Alex").contains("When you need Alex ("))
        XCTAssertTrue(t.contains("voicemail"))
        XCTAssertTrue(t.contains("Escape"))
        XCTAssertFalse(t.contains("did not answer twice"))
    }
}
