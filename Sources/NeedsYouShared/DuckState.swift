import Foundation

/// When other audio (music, videos) should be lowered while he talks (HM-1413).
///
/// Each reason to lower it is a named holder ("command:mac", "answer"). Holding the
/// same name twice counts once, so a second hold never ducks twice; the audio comes
/// back only when the last holder lets go, and then after a short linger, so the gap
/// between his command and the "which chat?" that follows does not bounce the music.
///
/// While Needs You's own voice plays, its player already lowers other audio (Apple's
/// voice processing): the ducker steps aside then (`voicePlaying`) and takes over again
/// after, if he still holds the floor.
public struct DuckState: Equatable {
    /// Holder name -> when it began (seconds, any clock).
    public private(set) var holders: [String: Double] = [:]
    public private(set) var voicePlaying = false
    /// Set when the last holder let go: other audio stays lowered until then.
    public private(set) var lingerUntil: Double?
    public let linger: Double
    /// A holder older than this is dropped (a missed release never keeps audio low).
    public let maxHold: Double

    public init(linger: Double = 1.2, maxHold: Double = 300) {
        self.linger = linger
        self.maxHold = maxHold
    }

    public mutating func hold(_ who: String, now: Double) {
        if holders[who] == nil { holders[who] = now }
        lingerUntil = nil
    }

    public mutating func release(_ who: String, now: Double) {
        guard holders.removeValue(forKey: who) != nil else { return }
        if holders.isEmpty { lingerUntil = now + linger }
    }

    /// Everything lets go at once, no linger (switched off in Settings).
    public mutating func releaseAll() {
        holders = [:]
        lingerUntil = nil
    }

    public mutating func voice(_ playing: Bool) { voicePlaying = playing }

    /// Drops holders past `maxHold` and a finished linger.
    public mutating func expire(now: Double) {
        let stale = holders.filter { now - $0.value >= maxHold }.map(\.key)
        for k in stale { release(k, now: now) }
        if let l = lingerUntil, now >= l { lingerUntil = nil }
    }

    /// He holds the floor (or just did, within the linger).
    public func wantsDuck(now: Double) -> Bool {
        if !holders.isEmpty { return true }
        if let l = lingerUntil { return now < l }
        return false
    }

    /// The ducker's own engine runs: he holds the floor and the voice is not already ducking.
    public func engineOn(now: Double) -> Bool { !voicePlaying && wantsDuck(now: now) }

    /// When the answer of `engineOn` can next change without a call (linger end, oldest holder expiring).
    public func nextChange(now: Double) -> Double? {
        var times: [Double] = []
        if let l = lingerUntil, l > now { times.append(l) }
        if let oldest = holders.values.min() { times.append(oldest + maxHold) }
        return times.min()
    }
}
