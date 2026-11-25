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

    func testDefaultKeepsMeasuredPatterns() {
        let m = WakeMatcher(phrase: "Hey Claude")
        XCTAssertTrue(m.isDefault)
        XCTAssertTrue(WakeMatcher(phrase: "  hey   claude! ").isDefault)
        XCTAssertTrue(WakeMatcher(phrase: "").isDefault)
        run("Hey Claude", [
            ("Hey Claude, this one: run the tests.", true, false),
            ("hey cloud", true, false),
            ("Hey clock", true, false),
            ("Hey Clyde.", true, false),
            ("Pay Claude, this one", true, false),
            ("Hey, close that window.", false, false),
            ("Hey, close that window.", false, true),
            ("I talked to Claude yesterday.", false, false),
            ("Hey Club", false, false),
            ("Hey Club", true, true),
            ("Playcloud", true, true),
            ("They went home.", false, true),
        ])
    }

    func testDefaultPartialAndHint() {
        let m = WakeMatcher(phrase: "Hey Claude")
        XCTAssertTrue(m.startsPhrase("Hey Cl"))
        XCTAssertTrue(m.startsPhrase("so, hey cla"))
        XCTAssertFalse(m.startsPhrase("Hey Claude, this"))
        XCTAssertTrue(m.hint("and then hey"))
        XCTAssertFalse(m.hint("nothing here"))
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
            ("Hey Claude", false, false),
            ("They baby", true, false), // "They" counts only at a sentence start
            ("I said they baby", false, false),
        ])
    }

    func testHeyClaudeThroughGenericMatcher() {
        // The generic matcher, run on the default words, behaves sensibly too.
        let m = WakeMatcher(phrase: "Hey Claude")
        let generic = { (t: String) -> Bool in
            let toks = WakeMatcher.tokens(t)
            for i in toks.indices where m.wordMatch(toks[i].word, 0, sentenceStart: toks[i].sentenceStart, voiceLearned: false) {
                if i + 1 < toks.count, m.wordMatch(toks[i + 1].word, 1, sentenceStart: false, voiceLearned: false) { return true }
            }
            return false
        }
        for t in ["Hey Claude", "hey cloud", "Hey clod", "hey clawed", "Hey Clyde", "hey claud", "Hey Claudes"] {
            XCTAssertTrue(generic(t), t)
        }
        for t in ["hey, close that", "Hey club", "hey clue", "hey cloth", "hey, could you", "hey call"] {
            XCTAssertFalse(generic(t), t)
        }
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
        let d = WakeMatcher(phrase: "Hey Claude")
        XCTAssertEqual(d.after("Hey Claude. Hey Claude, this one: go", voiceLearned: false), "this one: go")
    }

    func testKey() {
        XCTAssertEqual(WakeMatcher.key("claude"), WakeMatcher.key("cloud"))
        XCTAssertEqual(WakeMatcher.key("claude"), WakeMatcher.key("clawed"))
        XCTAssertNotEqual(WakeMatcher.key("claude"), WakeMatcher.key("close"))
        XCTAssertEqual(WakeMatcher.key("baby"), WakeMatcher.key("bobby"))
    }

    func testCheck() {
        XCTAssertNil(WakeMatcher.check("Hey Claude").warning)
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
