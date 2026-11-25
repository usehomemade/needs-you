@testable import NeedsYouShared
import XCTest

final class PresenceTests: XCTestCase {
    func testParse() {
        let cases: [(String, PresenceCommand?)] = [
            ("Good night.", .away(goodNight: true)),
            ("goodnight", .away(goodNight: true)),
            ("I'm going to bed, thanks.", .away(goodNight: true)),
            ("I'm going to take a shower.", .away(goodNight: false)),
            ("Um, I'm taking a break.", .away(goodNight: false)),
            ("Do not disturb.", .away(goodNight: false)),
            ("Don't disturb me", .away(goodNight: false)),
            ("Be right back.", .away(goodNight: false)),
            ("I'm back.", .back(summary: false)),
            ("Good morning!", .back(summary: false)),
            ("Morning.", .back(summary: false)),
            ("Good morning, what did you work on last night?", .back(summary: true)),
            ("I'm back. What happened while I was away?", .back(summary: true)),
            ("What did you work on last night?", .summary),
            ("Catch me up.", .summary),
            ("Play my voicemails.", .playVoicemails),
            ("Any messages?", .playVoicemails),
            ("Do I have any voicemails?", .playVoicemails),
            // Messages for a chat stay messages.
            ("this one: write a good night message for the team", nil),
            ("orchard: what's the status of the deploy?", nil),
            ("this one: I'm back from lunch, rerun the tests", nil),
            ("orchard: morning standup notes please", nil),
            ("trip planner: book a hotel where I can take a shower and sleep", nil),
            ("", nil),
        ]
        for (text, want) in cases {
            XCTAssertEqual(PresenceCommand.parse(text), want, text)
        }
    }
}
