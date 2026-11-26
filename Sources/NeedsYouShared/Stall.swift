import Foundation

/// The main-thread watchdog's bookkeeping (HM-1418): when a stall is worth a line in the
/// log. The watchdog asks the main thread to answer about twice a second; `check` gets
/// how long the current request has waited. A stall is reported when it passes 2 s, again
/// at each longer threshold (so a stuck app leaves a trail, not one line), and once more
/// when the main thread answers again.
public struct StallWatch: Equatable {
    public enum Event: Equatable {
        /// Still blocked, for this many seconds (the n-th report of this stall, from 1).
        case blocked(seconds: Double, report: Int)
        /// It answered again after about this many seconds.
        case recovered(seconds: Double)
    }

    public let thresholds: [Double]
    private var reported = 0
    private var peak: Double = 0

    public init(thresholds: [Double] = [2, 10, 30, 120, 600]) {
        self.thresholds = thresholds.sorted()
    }

    /// `waited`: seconds the main thread has not answered (0 when it just did).
    public mutating func check(waited: Double) -> Event? {
        guard let first = thresholds.first else { return nil }
        if waited < first {
            guard reported > 0 else { peak = 0; return nil }
            let was = peak
            reported = 0; peak = 0
            return .recovered(seconds: was)
        }
        peak = max(peak, waited)
        // Past the last threshold: once more every time as much time has gone by again.
        let next = reported < thresholds.count ? thresholds[reported]
            : thresholds[thresholds.count - 1] * Double(reported - thresholds.count + 2)
        guard waited >= next else { return nil }
        reported += 1
        return .blocked(seconds: waited, report: reported)
    }
}

/// How much of an app's Accessibility tree one read may walk (HM-1418): a number of
/// elements and a deadline. A busy or hung app answers every element slowly (up to the
/// messaging timeout each); without a deadline a 5000-element walk of it never ends.
public struct WalkBudget: Equatable {
    public private(set) var nodes: Int
    public let deadline: TimeInterval
    /// The deadline passed before the walk was done.
    public private(set) var timedOut = false

    /// `now` and `deadline` on the same clock (`ProcessInfo.systemUptime`).
    public init(nodes: Int, seconds: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.nodes = nodes
        self.deadline = now + seconds
    }

    /// The same deadline, a fresh element count (the next window of the same app).
    public func next(nodes: Int) -> WalkBudget {
        var b = self
        b.nodes = nodes
        return b
    }

    /// One more element may be read.
    public mutating func take(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard nodes > 0, !timedOut else { return false }
        if now >= deadline { timedOut = true; return false }
        nodes -= 1
        return true
    }
}
