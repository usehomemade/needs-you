import AppKit
import os

/// Chat apps found by their layout, not by name (HM-1394, the owner: "another ADE or IDE, or
/// Orca: they should just be ready"): any running app whose window has a message field
/// beside a column of chats. Checked at launch, when an app launches or comes to the
/// front, and every 5 minutes; the router reads the last result without waiting.
enum AppDiscovery {
    struct Found: Sendable, Hashable { var bundle: String; var name: String }

    private static let store = OSAllocatedUnfairLock<[String: Found]>(initialState: [:])
    static var found: [Found] { store.withLock { $0.values.sorted { $0.name < $1.name } } }

    @MainActor private static var timer: Timer?

    @MainActor static func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in refresh() } }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundle = app?.bundleIdentifier, title = app?.localizedName ?? ""
                if name == NSWorkspace.didTerminateApplicationNotification {
                    if let bundle { _ = store.withLock { $0.removeValue(forKey: bundle) } }
                    return
                }
                guard let bundle, app?.activationPolicy == .regular else { return }
                // A new window takes a moment to lay out.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (name == NSWorkspace.didLaunchApplicationNotification ? 6 : 1.5)) {
                    check(bundle, name: title)
                }
            }
        }
    }

    @MainActor static func refresh() {
        let mine = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != mine }
            .map { ($0.bundleIdentifier!, $0.localizedName ?? "") }
        DispatchQueue.global(qos: .utility).async {
            for (b, n) in apps { check(b, name: n) }
        }
    }

    /// Reads one app and keeps or drops it. A web app's first read is often empty: its
    /// tree is built only once something asks, so it is read again a moment later.
    nonisolated static func check(_ bundle: String, name: String) {
        guard var scan = AXDelivery.scanApp(bundle) else { return }
        if scan.nodes < 40 {
            Thread.sleep(forTimeInterval: 1.5)
            scan = AXDelivery.scanApp(bundle) ?? scan
        }
        let isChat = scan.hasField // message field below a chat column (ChatListFinder.isChatLayout)
        store.withLock { $0[bundle] = isChat ? Found(bundle: bundle, name: name) : nil }
    }
}
