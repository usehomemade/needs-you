@testable import NeedsYouShared
import XCTest

final class WakeMatcherTests: XCTestCase {
    /// (heard text, should wake, his voice learned)
    typealias Case = (String, Bool, Bool)

    func run(_ phrase: String, _ cases: [Case], file: StaticString = #filePath, line: UInt = #line) {
        let m = WakeMatcher(phrase: phrase)
        for (text, want, voice) in cases {
            XCTAssertEqual(m.contains(text, voiceLearned: voice), want,
                           "\(phrase): \"\(text)\" (voice \(voice)) should \(want ? "" : "not ")wake", file: file, line: line)
        }
    }

    func testDefaultIsHeyMac() {
        XCTAssertEqual(WakeMatcher.defaultPhrase, "Hey Mac")
        XCTAssertTrue(WakeMatcher(phrase: "Hey Mac").isDefault)
        XCTAssertTrue(WakeMatcher(phrase: "  hey   mac! ").isDefault)
        XCTAssertTrue(WakeMatcher(phrase: "").isDefault)
        XCTAssertEqual(WakeMatcher(phrase: "").name, "Mac")
        XCTAssertEqual(WakeMatcher(phrase: "").contextualStrings, ["Hey Mac", "Mac"])
        run("Hey Mac", [
            ("Hey Mac, this one: run the tests.", true, false),
            ("hey, mac", true, false),
            ("Hey Mack, docs site: test", true, false),
            ("hey mak", true, false),
            ("Hi Mac", true, false),
            ("Heymac this one", true, false),
            ("Pay Mac.", true, false),
            ("Hey Macs", true, false),
        ])
    }

    func testMigration() {
        let old = "Hey " + "Cl" + "aude"
        XCTAssertEqual(WakeMatcher.migrated(old), "Hey Mac")
        XCTAssertEqual(WakeMatcher.migrated(old.lowercased() + "!"), "Hey Mac")
        XCTAssertNil(WakeMatcher.migrated("Hey Baby"))
        XCTAssertNil(WakeMatcher.migrated("Hey Mac"))
        XCTAssertNil(WakeMatcher.migrated(nil))
    }

    func testMacAloneInNormalTalkDoesNotWake() {
        run("Hey Mac", [
            ("My Mac is slow today.", false, false),
            ("My Mac is slow today.", false, true),
            ("A Mac mini would do.", false, false),
            ("A Mac mini would do.", false, true),
            ("I bought a Mac.", false, false),
            ("Mac, open it", false, false),
            ("Hey, my Mac crashed", false, false),
            ("hey, make it quick", false, false),
            ("Hey Mike", false, false),
            ("hey man", false, false),
            ("I mac", false, true),
        ])
    }

    func testDefaultPartialAndHint() {
        let m = WakeMatcher(phrase: "Hey Mac")
        XCTAssertFalse(m.startsPhrase("Hey Ma")) // too short a name for an early wake
        XCTAssertTrue(m.hint("and then hey"))
        XCTAssertFalse(m.hint("nothing here"))
    }

    func testStopPhrase() {
        let m = WakeMatcher(phrase: "Hey Mac")
        XCTAssertTrue(m.isStop("Stop, Mac"))
        XCTAssertTrue(m.isStop("stop mack"))
        XCTAssertTrue(m.isStop("Stopmac."))
        XCTAssertTrue(m.isStop("Stuff Mac"))
        XCTAssertFalse(m.isStop("Some Mac users"))
        XCTAssertFalse(m.isStop("stop it"))
        XCTAssertFalse(m.isStop("my Mac"))
        let b = WakeMatcher(phrase: "Hey Baby")
        XCTAssertTrue(b.isStop("Stop, baby"))
        XCTAssertFalse(b.isStop("Stop, Mac"))
    }

    func testHeyBaby() {
        run("Hey Baby", [
            ("Hey baby, this one: run the tests.", true, false),
            ("hey, baby", true, false),
            ("Hey babe.", false, false),
            ("Hey babe.", true, true),
            ("Hey Bobby, orchard: deploy", true, false),
            ("Hey babies", true, false),
            ("Hi baby", true, false),
            ("Pay baby.", true, false),
            ("Heybaby this one", true, false),
            ("Hey, maybe later.", false, false),
            ("Hey, maybe later.", false, true),
            ("The baby is asleep.", false, false),
            ("Hey Bob", false, false),
            ("hey bae", false, false),
            ("Hey Mac", false, false),
            ("They baby", true, false), // "They" counts only at a sentence start
            ("I said they baby", false, false),
        ])
    }

    func testOtherPhrases() {
        run("Okay Computer", [
            ("ok computer, run it", true, false),
            ("Okay, computers", true, false),
            ("okay commuter", true, false),
            ("my computer is slow", false, false),
            ("okay, complete it", false, false),
        ])
        run("Hey Needs You", [
            ("Hey needs you, orchard: status", true, false),
            ("hey, need you", true, false),
            ("hey, needs a fix", false, false),
            ("I need you here", false, false),
        ])
        run("Jarvis", [
            ("Jarvis, this one: tests", true, false),
            ("Jarvis.", true, false),
            ("Travis", false, false),
            ("service", false, false),
        ])
        run("Hey Zoë", [
            ("hey zoe", true, false),
            ("Hey Zoë, this one", true, false),
            ("hey, tell him", false, false),
        ])
    }

    func testPartialFromPhrase() {
        let m = WakeMatcher(phrase: "Hey Baby")
        XCTAssertTrue(m.startsPhrase("Hey ba"))
        XCTAssertTrue(m.startsPhrase("ok so hey bab"))
        XCTAssertFalse(m.startsPhrase("Hey bad"))
        XCTAssertFalse(m.startsPhrase("Hey baby"))
        XCTAssertFalse(m.startsPhrase("ba"))
        let three = WakeMatcher(phrase: "Hey Needs You")
        XCTAssertFalse(three.startsPhrase("hey ne")) // the last word is too short for an early wake
        let jar = WakeMatcher(phrase: "Okay Jarvis")
        XCTAssertTrue(jar.startsPhrase("okay ja"))
        XCTAssertTrue(jar.startsPhrase("ok jar"))
        XCTAssertFalse(jar.startsPhrase("so ja"))
    }

    func testHint() {
        XCTAssertTrue(WakeMatcher(phrase: "Hey Baby").hint("so hey"))
        let jar = WakeMatcher(phrase: "Jarvis")
        XCTAssertTrue(jar.hint("ok jarvis"))
        XCTAssertFalse(jar.hint("hey there"))
    }

    func testAfter() {
        let m = WakeMatcher(phrase: "Hey Baby")
        XCTAssertEqual(m.after("Hey baby, this one: run the tests.", voiceLearned: false), "this one: run the tests.")
        XCTAssertEqual(m.after("Hey baby. Hey baby, orchard: deploy", voiceLearned: false), "orchard: deploy")
        XCTAssertEqual(m.after("Hey baby, um, hey bobby, done", voiceLearned: false), "done")
        XCTAssertEqual(m.after("Hey baby, tell them I said hey baby", voiceLearned: false), "tell them I said hey baby")
        XCTAssertNil(m.after("nothing", voiceLearned: false))
        let d = WakeMatcher(phrase: "Hey Mac")
        XCTAssertEqual(d.after("Hey Mac. Hey Mac, this one: go", voiceLearned: false), "this one: go")
        XCTAssertEqual(d.after("Hey Mac, docs site: test", voiceLearned: false), "docs site: test")
        XCTAssertEqual(d.after("Hey Mack, my Mac is slow", voiceLearned: false), "my Mac is slow")
    }

    func testKey() {
        XCTAssertEqual(WakeMatcher.key("mac"), WakeMatcher.key("mack"))
        XCTAssertEqual(WakeMatcher.key("mac"), WakeMatcher.key("mak"))
        XCTAssertNotEqual(WakeMatcher.key("mac"), WakeMatcher.key("man"))
        XCTAssertEqual(WakeMatcher.key("baby"), WakeMatcher.key("bobby"))
    }

    func testCheck() {
        XCTAssertNil(WakeMatcher.check("Hey Mac").warning)
        XCTAssertNil(WakeMatcher.check("Hey Baby").warning)
        XCTAssertNotNil(WakeMatcher.check("Jarvis").warning) // one word, 2 syllables
        XCTAssertFalse(WakeMatcher.check("  ").usable)
        XCTAssertNotNil(WakeMatcher.check("Bob").warning)
        XCTAssertNotNil(WakeMatcher.check("hey you").warning)
        XCTAssertNotNil(WakeMatcher.check("thank you").warning)
        XCTAssertNil(WakeMatcher.check("Computer").warning) // 3 syllables
        XCTAssertNotNil(WakeMatcher.check("hey there buddy my old friend").warning)
    }
}
