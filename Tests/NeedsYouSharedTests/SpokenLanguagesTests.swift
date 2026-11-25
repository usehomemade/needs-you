@testable import NeedsYouShared
import XCTest

final class SpokenLanguagesTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(SpokenLanguages.parse(nil), ["en"])
        XCTAssertEqual(SpokenLanguages.parse(""), ["en"])
        XCTAssertEqual(SpokenLanguages.parse("xx"), ["en"])
        XCTAssertEqual(SpokenLanguages.parse("tr,en"), ["en", "tr"])
        XCTAssertEqual(SpokenLanguages.parse(" TR , de"), ["tr", "de"])
        XCTAssertEqual(SpokenLanguages.store(["ru", "en", "ru"]), "en,ru")
    }

    func testEndWords() {
        let tr = ["en", "tr"]
        // Standalone end words end the turn.
        XCTAssertTrue(SpokenLanguages.endsWithEndWord("Testleri tekrar çalıştır, bitti.", languages: tr))
        XCTAssertTrue(SpokenLanguages.endsWithEndWord("Testleri tekrar çalıştır. Tamam.", languages: tr))
        XCTAssertTrue(SpokenLanguages.endsWithEndWord("Bu kadar.", languages: tr))
        XCTAssertTrue(SpokenLanguages.endsWithEndWord("tamamdır", languages: tr))
        // A verb at the end of a Turkish sentence is not an end word.
        XCTAssertFalse(SpokenLanguages.endsWithEndWord("Test bitti.", languages: tr))
        XCTAssertFalse(SpokenLanguages.endsWithEndWord("Deploy bitti mi?", languages: tr))
        // Only the languages that are on.
        XCTAssertFalse(SpokenLanguages.endsWithEndWord("Mach das, fertig.", languages: tr))
        XCTAssertTrue(SpokenLanguages.endsWithEndWord("Mach das, fertig.", languages: ["en", "de"]))
        XCTAssertTrue(SpokenLanguages.endsWithEndWord("Fais-le, c'est tout.", languages: ["fr"]))
        XCTAssertTrue(SpokenLanguages.endsWithEndWord("Fais-le, c’est tout !", languages: ["fr"]))
        XCTAssertTrue(SpokenLanguages.endsWithEndWord("Fallo adesso, ho finito.", languages: ["it"]))
        XCTAssertTrue(SpokenLanguages.endsWithEndWord("Запусти тесты. Готово.", languages: ["ru"]))
        XCTAssertTrue(SpokenLanguages.endsWithEndWord("Запусти тесты, всё.", languages: ["ru"]))
        // English is handled by the app's own rule.
        XCTAssertFalse(SpokenLanguages.endsWithEndWord("Run the tests, done.", languages: ["en"]))
    }

    func testStrip() {
        let tr = ["en", "tr"]
        XCTAssertEqual(SpokenLanguages.stripEndWord("Testleri çalıştır, bitti.", languages: tr), "Testleri çalıştır")
        XCTAssertEqual(SpokenLanguages.stripEndWord("Testleri çalıştır. Tamam.", languages: tr), "Testleri çalıştır.")
        // A lone "Tamam." is his answer ("okay"): kept.
        XCTAssertEqual(SpokenLanguages.stripEndWord("Tamam.", languages: tr), "Tamam.")
        XCTAssertEqual(SpokenLanguages.stripEndWord("Test bitti.", languages: tr), "Test bitti.")
        XCTAssertEqual(SpokenLanguages.stripEndWord("Run the tests.", languages: tr), "Run the tests.")
    }
}
