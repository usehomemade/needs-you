import Foundation

/// At most one trip to System Settings per permission per 10 minutes (HM-1405), so a
/// check that runs again and again (every typed message, every mic start) never loops.
public struct PromptLimiter {
    public let interval: TimeInterval
    private var last: [String: Date] = [:]

    public init(interval: TimeInterval = 600) { self.interval = interval }

    /// True (and remembered) when `key` was not let through in the last `interval`.
    public mutating func allow(_ key: String, now: Date = Date()) -> Bool {
        if let t = last[key], now.timeIntervalSince(t) < interval { return false }
        last[key] = now
        return true
    }
}

/// What to tell the user when Accessibility is off (HM-1405). macOS keeps the switch
/// of the build that was trusted; after an update or a re-signed build that entry can
/// stay on in System Settings and still not count for the new one.
public enum AccessibilityAdvice: Equatable {
    /// This very build was trusted and the switch was turned off: turn it on.
    case turnOn
    /// An older build was trusted: turn the switch off and on again.
    case toggle
    /// Never seen trusted: turn it on (or, if it already shows on, off and on).
    case turnOnOrToggle

    /// `trustedBuild`: the code hash last seen trusted; `build`: this one's.
    public static func advice(trustedBuild: String?, build: String?) -> AccessibilityAdvice {
        guard let trustedBuild else { return .turnOnOrToggle }
        guard let build else { return .turnOnOrToggle }
        return trustedBuild == build ? .turnOn : .toggle
    }

    /// One short line for the island and Settings.
    public var line: String {
        switch self {
        case .turnOn: return "Switch on Needs You in Accessibility."
        case .toggle: return "Turn Needs You off and on again: the switch is for the old version."
        case .turnOnOrToggle: return "Switch on Needs You. Already on? Turn it off and on again."
        }
    }
}
