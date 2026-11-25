import AppKit
import NeedsYouShared
import SwiftUI

// MARK: - Dock and menu bar (HM-1356)

/// Where Needs You shows itself: the Dock (a normal app with a main menu) and/or
/// the menu bar. At least one stays on.
@MainActor
enum AppPresence {
    static let dockKey = "showInDock"
    static let menuBarKey = "showInMenuBar"

    static var showInDock: Bool { UserDefaults.standard.bool(forKey: dockKey) }
    static var showInMenuBar: Bool { UserDefaults.standard.bool(forKey: menuBarKey) }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [dockKey: true, menuBarKey: true, AgentsStore.enabledKey: true])
        if !showInDock && !showInMenuBar { UserDefaults.standard.set(true, forKey: menuBarKey) }
    }

    /// Dock on: a regular app (Dock icon, main menu). Off: menu bar only.
    static func apply() {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - Navigation shared by the window, the menus and the Dock

@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()

    enum Section: Hashable {
        case conversations, voicemails, chats
        case project(String)
    }

    @Published var section: Section? = .conversations
    @Published var conversation: String?
    @Published var voicemail: String?
    @Published var chat: String?

    /// Captured from the scene so AppKit callbacks (Dock click, Dock menu) can open windows.
    static var openWindowAction: OpenWindowAction?
    static var openSettingsAction: OpenSettingsAction?

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let a = openSettingsAction { a() } else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }

    func show(_ section: Section, conversation: String? = nil, voicemail: String? = nil) {
        self.section = section
        if let conversation { self.conversation = conversation }
        if let voicemail { self.voicemail = voicemail }
        Self.open("main")
    }

    static func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == id && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: id)
        }
    }
}

// MARK: - Main menu

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var dnd = DoNotDisturb.shared
    @ObservedObject private var nav = Nav.shared
    @ObservedObject private var updates = Updates.shared

    var body: some Commands {
        let _ = Nav.openWindowAction = openWindow
        let _ = Nav.openSettingsAction = openSettings
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { updates.check() }
                .disabled(!updates.canCheck)
        }
        CommandGroup(replacing: .newItem) {
            Button("Play Voicemails") { Task { await Conductor.shared.playVoicemails(greeting: nil, summary: false) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(dnd.unheard.isEmpty)
            Toggle("Do Not Disturb", isOn: Binding(get: { dnd.on }, set: { dnd.set($0) }))
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        CommandGroup(before: .sidebar) {
            Button("Conversations") { nav.show(.conversations) }.keyboardShortcut("1")
            Button("Voicemails") { nav.show(.voicemails) }.keyboardShortcut("2")
            Button("Chats") { nav.show(.chats) }.keyboardShortcut("3")
            Divider()
        }
        CommandGroup(before: .windowList) {
            Button("Needs You") { Nav.open("main") }.keyboardShortcut("0")
            Button("Training") { Nav.open("training") }.keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Needs You Help") { NSWorkspace.shared.open(AppHelp.readme) }
            Button("Agent Instructions") { NSWorkspace.shared.open(AgentsStore.shared.model.fileURL) }
        }
    }
}

enum AppHelp {
    static var readme: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/needs-you/README.md")
    }
}

// MARK: - Dock menu

/// Control-click on the Dock icon: the switches used most.
@MainActor
enum DockMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        let dnd = DoNotDisturb.shared
        let voice = VoiceCommands.shared
        menu.addItem(BlockItem(MenuStatus.line(), enabled: false) {})
        menu.addItem(.separator())
        menu.addItem(BlockItem("Do Not Disturb", checked: dnd.on) { dnd.set(!dnd.on) })
        let n = dnd.unheard.count
        menu.addItem(BlockItem(n > 0 ? "Play Voicemails (\(n))" : "No Voicemails", enabled: n > 0) {
            Task { await Conductor.shared.playVoicemails(greeting: nil, summary: false) }
        })
        menu.addItem(BlockItem("Listen for \u{201C}\(Wake.phrase)\u{201D}", checked: voice.enabled) { voice.enabled.toggle() })
        return menu
    }

    final class BlockItem: NSMenuItem {
        private let run: () -> Void
        init(_ title: String, checked: Bool = false, enabled: Bool = true, _ run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: enabled ? #selector(fire) : nil, keyEquivalent: "")
            target = self
            state = checked ? .on : .off
            isEnabled = enabled
        }
        required init(coder: NSCoder) { fatalError() }
        @objc private func fire() { MainActor.assumeIsolated { run() } }
    }
}

// MARK: - Status line (menu, Dock menu, window)

@MainActor
enum MenuStatus {
    static func line() -> String {
        let c = Conductor.shared, dnd = DoNotDisturb.shared, voice = VoiceCommands.shared
        if let convo = c.current {
            let who = convo.source
            switch c.phase {
            case .speaking: return "Speaking to \(who)"
            case .listening: return "Listening to you for \(who)"
            case .transcribing: return "Writing down your answer"
            case .publishing: return "Publishing an artifact"
            case .idle: return "Talking with \(who)"
            }
        }
        if dnd.on {
            let since = dnd.state.since.map { " since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return (dnd.state.goodNight ? "Good Night" : "Do Not Disturb") + since
        }
        if voice.capturing { return "Listening to you" }
        if voice.enabled { return voice.armed ? "Listening for \u{201C}\(Wake.phrase)\u{201D}" : "Hey Claude: \(voice.status)" }
        return "Ready"
    }

    static var symbol: String {
        let c = Conductor.shared
        if c.current != nil || c.phase != .idle { return c.menuSymbol }
        if DoNotDisturb.shared.on { return "moon.fill" }
        if VoiceCommands.shared.enabled { return "ear" }
        return "checkmark.circle"
    }
}

extension Conversation {
    /// The chat or project it came from: the agent's folder, else --project.
    var source: String {
        if kind == "send", let target { return target }
        if let cwd, let last = cwd.split(separator: "/").last, cwd != NSHomeDirectory() { return String(last) }
        return project ?? "Agent"
    }

    var outcomeText: String {
        switch outcome {
        case .open: return "Open"
        case .answered: return "Answered"
        case .done: return turns.contains { $0.role == .user } ? "Answered" : "Ended"
        case .noAnswer: return "No answer"
        case .error: return "Error"
        case .sent: return "Sent"
        case .cancelled: return "Not sent"
        case .queued: return "Queued"
        case .delivered: return "Delivered"
        }
    }

    var kindText: String {
        switch kind {
        case "send": return "Sent by voice"
        case "voicemail": return "Voicemail"
        default: return "Ask"
        }
    }

    var transcriptText: String {
        ([title] + turns.map { "\($0.role == .agent ? source : "You"): \($0.text)" }).joined(separator: "\n\n")
    }
}

// MARK: - Agent instructions (HM-1355)

@MainActor
final class AgentsStore: ObservableObject {
    static let shared = AgentsStore()
    static let enabledKey = "agentInstructionsEnabled"

    @Published private(set) var status: AgentInstructions.Status?
    @Published private(set) var lastError: String?
    private(set) var model: AgentInstructions

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    private var recordKey: String { "agentInstructions:" + model.dir.path }
    /// The --ui-demo windows only touch these files when a test folder is set.
    private var mayWrite: Bool { !Prefs.readOnly || ProcessInfo.processInfo.environment["NEEDS_YOU_CLAUDE_DIR"] != nil }

    init() {
        model = AgentInstructions(dir: AgentInstructions.targetDir())
        if let d = UserDefaults.standard.data(forKey: recordKey), let r = try? JSONDecoder().decode(AgentInstructions.Record.self, from: d) {
            model.record = r
        }
    }

    /// On launch and when Settings → Agents opens.
    func sync() {
        guard mayWrite else { status = nil; return }
        model.defaultText = AgentInstructions.defaultText(name: UserName.value)
        if enabled {
            run { try $0.sync() }
        } else {
            status = model.status(enabled: false)
        }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { sync() } else { run { try $0.disable() }; status = model.status(enabled: false) }
    }

    func useNewDefault() { run { try $0.useNewDefault() } }
    func keepMine() { run { $0.keepMine() } }
    func removeLegacySection() { run { try $0.removeLegacySection() } }
    func diff() -> String { model.diff() }

    func edit() { NSWorkspace.shared.open(model.fileURL) }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([model.fileURL]) }

    private func run(_ body: (inout AgentInstructions) throws -> Void) {
        guard mayWrite else { return }
        do {
            try body(&model)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        if let d = try? JSONEncoder().encode(model.record) { UserDefaults.standard.set(d, forKey: recordKey) }
        status = model.status(enabled: enabled)
    }
}
