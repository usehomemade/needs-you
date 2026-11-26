import AppKit
import NeedsYouShared

/// The apps Needs You may send to, and the switches for them in Settings, Apps (HM-1415).
/// Kept in defaults: "chatApps.disabled" (ids turned off) and "chatApps.seen" (every app a
/// chat ran in, so a terminal stays listed while none of its chats is open).
enum ChatApps {
    typealias App = ChatAppSwitches.App
    static let disabledKey = "chatApps.disabled"
    static let seenKey = "chatApps.seen"
    static let changed = Notification.Name("ChatApps.changed")

    static var disabled: Set<String> { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }

    static func isEnabled(_ id: String?) -> Bool { ChatAppSwitches.allows(id, disabled: disabled) }

    static func set(_ id: String, enabled: Bool) {
        var d = disabled
        if enabled { d.remove(id) } else { d.insert(id) }
        UserDefaults.standard.set(d.sorted(), forKey: disabledKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The app a connected chat belongs to (its herdr or tmux pane, else the app showing it).
    @MainActor static func owner(_ c: ChatInfo) -> App? {
        let host = c.pane == nil ? AXDelivery.guiApp(c.agentPid).flatMap(app) : nil
        let o = ChatAppSwitches.owner(pane: c.pane?.kind, host: host)
        if let o { remember(o) }
        return o
    }

    nonisolated static func app(_ r: NSRunningApplication) -> App? {
        guard let b = r.bundleIdentifier else { return nil }
        return App(id: b, name: r.localizedName ?? b, kind: .host)
    }

    private static var seen: [App] {
        guard let d = UserDefaults.standard.data(forKey: seenKey) else { return [] }
        return (try? JSONDecoder().decode([App].self, from: d)) ?? []
    }

    private static func remember(_ a: App) {
        guard !Prefs.readOnly else { return }
        var s = seen
        guard !s.contains(where: { $0.id == a.id }) else { return }
        s.append(a)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: seenKey) }
    }

    /// Everything to list in Settings: herdr when it is installed, every app a chat ran in,
    /// every chat app found by its layout. Uninstalled apps drop out; a turned-off one that
    /// is still installed stays, so it can be turned back on.
    @MainActor static var all: [App] {
        var apps: [App] = []
        if FileManager.default.isExecutableFile(atPath: Router.herdr) { apps.append(ChatAppSwitches.mux(.herdr)) }
        for c in ChatRegistry.shared.reachable { _ = owner(c) }
        apps += seen
        apps += (AppDiscovery.found + AppDiscovery.known).map { App(id: $0.bundle, name: $0.name, kind: .chatApp) }
        return ChatAppSwitches.list(apps).filter { a in
            a.kind == .mux || NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.id) != nil
        }
    }

    static func displayName(_ id: String) -> String {
        if let a = seen.first(where: { $0.id == id }) { return a.name }
        if let a = (AppDiscovery.found + AppDiscovery.known).first(where: { $0.bundle == id }) { return a.name }
        return id
    }
}
