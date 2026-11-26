import XCTest
@testable import NeedsYouShared

/// "For three hours", "until 8", "until tomorrow morning" (HM-1433): the model fills the parts,
/// this code turns them into a date against the clock.
final class AwayTimeTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// `h`:`m` on `day` November 2026 (the 25th is a Wednesday).
    func at(_ h: Int, _ m: Int = 0, day: Int = 25) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }
    func end(_ t: AwayTime, now: Date? = nil) -> Date? { t.end(now: now ?? at(10), calendar: cal) }

    func testLength() {
        XCTAssertEqual(end(AwayTime(minutes: 180)), at(13))
        XCTAssertEqual(end(AwayTime(minutes: 20)), at(10, 20))
    }
    func testNothingSaidHasNoEnd() {
        XCTAssertNil(end(AwayTime()))
        XCTAssertNil(end(AwayTime(minutes: 0, hour: -1)))
    }
    func testHourWithoutAmPmIsTheNextOneAhead() {
        XCTAssertEqual(end(AwayTime(hour: 8)), at(20))
        XCTAssertEqual(end(AwayTime(hour: 4)), at(16))
        XCTAssertEqual(end(AwayTime(hour: 8), now: at(21)), at(8, day: 26))
        XCTAssertEqual(end(AwayTime(hour: 12)), at(12))
        XCTAssertEqual(end(AwayTime(hour: 8, minute: 30)), at(20, 30))
    }
    func testAmPmAndTwentyFourHour() {
        XCTAssertEqual(end(AwayTime(hour: 3, pm: true)), at(15))
        XCTAssertEqual(end(AwayTime(hour: 15)), at(15))
        XCTAssertEqual(end(AwayTime(hour: 9, pm: false)), at(9, day: 26))
        XCTAssertEqual(end(AwayTime(hour: 7, part: .evening)), at(19))
    }
    func testPartOfDay() {
        XCTAssertEqual(end(AwayTime(part: .evening)), at(18))
        XCTAssertEqual(end(AwayTime(part: .morning)), at(8, day: 26))
        XCTAssertEqual(end(AwayTime(part: .noon)), at(12))
        // Already past today: tomorrow's.
        XCTAssertEqual(end(AwayTime(part: .evening), now: at(19)), at(18, day: 26))
    }
    func testNamedDays() {
        XCTAssertEqual(end(AwayTime(day: .tomorrow, part: .morning)), at(8, day: 26))
        XCTAssertEqual(end(AwayTime(hour: 9, day: .tomorrow)), at(9, day: 26))
        XCTAssertEqual(end(AwayTime(hour: 3, day: .tomorrow)), at(15, day: 26))
        XCTAssertEqual(end(AwayTime(day: .monday)), at(8, day: 30))
        // "Until Wednesday" on a Wednesday is next week.
        XCTAssertEqual(end(AwayTime(day: .wednesday)), cal.date(from: DateComponents(year: 2026, month: 12, day: 2, hour: 8)))
        XCTAssertEqual(end(AwayTime(hour: 5, day: .today)), at(17))
        XCTAssertNil(end(AwayTime(day: .today, part: .morning)))
    }
    func testGoodNightEndsInTheMorning() {
        XCTAssertEqual(end(AwayTime(day: .tomorrow, part: .night).forSleep, now: at(23)), at(8, day: 26))
        XCTAssertEqual(end(AwayTime(part: .morning).forSleep, now: at(23)), at(8, day: 26))
        XCTAssertEqual(AwayTime(hour: 7).forSleep, AwayTime(hour: 7))
        XCTAssertEqual(AwayTime().forSleep, AwayTime())
        XCTAssertEqual(AwayTime(day: .monday, part: .evening).forSleep, AwayTime(day: .monday, part: .morning))
    }
    func testSpokenLength() {
        XCTAssertEqual(AwayTime.spokenLength(180), "3 hours")
        XCTAssertEqual(AwayTime.spokenLength(60), "an hour")
        XCTAssertEqual(AwayTime.spokenLength(90), "an hour and a half")
        XCTAssertEqual(AwayTime.spokenLength(20), "20 minutes")
        XCTAssertEqual(AwayTime.spokenLength(135), "2 hours and 15 minutes")
    }
    func testSpokenEnd() {
        XCTAssertEqual(AwayTime.spokenEnd(at(15), now: at(10), calendar: cal), "3 p.m.")
        XCTAssertEqual(AwayTime.spokenEnd(at(12), now: at(10), calendar: cal), "noon")
        XCTAssertEqual(AwayTime.spokenEnd(at(8, day: 26), now: at(10), calendar: cal), "8 a.m. tomorrow")
        XCTAssertEqual(AwayTime.spokenEnd(at(8, 30, day: 30), now: at(10), calendar: cal), "8:30 a.m. on Monday")
    }
    func testConfirmation() {
        XCTAssertEqual(AwayTime.confirmation(goodNight: false, minutes: 180, end: at(13), now: at(10), calendar: cal),
                       "Okay. I'll take messages for 3 hours.")
        XCTAssertEqual(AwayTime.confirmation(goodNight: true, minutes: nil, end: at(8, day: 26), name: ", Sam", now: at(23), calendar: cal),
                       "Good night, Sam. Do not disturb until 8 a.m. tomorrow. I'll take messages until then.")
        XCTAssertEqual(AwayTime.confirmation(goodNight: false, minutes: nil, end: nil), "Okay. I'll keep the messages until you're back.")
    }
}
