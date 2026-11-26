import Foundation

/// How long he wants quiet (HM-1433): a length ("for three hours") or an end ("until 8",
/// "until tomorrow morning", "until Monday"). The on-device model fills the parts from his
/// words; this code turns them into a date against the local clock.
public struct AwayTime: Equatable, Sendable, CustomStringConvertible {
    public enum Day: String, CaseIterable, Sendable {
        case today, tomorrow, monday, tuesday, wednesday, thursday, friday, saturday, sunday
        /// Calendar weekday (Sunday = 1) for the named days.
        var weekday: Int? {
            switch self {
            case .sunday: return 1
            case .monday: return 2
            case .tuesday: return 3
            case .wednesday: return 4
            case .thursday: return 5
            case .friday: return 6
            case .saturday: return 7
            case .today, .tomorrow: return nil
            }
        }
    }
    public enum Part: String, CaseIterable, Sendable {
        case morning, noon, afternoon, evening, night
        /// When that part of the day starts (what "until the morning" means).
        var hour: Int {
            switch self {
            case .morning: return 8
            case .noon: return 12
            case .afternoon: return 13
            case .evening: return 18
            case .night: return 21
            }
        }
        /// Hours 1-12 said with it are in the afternoon or evening.
        var pm: Bool? {
            switch self {
            case .morning: return false
            case .noon: return nil
            case .afternoon, .evening, .night: return true
            }
        }
    }

    /// "for N minutes"
    public var minutes: Int?
    /// "until H[:MM]": 0-23, or 1-12 when he did not say a.m. or p.m.
    public var hour: Int?
    public var minute: Int?
    /// true p.m., false a.m., nil unsaid.
    public var pm: Bool?
    public var day: Day?
    public var part: Part?

    public init(minutes: Int? = nil, hour: Int? = nil, minute: Int? = nil, pm: Bool? = nil, day: Day? = nil, part: Part? = nil) {
        self.minutes = minutes.flatMap { $0 > 0 ? $0 : nil }
        self.hour = hour.flatMap { (0...24).contains($0) ? $0 % 24 : nil }
        self.minute = minute.flatMap { (0...59).contains($0) ? $0 : nil }
        self.pm = pm; self.day = day; self.part = part
    }

    public var isEmpty: Bool { minutes == nil && hour == nil && day == nil && part == nil }

    /// For logs and the dry run: "180 min", "until 8:30 pm tomorrow", "no time".
    public var description: String {
        if let m = minutes { return "\(m) min" }
        if isEmpty { return "no time" }
        var parts = ["until"]
        if let h = hour { parts.append("\(h)" + (minute.map { $0 > 0 ? String(format: ":%02d", $0) : "" } ?? "") + (pm.map { $0 ? " pm" : " am" } ?? "")) }
        if let d = day { parts.append(d.rawValue) }
        if let p = part { parts.append(p.rawValue) }
        return parts.joined(separator: " ")
    }

    /// Good night: a length or a clock time stays; "see you in the morning", "talk tomorrow" or
    /// "until Monday" all mean the morning after he wakes (that day's morning for a weekday).
    public var forSleep: AwayTime {
        if minutes != nil || hour != nil || isEmpty { return self }
        return AwayTime(day: day?.weekday != nil ? day : nil, part: .morning)
    }

    /// When it ends, or nil when he said no time. A length counts from `now`. An hour with no
    /// a.m./p.m. is the next one ahead ("until 8" at 9 p.m. is 8 a.m. tomorrow); a day with no
    /// time is its morning; a time already past today with no day is tomorrow.
    public func end(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        if let m = minutes { return now.addingTimeInterval(Double(m) * 60) }
        guard !isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        func at(_ dayStart: Date, _ h: Int) -> Date? {
            calendar.date(bySettingHour: h, minute: minute ?? 0, second: 0, of: dayStart)
        }
        /// The clock hours his words allow (one, or both halves of the day).
        var hours: [Int] {
            if let h = hour {
                if h >= 13 || h == 0 { return [h] }
                let said = pm ?? part?.pm
                if let said { return [said ? (h == 12 ? 12 : h + 12) : (h == 12 ? 0 : h)] }
                return h == 12 ? [12, 0] : [h, h + 12]
            }
            return [part?.hour ?? Part.morning.hour]
        }
        let named: Date? = {
            switch day {
            case .today?: return today
            case .tomorrow?: return calendar.date(byAdding: .day, value: 1, to: today)
            case let d? where d.weekday != nil:
                // The next such day, never today ("until Monday" on a Monday is next week).
                var c = DateComponents(); c.weekday = d.weekday
                return calendar.nextDate(after: now, matching: c, matchingPolicy: .nextTime).map { calendar.startOfDay(for: $0) }
            default: return nil
            }
        }()
        if let named {
            // On a named day an hour with no a.m./p.m. is the daytime one (7 to 6).
            let hs = hours
            let h = hs.count == 1 ? hs[0] : (hs[0] >= 7 ? hs[0] : hs[1])
            return at(named, h).flatMap { $0 > now ? $0 : nil }
        }
        let options = hours.flatMap { h in [at(today, h), calendar.date(byAdding: .day, value: 1, to: today).flatMap { at($0, h) }] }
        return options.compactMap { $0 }.filter { $0 > now }.min()
    }

    // MARK: Spoken

    /// "3 hours", "an hour and a half", "20 minutes".
    public static func spokenLength(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return minutes == 1 ? "a minute" : "\(minutes) minutes" }
        let hours = h == 1 ? "an hour" : "\(h) hours"
        if m == 0 { return hours }
        if m == 30 { return hours + " and a half" }
        return hours + " and \(m) minute\(m == 1 ? "" : "s")"
    }

    /// "3 p.m.", "8 a.m. tomorrow", "8 a.m. on Monday".
    public static func spokenEnd(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = calendar.component(.minute, from: d) == 0 ? "h a" : "h:mm a"
        var time = f.string(from: d).replacingOccurrences(of: "AM", with: "a.m.").replacingOccurrences(of: "PM", with: "p.m.")
        if calendar.component(.hour, from: d) == 12, calendar.component(.minute, from: d) == 0 { time = "noon" }
        if calendar.isDate(d, inSameDayAs: now) { return time }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) { return time + " tomorrow" }
        f.dateFormat = "EEEE"
        return time + " on " + f.string(from: d)
    }

    /// What it says when quiet starts.
    public static func confirmation(goodNight: Bool, minutes: Int?, end: Date?, name: String = "", now: Date = Date(), calendar: Calendar = .current) -> String {
        let hi = goodNight ? "Good night\(name)." : "Okay."
        if let m = minutes { return hi + " I'll take messages for \(spokenLength(m))." }
        if let end { return hi + " Do not disturb until \(spokenEnd(end, now: now, calendar: calendar)). I'll take messages until then." }
        return goodNight ? hi + " I'll keep the messages for the morning." : hi + " I'll keep the messages until you're back."
    }
}
