import AppKit
import ApplicationServices
import AVFoundation
import NeedsYouShared
import Security
import Speech

/// Opens System Settings on the page of a permission Needs You is missing right now
/// (HM-1405) and says on the island which switch to turn on. Each permission goes at
/// most once per 10 minutes (`PromptLimiter`), so a check that keeps failing never loops.
///
/// The app needs only these three: it sends no Apple Events (no Automation), its
/// shortcuts are Carbon hot keys (no Input Monitoring), it records no screen and it
/// shows no notifications (the island is its only surface, HM-1363).
@MainActor
enum PermissionSettings {
    enum Permission: String, CaseIterable, Identifiable {
        case accessibility, microphone, speechRecognition

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .microphone: return "Microphone"
            case .speechRecognition: return "Speech Recognition"
            }
        }

        /// What it is for, one line for Settings.
        var use: String {
            switch self {
            case .accessibility: return "Types your voice messages into chats and finds them in their apps."
            case .microphone: return "Hears your answers and \u{201C}\(Wake.phrase)\u{201D}."
            case .speechRecognition: return "Hears \u{201C}\(Wake.phrase)\u{201D} on this Mac."
            }
        }

        var url: URL {
            let anchor: String
            switch self {
            case .accessibility: anchor = "Privacy_Accessibility"
            case .microphone: anchor = "Privacy_Microphone"
            case .speechRecognition: anchor = "Privacy_SpeechRecognition"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor)!
        }

        var granted: Bool {
            switch self {
            case .accessibility: return AXIsProcessTrusted()
            case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .authorized
            }
        }

        /// Not asked yet: the system asks itself the first time it is used.
        var undecided: Bool {
            switch self {
            case .accessibility: return false
            case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .notDetermined
            }
        }

        /// Which switch to turn on, one line (the island and Settings).
        var fix: String {
            switch self {
            case .accessibility: return PermissionSettings.accessibilityAdvice.line
            case .microphone: return "Switch on Needs You in Microphone."
            case .speechRecognition: return "Switch on Needs You in Speech Recognition."
            }
        }
    }

    private static var limiter = PromptLimiter()
    private static let promptedKey = "axPrompted"
    nonisolated private static let trustedKey = "axTrustedBuild"

    /// Opens the page now and brings System Settings forward (Settings buttons).
    static func open(_ p: Permission) {
        NSWorkspace.shared.open(p.url)
        // Usually forward already; make sure when Needs You itself is in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.activate()
        }
    }

    /// Something needs `p` right now and it is off: say which switch on the island and
    /// open its page, at most once per 10 minutes. Accessibility's first time ever also
    /// asks the system to prompt, which puts Needs You in the list so it has a switch.
    static func needs(_ p: Permission) {
        guard !Prefs.readOnly, !p.granted, !p.undecided, limiter.allow(p.rawValue) else { return }
        Isolation.note("permissions: \(p.rawValue) is off, opening its System Settings page")
        Island.shared.error("\(p.title) is off", p.fix)
        if p == .accessibility, !UserDefaults.standard.bool(forKey: promptedKey) {
            UserDefaults.standard.set(true, forKey: promptedKey)
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        open(p)
    }

    /// At launch: Accessibility is what every typed message needs. Remembers the build it
    /// was trusted with, so after an update the island can say "off and on again".
    static func launchCheck() {
        guard !Prefs.readOnly else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if noteAccessibility() { return }
            needs(.accessibility)
            watchForGrant()
        }
    }

    /// Records this build as trusted when it is. True when trusted.
    @discardableResult
    static func noteAccessibility() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if let b = build, UserDefaults.standard.string(forKey: trustedKey) != b {
            UserDefaults.standard.set(b, forKey: trustedKey)
        }
        return true
    }

    nonisolated static var accessibilityAdvice: AccessibilityAdvice {
        AccessibilityAdvice.advice(trustedBuild: UserDefaults.standard.string(forKey: trustedKey), build: build)
    }

    /// For two minutes after the page opened: note the grant as soon as it comes.
    private static func watchForGrant() {
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if noteAccessibility() { Isolation.note("permissions: accessibility allowed"); return }
            }
        }
    }

    /// This binary's code hash: a new version or a re-signed build has another one.
    nonisolated static let build: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let d = info as? [String: Any], let hash = d[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }()
}
