import AppKit
import NeedsYouShared
import ServiceManagement
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--update-check") { Updates.cliCheck() }
        if args.contains("--download-models") {
            // Install step: fetch and compile the local speech models once.
            var finished = false
            var failed = false
            Task.detached {
                do {
                    try await ModelPrefetch.downloadAll()
                    UserDefaults.standard.set(true, forKey: ModelPrefetch.doneKey)
                    print("local speech models ready")
                } catch {
                    print("model download failed: \(error.localizedDescription)"); failed = true
                }
                finished = true
            }
            // Spin the main run loop: model loading may hop to the main actor.
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            exit(failed ? 1 : 0)
        }
        if let i = args.firstIndex(of: "--tts-test") {
            // Test hook (HM-1368): NeedsYou --tts-test "<text>" [--tts-out file] [--title <voice>|fallback]
            // [--download <codes>|--wait-download]. Synthesizes in this process (no socket, nothing
            // plays), prints the tts-test JSON. --download tr,de fetches those native voices first;
            // --wait-download waits for a first-use download the line started.
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
            var req = Request(command: .tts)
            req.text = args.indices.contains(i + 1) ? args[i + 1] : ""
            req.ttsOut = value("--tts-out")
            req.context = value("--title")
            let downloads = VoiceRouting.parse(value("--download"))
            let waitDownload = args.contains("--wait-download")
            let repeats = value("--repeat").flatMap { Int($0) } ?? 1
            var finished = false
            Task.detached {
                for code in downloads { await NativeVoices.shared.download(code) }
                // --repeat <n>: synthesize n times (warm latency in state).
                for _ in 0..<max(1, repeats) {
                    let r = await Conductor.ttsTest(req)
                    if let data = try? LineIO.encoder.encode(r) { print(String(decoding: data, as: UTF8.self)) }
                }
                if waitDownload {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    while await NativeVoices.shared.downloading != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
                    print("download: \(await NativeVoices.shared.lastError ?? "done")")
                }
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            exit(0)
        }
        if args.contains("--overlay-demo") {
            // Test hook: the subtitle overlay and glow with sample text, no audio, no
            // socket (runs next to the installed app), then quits.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                await Subtitles.shared.demo()
                // --idle-after <s>: stay hidden that long (to measure the idle cost).
                let idle = args.firstIndex(of: "--idle-after").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 1.5
                try? await Task.sleep(nanoseconds: UInt64(idle * 1e9))
                exit(0)
            }
            app.run()
        }
        if args.contains("--island-demo") {
            // Test hook: the notch island steps through every state with fake levels,
            // no audio, no socket (runs next to the installed app), then quits.
            //   --island-style automatic|notch|external   (default: the Settings choice)
            //   --idle-after <s>                          stay hidden that long (idle cost)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            if let i = args.firstIndex(of: "--island-style"), args.indices.contains(i + 1) {
                Island.Style.override = Island.Style(rawValue: args[i + 1]) // not saved
            }
            Task { @MainActor in
                await Island.shared.demo()
                let idle = args.firstIndex(of: "--idle-after").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 0.5
                try? await Task.sleep(nanoseconds: UInt64(idle * 1e9))
                exit(0)
            }
            app.run()
        }
        if args.contains("--ui-demo") {
            // Test hook: the windows and menus without the socket, the mic or any
            // audio, next to the installed app. Reads the app's settings and files,
            // writes nothing (see UIDemo).
            Prefs.readOnly = true
            if let real = UserDefaults.standard.persistentDomain(forName: Wire.bundleID) {
                UserDefaults.standard.register(defaults: real)
            }
        }
        NeedsYouApp.main()
    }
}

struct NeedsYouApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var conductor = Conductor.shared
    @AppStorage(AppPresence.menuBarKey) private var showInMenuBar = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuContent().environmentObject(conductor)
        } label: {
            MenuBarLabel().environmentObject(conductor)
        }

        Window("Needs You", id: "main") {
            MainView()
                .environmentObject(conductor)
                .frame(minWidth: 760, minHeight: 460)
        }
        .defaultSize(width: 980, height: 620)
        // Listed once, by AppCommands with its shortcut; SwiftUI would list every Window again.
        .commandsRemoved()
        .commands { AppCommands() }

        Window("Welcome to Needs You", id: "name") {
            UserNamePrompt()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("Training", id: "training") {
            TrainingView()
        }
        .defaultSize(width: 680, height: 720)
        .commandsRemoved()

        Window("Router Debug", id: "debug") {
            DebugView()
        }
        .defaultSize(width: 820, height: 680)
        .commandsRemoved()

        Settings {
            SettingsView().environmentObject(conductor)
        }
    }
}

/// The menu bar icon, with a small dot while the mic is open for "Hey Claude".
struct MenuBarLabel: View {
    @EnvironmentObject var conductor: Conductor
    @ObservedObject var voice = VoiceCommands.shared
    @ObservedObject var dnd = DoNotDisturb.shared

    var body: some View {
        let symbol = voice.capturing ? "mic.fill" : (dnd.on && conductor.phase == .idle ? "moon.zzz" : conductor.menuSymbol)
        if voice.armed || voice.capturing {
            Image(nsImage: Self.withDot(symbol))
        } else {
            Image(systemName: symbol)
        }
    }

    static func withDot(_ symbol: String) -> NSImage {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Needs You")!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!
        let size = NSSize(width: base.size.width + 6, height: base.size.height)
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width - 5, y: size.height - 5, width: 5, height: 5)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Needs You, listening for \(Wake.phrase)"
        return img
    }
}

extension Conductor {
    var menuSymbol: String {
        switch phase {
        case .idle: return current == nil ? "waveform" : "bubble.left.and.text.bubble.right"
        case .speaking: return "speaker.wave.2.fill"
        case .listening: return "mic.fill"
        case .transcribing: return "text.bubble"
        case .publishing: return "arrow.up.doc"
        }
    }
}

/// The menu bar menu (HM-1356): what is going on, then the switches he uses most.
struct MenuContent: View {
    @EnvironmentObject var conductor: Conductor
    @ObservedObject private var voice = VoiceCommands.shared
    @ObservedObject private var dnd = DoNotDisturb.shared
    @ObservedObject private var updates = Updates.shared
    @AppStorage(Wake.defaultsKey) private var wakePhrase = WakeMatcher.defaultPhrase
    @AppStorage("micUID") private var micUID = ""
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(MenuStatus.line())
        if conductor.queued > 0 { Text("\(conductor.queued) more waiting") }
        if let e = conductor.lastError { Text(e) }
        if conductor.phase == .listening {
            Button("Stop Listening") { conductor.stop() }
        }
        Divider()
        Toggle(dnd.state.goodNight && dnd.on ? "Do Not Disturb (Good Night)" : "Do Not Disturb",
               isOn: Binding(get: { dnd.on }, set: { dnd.set($0) }))
        voicemails
        recent
        Divider()
        Toggle("Listen for \u{201C}\(WakeMatcher(phrase: wakePhrase).phrase)\u{201D}", isOn: $voice.enabled)
        microphones
        Divider()
        Button("Open Needs You") { Nav.open("main") }
            .keyboardShortcut("o")
        UpdateButton()
        Button("Settings\u{2026}") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        if updates.enabled {
            Button("Check for Updates\u{2026}") { updates.check() }
                .disabled(!updates.canCheck)
        }
        Divider()
        Button("Quit Needs You") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var voicemails: some View {
        let list = dnd.unheard
        if list.isEmpty {
            Button("No Voicemails") {}.disabled(true)
        } else {
            Menu("Voicemails (\(list.count))") {
                Button("Play All") { Task { await conductor.playVoicemails(greeting: nil, summary: false) } }
                    .disabled(conductor.busy)
                Divider()
                ForEach(list.prefix(10)) { v in
                    Button("\(v.at.formatted(date: .omitted, time: .shortened))  \(v.source): \(Self.short(v.text))") {
                        Task { await conductor.playVoicemails(greeting: nil, summary: false, only: [v.id]) }
                    }
                    .disabled(conductor.busy)
                }
                if list.count > 10 { Text("\(list.count - 10) more") }
                Divider()
                Button("Show Voicemails\u{2026}") { Nav.shared.show(.voicemails) }
            }
        }
    }

    @ViewBuilder private var recent: some View {
        let list = Array(conductor.history.prefix(5))
        Menu("Recent Conversations") {
            if list.isEmpty { Text("No Conversations") }
            ForEach(list) { c in
                Button("\(c.source): \(Self.short(c.title))") { Nav.shared.show(.conversations, conversation: c.id) }
            }
            Divider()
            Button("Show All Conversations\u{2026}") { Nav.shared.show(.conversations) }
        }
    }

    @ViewBuilder private var microphones: some View {
        Menu("Microphone") {
            Picker("Microphone", selection: $micUID) {
                Text("System Default").tag("")
                ForEach(AudioDevices.inputs()) { m in Text(m.name).tag(m.id) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle(voice.phoneInUse.map { "Also Use iPhone Mic (\($0))" } ?? "Also Use iPhone Mic", isOn: $voice.phoneMic)
        }
    }

    static func short(_ s: String, _ n: Int = 48) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count > n ? String(t.prefix(n)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : t
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Prefs.registerDefaults()
        AppPresence.registerDefaults()
        AppPresence.apply()
        if Prefs.readOnly { UIDemo.start(); return }
        // Cues in memory before the first wake (HM-1344: the chime is latency-critical).
        DispatchQueue.global(qos: .userInitiated).async { Sounds.shared.preload() }
        AgentsStore.shared.sync()
        AgentConnect.shared.refreshClaudeHooks()
        AppDiscovery.start()
        PermissionVoice.shared.sync() // HM-1369: only acts when turned on in Settings → Agents
        do {
            try Server.shared.start()
            Updates.shared.start()
            ModelPrefetch.runIfNeeded()
            if UserName.value == nil && !UserDefaults.standard.bool(forKey: UserName.askedKey) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Nav.open("name") }
            }
        } catch Server.StartError.alreadyRunning {
            NSApp.terminate(nil)
        } catch {
            Conductor.shared.lastError = "Could not open the socket: \(error)"
        }
        Island.shared.attach()
        VoiceCommands.shared.setUp()
        Hotkeys.shared.setUp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !Prefs.readOnly { Server.shared.stop() }
    }

    /// Dock icon clicked with no window open: open the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Nav.open("main") }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { DockMenu.make() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
