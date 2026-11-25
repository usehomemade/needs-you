import Foundation
import XCTest

/// HM-1363: the notch island owns on-screen state. No other code may open a floating
/// panel, HUD, popover or notification banner (the old top-right "Sending…" panel).
/// Only Island.swift (the island) and Subtitles.swift (subtitles and the edge glow)
/// may create panels; the app's own windows are SwiftUI `Window` scenes in App.swift.
final class SurfaceGuardTests: XCTestCase {
    static let allowed: [String: [String]] = [
        "Island.swift": ["NSPanel"],
        "Subtitles.swift": ["NSPanel"],
    ]

    static let forbidden = [
        "NSPanel", "NSWindow(", "NSWindowController(", "NSPopover", "UNUserNotification", "NSUserNotification",
        "UNMutableNotificationContent", ".hudWindow, ", "SendHUD", "makeKeyAndOrderFront(nil)",
    ]

    func testOnlyTheIslandAndSubtitlesPutPanelsOnScreen() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "Sources not found at \(sources.path)")
        var hits: [String] = []
        for f in files {
            let ok = Self.allowed[f.lastPathComponent] ?? []
            let lines = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
            for (n, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                for word in Self.forbidden where code.contains(word) && !ok.contains(where: { word.hasPrefix($0) }) {
                    // AppShell brings the app's own main window forward; that is not a popup.
                    if f.lastPathComponent == "AppShell.swift" && word == "makeKeyAndOrderFront(nil)" { continue }
                    hits.append("\(f.lastPathComponent):\(n + 1): \(word)")
                }
            }
        }
        XCTAssertEqual(hits, [], "Show state on the island (Island.swift), not in a new panel or banner: \(hits)")
    }
}
