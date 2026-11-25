import XCTest
@testable import NeedsYouShared

final class TurnTextTests: XCTestCase {
    func testOpenEndings() {
        // The cut-offs from 25 Nov (HM-1360).
        XCTAssertTrue(TurnText.trailsOff("Hey Claude, I think I like."))
        XCTAssertTrue(TurnText.trailsOff("because right now when I try to."))
        XCTAssertTrue(TurnText.trailsOff("Check the deploy and"))
        XCTAssertTrue(TurnText.trailsOff("So what I want is, um"))
        XCTAssertTrue(TurnText.trailsOff("I think"))
        XCTAssertTrue(TurnText.trailsOff("Open the pull request,"))
        XCTAssertTrue(TurnText.trailsOff("Let me see..."))
        XCTAssertTrue(TurnText.trailsOff("Testleri çalıştır ve"))
        XCTAssertTrue(TurnText.trailsOff("Ich glaube, dass"))
    }

    func testFinishedEndings() {
        XCTAssertFalse(TurnText.trailsOff("Yes, go ahead."))
        XCTAssertFalse(TurnText.trailsOff("Run the tests."))
        XCTAssertFalse(TurnText.trailsOff("I think so."))
        XCTAssertFalse(TurnText.trailsOff("I'd like that."))
        XCTAssertFalse(TurnText.trailsOff("No."))
        XCTAssertFalse(TurnText.trailsOff("Turn it on."))
        XCTAssertFalse(TurnText.trailsOff("Can you do it for me?"))
        XCTAssertFalse(TurnText.trailsOff("Bu kadar yani."))
        XCTAssertFalse(TurnText.trailsOff(""))
    }

    func testLanguagePick() {
        // Clear English with English picked.
        var d = LanguagePick.decide(["en": 0.97, "nl": 0.02, "de": 0.01], picked: ["en"], strict: false, speech: 2)
        XCTAssertEqual(d.code, "en"); XCTAssertTrue(d.confident)
        // Too little speech: not shown yet.
        d = LanguagePick.decide(["en": 0.97, "nl": 0.03], picked: ["en"], strict: false, speech: 1.0)
        XCTAssertFalse(d.confident)
        // German he did not pick, clear: switches.
        d = LanguagePick.decide(["de": 0.96, "en": 0.03, "nl": 0.01], picked: ["en", "tr"], strict: false, speech: 2)
        XCTAssertEqual(d.code, "de"); XCTAssertTrue(d.confident)
        // German strict: stays with his languages.
        d = LanguagePick.decide(["de": 0.96, "en": 0.03, "tr": 0.01], picked: ["en", "tr"], strict: true, speech: 2)
        XCTAssertEqual(d.code, "en")
        // A shaky other language (Hindi 0.6): not clear, best of his.
        d = LanguagePick.decide(["hi": 0.6, "en": 0.3, "tr": 0.1], picked: ["en", "tr"], strict: false, speech: 2)
        XCTAssertFalse(d.confident); XCTAssertEqual(d.code, "en")
        // Turkish picked, moderately sure: the prior makes it clear.
        d = LanguagePick.decide(["tr": 0.7, "az": 0.25, "en": 0.05], picked: ["en", "tr"], strict: false, speech: 2)
        XCTAssertEqual(d.code, "tr"); XCTAssertTrue(d.confident)
    }
}

final class ScriptTests: XCTestCase {
    func testFits() {
        XCTAssertTrue(Script.fits("Türkçe konuştuğum zaman", languages: ["tr"]))
        XCTAssertTrue(Script.fits("Run the tests.", languages: ["en"]))
        XCTAssertFalse(Script.fits("तुर्की बोलते समय", languages: ["en", "tr"]))
        XCTAssertTrue(Script.fits("Запусти тесты", languages: ["ru"]))
        XCTAssertFalse(Script.fits("Запусти тесты", languages: ["tr"]))
        XCTAssertTrue(Script.fits("", languages: ["tr"]))
    }
}
