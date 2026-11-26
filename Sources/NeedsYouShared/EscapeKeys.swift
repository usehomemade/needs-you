import Foundation

/// What Escape means (HM-1429): once = close, twice quickly = reset.
///
/// - Close: stop listening or speaking now and fold the pill away. What he said so
///   far is kept, not sent (history: not sent; "Hey Mac, <chat>" sends it later), an
///   agent's question waits as a voicemail.
/// - Reset: a second press within `window` of the first cancels everything in
///   flight and drops what the close kept; back to listening for the wake phrase.
///
/// A close is only final once the window has passed without a second press, so its
/// callers ask `outcome(of:at:)` before they keep anything.
public struct EscapeKeys: Sendable {
    public enum Press: String, Equatable, Sendable { case close, reset }

    public static let window: TimeInterval = 0.5

    /// The last press that closed (nil after a reset used it up).
    public private(set) var closedAt: Date?
    /// The last reset.
    public private(set) var resetAt: Date?

    public init() {}

    public mutating func press(at now: Date) -> Press {
        if let c = closedAt, now.timeIntervalSince(c) < Self.window, now >= c {
            closedAt = nil
            resetAt = now
            return .reset
        }
        closedAt = now
        return .close
    }

    /// What the close at `close` turned into, at `now`: `.reset` once a second press
    /// came, `.close` once the window passed without one, nil while it may still come.
    public func outcome(of close: Date, at now: Date) -> Press? {
        if let r = resetAt, r >= close, r.timeIntervalSince(close) < Self.window { return .reset }
        return now.timeIntervalSince(close) >= Self.window ? .close : nil
    }
}
