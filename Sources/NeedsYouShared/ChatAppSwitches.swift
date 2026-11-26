import Foundation

/// Which apps Needs You may send to (HM-1415): one person only uses a terminal, another
/// only a chat app. Each chat belongs to exactly one app: the herdr or tmux pane it runs
/// in (that pane is what gets selected and typed into), else the app that shows it
/// (a terminal, an editor, a chat app). A turned-off app's chats are no router target and
/// nothing is typed into them.
public enum ChatAppSwitches {
    public struct App: Codable, Equatable, Hashable, Sendable, Identifiable {
        /// mux: herdr or tmux. host: the app a connected chat runs in. chatApp: found by its layout.
        public enum Kind: String, Codable, Sendable, CaseIterable { case mux, host, chatApp }
        /// A bundle id, or "herdr" / "tmux".
        public var id: String
        public var name: String
        public var kind: Kind

        public init(id: String, name: String, kind: Kind) {
            self.id = id; self.name = name; self.kind = kind
        }
    }

    public static func muxID(_ kind: PaneRef.Kind) -> String { kind.rawValue }

    public static func mux(_ kind: PaneRef.Kind) -> App {
        App(id: muxID(kind), name: kind.rawValue, kind: .mux)
    }

    /// The app a chat belongs to: its pane's multiplexer when it runs in one, else the app
    /// that shows it. nil when neither is known.
    public static func owner(pane: PaneRef.Kind?, host: App?) -> App? {
        if let pane { return mux(pane) }
        return host
    }

    /// An app nobody can name (no pane, no host found) is not blocked: nothing can be typed
    /// into it anyway, and its chats still get messages through their hooks.
    public static func allows(_ id: String?, disabled: Set<String>) -> Bool {
        guard let id else { return true }
        return !disabled.contains(id)
    }

    /// The Settings list: each app once (the first kind it was seen as wins, multiplexers
    /// first, then the apps chats run in, then chat apps), by name within a kind.
    public static func list(_ apps: [App]) -> [App] {
        var seen = Set<String>(), out: [App] = []
        for k in App.Kind.allCases {
            for a in apps where a.kind == k && !a.name.isEmpty && seen.insert(a.id).inserted { out.append(a) }
        }
        return out.sorted {
            let (i, j) = (App.Kind.allCases.firstIndex(of: $0.kind)!, App.Kind.allCases.firstIndex(of: $1.kind)!)
            return i != j ? i < j : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
