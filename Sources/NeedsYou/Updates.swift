import AppKit
import Sparkle
import SwiftUI

/// In-app updates (HM-1366): Sparkle 2 with an EdDSA-signed appcast.
/// Release builds carry SUFeedURL and SUPublicEDKey in Info.plist; local
/// builds (scripts/install.sh) have neither and never update themselves.
///
/// Sparkle checks once a day. When it finds an update it does not pop a
/// window: the main window, Settings → General and the menu bar menu show
/// "Update to X" instead, and clicking it opens Sparkle's update dialog.
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    /// The version a check found, e.g. "1.3.0"; nil when up to date.
    @Published private(set) var available: String?
    @Published private(set) var canCheck = false

    private var controller: SPUStandardUpdaterController?

    /// True when this build has an appcast to check (release builds only).
    static var configured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["SUFeedURL"] != nil && info["SUPublicEDKey"] != nil
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    var enabled: Bool { controller != nil }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    func start() {
        guard Self.configured, controller == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheck)
    }

    /// "Check for Updates…" and the "Update" buttons.
    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        DispatchQueue.main.async { self.available = v }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { self.available = nil }
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled checks: let Sparkle show its window only when the app is in
    /// front anyway; otherwise the "Update" button waits in the app.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let v = update.displayVersionString
        DispatchQueue.main.async { self.available = v }
    }

    func standardUserDriverWillFinishUpdateSession() {}
}

extension Updates {
    /// Test hook `--update-check`: one check against the feed in Info.plist,
    /// prints the result as JSON and quits. Runs next to the installed app (no
    /// socket, no audio). With `--install` it downloads, verifies and installs
    /// the update when this process exits (no relaunch); use it on a throwaway
    /// copy only.
    static func cliCheck() -> Never {
        guard configured else {
            print(#"{"error":"this build has no SUFeedURL/SUPublicEDKey"}"#); exit(2)
        }
        let install = CommandLine.arguments.contains("--install")
        final class Probe: NSObject, SPUUpdaterDelegate, SPUUserDriver {
            let install: Bool
            init(install: Bool) { self.install = install }
            func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
                if install { return }
                Probe.finish(["status": "update", "version": item.displayVersionString, "build": item.versionString,
                              "url": item.fileURL?.absoluteString ?? ""])
            }
            func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
                Probe.finish(["status": "current", "detail": error.localizedDescription])
            }
            func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
                Probe.finish(["status": "error", "detail": error.localizedDescription], code: 1)
            }
            static func finish(_ o: [String: String], code: Int32 = 0) {
                let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
                print(String(decoding: d, as: UTF8.self)); exit(code)
            }
            // A silent user driver: answer every prompt with "not now".
            func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
                reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
            }
            func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
            func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
                reply(install ? .install : .dismiss)
            }
            func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
            func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
            func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
            func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
            func showDownloadInitiated(cancellation: @escaping () -> Void) {}
            func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
            func showDownloadDidReceiveData(ofLength length: UInt64) {}
            func showDownloadDidStartExtractingUpdate() {}
            func showExtractionReceivedProgress(_ progress: Double) {
                // Extracted and verified: the installer takes over when we exit.
                if install && progress >= 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Probe.finish(["status": "installing-on-exit"]) }
                }
            }
            /// Downloaded and verified: "not now" leaves the installer waiting
            /// for this process to exit, then it replaces the app.
            func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
                reply(.dismiss)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Probe.finish(["status": "installing-on-exit"]) }
            }
            func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
            func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
            func showUpdateInFocus() {}
            func dismissUpdateInstallation() {}
        }
        let probe = Probe(install: install)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: probe, delegate: probe)
        do { try updater.start() } catch {
            Probe.finish(["status": "error", "detail": error.localizedDescription], code: 1)
        }
        if install { updater.checkForUpdates() } else { updater.checkForUpdateInformation() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { Probe.finish(["status": "timeout"], code: 1) }
        withExtendedLifetime((probe, updater)) { RunLoop.main.run() }
        exit(0)
    }
}

/// "Update to X" button shown wherever an update is waiting.
struct UpdateButton: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        if let v = updates.available {
            Button("Update to \(v)") { updates.check() }
                .help("Needs You \(v) is available. You have \(updates.currentVersion).")
        }
    }
}

/// Settings → General: version, "Check for Updates…" and the update row.
struct UpdatesSection: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        Section {
            if let v = updates.available {
                LabeledContent("Needs You \(v) is available") {
                    Button("Update") { updates.check() }.buttonStyle(.borderedProminent)
                }
            }
            LabeledContent("Version \(updates.currentVersion)") {
                Button("Check for Updates\u{2026}") { updates.check() }
                    .disabled(!updates.canCheck)
            }
        } footer: {
            if !updates.enabled {
                Text("This build was made on this Mac and does not update itself.").foregroundStyle(.secondary)
            } else {
                Text("Needs You checks for updates once a day.").foregroundStyle(.secondary)
            }
        }
    }
}
