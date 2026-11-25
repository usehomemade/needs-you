@testable import NeedsYouShared
import XCTest

final class SpeechTextTests: XCTestCase {
    /// Lines like the ones agents write stay as they are: agents already write
    /// spoken text most of the time, and the cleaner must not hurt it.
    func testRealLinesUnchanged() {
        let lines = [
            "Yesterday at 11:02 p.m., from needs-you: website is waiting for you.",
            "website asks: Which color? Option 1, Red. Option 2, Blue.",
            "Got it. Ready for number 4?",
            "Understood. Your voice itself is recognized every time: the speaker match was 0.56 to 0.76 on all five tries, and the game never got through.",
            "Turkish and German voices are ready for you to listen to. I used Supertonic instead of Piper: one 162 megabyte download covers Turkish, German, French, Italian and Russian, and it's fast.",
            "One thing for you: in the Chrome window called Work, at the top left, sign in to X as alex underscore, then add acme as a second account.",
            "Two things. First, production: I found why your new VMs break. Your production acme-dev project has none of its environment variables, so install fails and then every service fails.",
            "Merhaba Neşe! Şu an Türkçe konuşuyorum. Sesim nasıl geliyor?",
            "Got it. Apple style version three it is, but all of it lower and bassier.",
            "Sorry Zoë, my last message quoted your phrase, which turned the detector off, so that one did not count.",
            "Okay, removing ElevenLabs. Idle it uses about 30 megabytes and the same few percent CPU as before.",
            "Try four missed: I heard Hey God instead of Hey Claude.",
            "I only caught 'I think I like'. Which set: Cuelume, Minimal, Soft, or Apple style?",
            "Sentence 5: Please ask Neşe before you change anything on the server.",
            "PS4 is an open model that pulls your voice out of game noise.",
            "Click Deny on that Keychain prompt. We won't use the old key, I'm making a new certificate just for Needs You.",
        ]
        for line in lines {
            XCTAssertEqual(SpeechText.spoken(line), line, line)
        }
    }

    func testRules() {
        let cases: [(String, String)] = [
            // paths
            ("I changed Sources/NeedsYou/Sounds.swift.", "I changed Sounds dot swift."),
            ("Edit `~/.claude/settings.json` first.", "Edit settings dot json first."),
            ("The log is in /tmp/needs-you/run.log, look there.", "The log is in run dot log, look there."),
            ("Run ./scripts/install.sh again.", "Run install dot sh again."),
            ("It lives in acme/infra.", "It lives in infra."),
            ("Pick yes/no and and/or stay readable.", "Pick yes or no and and or or stay readable."),
            ("It runs 24/7 now.", "It runs 24/7 now."),
            ("Files go in ~/ by default.", "Files go in home folder by default."),
            // URLs
            ("See https://github.com/FluidInference/FluidAudio/releases for that.", "See github dot com for that."),
            ("The page is at https://docs.example.org/a/what-the-other-voice-tools-do.", "The page is at docs dot example dot org."),
            ("Open [the study](https://docs.example.org/a/x) now.", "Open the study now."),
            ("Docs: www.example.com/docs/page", "Docs: example dot com"),
            // code
            ("Run this:\n```bash\nnpm test -- auth.spec.ts\n```\nThen tell me.", "Run this: a code block. Then tell me."),
            ("Run `npm test` and `swift build`.", "Run npm test and swift build."),
            // markdown
            ("## Status\n- **Build** is green\n- Tests: *all* passing", "Status. Build is green. Tests: all passing."),
            ("> Note: this is _important_.", "Note: this is important."),
            ("| Name | Result |\n|---|---|\n| build | green |", "Name, Result. build, green."),
            ("1. Open the file\n2. Save it", "1. Open the file. 2. Save it."),
            // dashes
            ("It works — mostly.", "It works, mostly."),
            ("That took 3–5 hours.", "That took 3 to 5 hours."),
            ("Done - now the tests.", "Done, now the tests."),
            // hashes and ids
            ("Merged at 227dbf4 on main.", "Merged at on main."),
            ("Pushed 7feceb0a1b2c3d4e5f60718293a4b5c6d7e8f901 to next.", "Pushed to next."),
            ("The project ce2f6cbd-734c-42be-910a-94e9ace8ce84 is ready.", "The project is ready."),
            ("The app twjyo4jiod3hnovolaftxwxe restarted.", "The app restarted."),
            ("Fixed in PR #123.", "Fixed in PR number 123."),
            // versions
            ("Release v1.2.3 is out.", "Release version 1.2.3 is out."),
            ("FluidAudio v0.18.3 works.", "FluidAudio version 0.18.3 works."),
            // units and symbols
            ("It takes ~50 ms per pass.", "It takes about 50 milliseconds per pass."),
            ("About 630 MB, and 1 GB later.", "About 630 megabytes, and 1 gigabyte later."),
            ("Wait 2 s, then 4s at most.", "Wait 2 seconds, then 4 seconds at most."),
            ("CPU at 23 % and 9% later.", "CPU at 23 percent and 9 percent later."),
            ("Build → test → ship.", "Build to test to ship."),
            ("Score ≥ 0.45 counts.", "Score at least 0.45 counts."),
            ("That's 4x faster at 44.1 kHz.", "That's 4 times faster at 44.1 kilohertz."),
            ("In the 1990s it was 30 min.", "In the 1990s it was 30 minutes."),
            ("Logs & metrics are fine.", "Logs and metrics are fine."),
            // file names and domains
            ("Check README.md and Package.swift.", "Check README dot md and Package dot swift."),
            ("Staging is on acme.dev now.", "Staging is on acme dot dev now."),
            ("Set it in the .env file.", "Set it in the dot env file."),
            ("e.g. at 9 a.m. it runs.", "e.g. at 9 a.m. it runs."),
            // emoji
            ("All green ✅ shipped 🚀!", "All green shipped!"),
            ("Thumbs up 👍🏽 from me.", "Thumbs up from me."),
            // snake case
            ("The permission_prompt event fired.", "The permission prompt event fired."),
        ]
        for (input, want) in cases {
            XCTAssertEqual(SpeechText.spoken(input), want, input)
        }
    }

    func testIdempotent() {
        for s in ["I changed Sources/NeedsYou/Sounds.swift.", "Release v1.2.3 is out.", "It takes ~50 ms per pass.", "Run this:\n```\nx\n```"] {
            let once = SpeechText.spoken(s)
            XCTAssertEqual(SpeechText.spoken(once), once, s)
        }
    }

    func testEmptyAndPlain() {
        XCTAssertEqual(SpeechText.spoken(""), "")
        XCTAssertEqual(SpeechText.spoken("Okay."), "Okay.")
        XCTAssertEqual(SpeechText.spoken("Hi Zoë. This is how I sound when an agent needs you."), "Hi Zoë. This is how I sound when an agent needs you.")
    }
}
