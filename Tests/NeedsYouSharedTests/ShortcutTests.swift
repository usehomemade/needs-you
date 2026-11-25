@testable import NeedsYouShared
import XCTest

final class ShortcutTests: XCTestCase {
    func testDefaultAndDisplay() {
        XCTAssertEqual(KeyCombo.defaultTurn.display, "⌥⇧Space")
        XCTAssertEqual(KeyCombo(keyCode: 49, modifiers: KeyCombo.control | KeyCombo.option).display, "⌃⌥Space")
        XCTAssertEqual(KeyCombo(keyCode: 40, modifiers: KeyCombo.cmd | KeyCombo.shift).display, "⇧⌘K")
        XCTAssertEqual(KeyCombo.escape.display, "Esc")
        XCTAssertTrue(KeyCombo.defaultTurn.isValid)
        XCTAssertFalse(KeyCombo(keyCode: 49, modifiers: KeyCombo.shift).isValid)  // ⇧Space would eat typing
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: 0).isValid)
        XCTAssertTrue(KeyCombo(keyCode: 105, modifiers: 0).isValid)               // F13 alone
        XCTAssertEqual(KeyCombo(stored: KeyCombo.defaultTurn.stored), .defaultTurn)
        XCTAssertNil(KeyCombo(stored: ""))
    }

    func testTurnKeyActions() {
        typealias S = TurnKey.State
        XCTAssertEqual(TurnKey.action(S()), .openCommand)
        // Do not disturb wins over everything, even while something is going on.
        XCTAssertEqual(TurnKey.action(S(doNotDisturb: true)), .moon)
        XCTAssertEqual(TurnKey.action(S(doNotDisturb: true, speaking: true)), .moon)
        XCTAssertEqual(TurnKey.action(S(doNotDisturb: true, commandOpen: true)), .moon)
        XCTAssertEqual(TurnKey.action(S(speaking: true)), .stopSpeech)
        XCTAssertEqual(TurnKey.action(S(speaking: true, answerOpen: true)), .stopSpeech)
        XCTAssertEqual(TurnKey.action(S(commandOpen: true)), .endCommand)
        XCTAssertEqual(TurnKey.action(S(answerOpen: true)), .endAnswer)
        XCTAssertEqual(TurnKey.action(S(working: true)), .ignore)
    }

    func testSpeechStop() {
        XCTAssertTrue(SpeechStop.voice.listensAfter)
        XCTAssertTrue(SpeechStop.menu.listensAfter)
        XCTAssertFalse(SpeechStop.escape.listensAfter)
    }
}
