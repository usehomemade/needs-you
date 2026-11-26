import AppKit
import NeedsYouShared
import ServiceManagement
import SwiftUI

// MARK: - Settings (HM-1356)

/// A toolbar of panes, as the HIG asks for an app's settings window. The window
/// title follows the pane and the last pane opens again next time.
struct SettingsView: View {
    enum Pane: String, CaseIterable {
        case general, permissions, wake, voice, microphones, models, doNotDisturb, agents, apps
    }

    @AppStorage("settingsPane") private var pane = Pane.general.rawValue

    var body: some View {
        TabView(selection: $pane) {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }.tag(Pane.general.rawValue)
            PermissionsPane()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(Pane.permissions.rawValue)
            WakePane()
                .tabItem { Label(Wake.phrase, systemImage: "waveform") }.tag(Pane.wake.rawValue)
            VoicePane()
                .tabItem { Label("Voice", systemImage: "speaker.wave.2") }.tag(Pane.voice.rawValue)
            MicrophonesPane()
                .tabItem { Label("Microphones", systemImage: "mic") }.tag(Pane.microphones.rawValue)
            ModelsPane()
                .tabItem { Label("Models", systemImage: "cpu") }.tag(Pane.models.rawValue)
            DoNotDisturbPane()
                .tabItem { Label("Do Not Disturb", systemImage: "moon") }.tag(Pane.doNotDisturb.rawValue)
            AgentsPane()
                .tabItem { Label("Agents", systemImage: "terminal") }.tag(Pane.agents.rawValue)
            AppsPane()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }.tag(Pane.apps.rawValue)
        }
        .frame(width: 660) // nine panes fit the toolbar without an overflow menu
    }
}

/// One pane: a grouped form sized to its content.
private struct Pane<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 660, height: height)
    }
}

// MARK: General

struct GeneralPane: View {
    @AppStorage(AppPresence.dockKey) private var showInDock = true
    @AppStorage(AppPresence.menuBarKey) private var showInMenuBar = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var note: String?

    var body: some View {
        Pane(height: 560) {
            UserNameSection()
            Section {
                Toggle("Show in Dock", isOn: $showInDock)
                    .disabled(showInDock && !showInMenuBar)
                    .onChange(of: showInDock) { _, _ in AppPresence.apply() }
                Toggle("Show in Menu Bar", isOn: $showInMenuBar)
                    .disabled(showInMenuBar && !showInDock)
            } footer: {
                Text("With the Dock icon on, Needs You has its own menus and a window you can open from the Dock. At least one of the two stays on.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open at Login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in setLogin(on) }
                LabeledContent("Speech", value: "On this Mac (Parakeet, Kokoro, Supertonic, Whisper)")
            } footer: {
                if let note { Text(note).foregroundStyle(.red) }
            }
            UpdatesSection()
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            note = nil
        } catch {
            note = "Open at Login: \(error.localizedDescription)"
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: Permissions (HM-1405)

/// Every permission Needs You needs, checked live: when the window comes to the front
/// and every 2 seconds while the pane shows. Missing ones come first, each with a
/// button to its own System Settings page.
struct PermissionsPane: View {
    @State private var granted: [PermissionSettings.Permission: Bool] = [:]
    @State private var advice = PermissionSettings.accessibilityAdvice
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var ordered: [PermissionSettings.Permission] {
        let all = PermissionSettings.Permission.allCases
        return all.filter { granted[$0] == false } + all.filter { granted[$0] != false }
    }

    var body: some View {
        Pane(height: 420) {
            Section {
                ForEach(ordered) { p in row(p) }
            } footer: {
                Text("Needs You sends no Apple Events to other apps, needs no Input Monitoring for its shortcuts, records no screen and shows no notifications, so it never asks for Automation, Input Monitoring, Screen Recording or Notifications.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    @ViewBuilder private func row(_ p: PermissionSettings.Permission) -> some View {
        let ok = granted[p] ?? p.granted
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).fontWeight(ok ? .regular : .semibold)
                Text(ok ? p.use : (p == .accessibility ? advice.line : p.fix) + " " + p.use)
                    .font(.caption).foregroundStyle(ok ? Color.secondary : Color.orange)
            }
            Spacer()
            Button(ok ? "Open\u{2026}" : "Open Settings\u{2026}") { PermissionSettings.open(p) }
                .help("Opens System Settings, Privacy & Security, \(p.title)")
        }
    }

    private func refresh() {
        PermissionSettings.noteAccessibility()
        advice = PermissionSettings.accessibilityAdvice
        var g: [PermissionSettings.Permission: Bool] = [:]
        for p in PermissionSettings.Permission.allCases { g[p] = p.granted }
        if g != granted { granted = g }
    }
}

// MARK: Hey Mac

struct WakePane: View {
    @ObservedObject private var conductor = Conductor.shared
    @ObservedObject private var voice = VoiceCommands.shared
    @AppStorage(Wake.defaultsKey) private var wakePhrase = WakeMatcher.defaultPhrase
    @State private var phraseDraft: String?

    private var phrase: String { WakeMatcher(phrase: wakePhrase).phrase }

    var body: some View {
        Pane(height: 600) {
            Section {
                Toggle("Listen for \u{201C}\(phrase)\u{201D}", isOn: $voice.enabled)
                LabeledContent("Status", value: voice.status)
                if voice.enabled && !voice.speechAllowed {
                    Button("Open Speech Recognition Settings\u{2026}") {
                        PermissionSettings.open(.speechRecognition)
                    }
                }
            } footer: {
                Text("Say \u{201C}\(phrase), <chat name>: <message>\u{201D}, or \u{201C}\(phrase), this one: <message>\u{201D} for the chat in front. Speech stays on this Mac until you say \u{201C}\(phrase)\u{201D}. \u{201C}Stop, \(WakeMatcher(phrase: wakePhrase).name)\u{201D} cuts Needs You off.")
                    .foregroundStyle(.secondary)
            }
            Section("Wake Phrase") {
                wakePhraseRows
            }
            Section {
                LabeledContent("Your Turn Shortcut") { ShortcutRecorder() }
            } footer: {
                Text("Same as saying \u{201C}\(phrase)\u{201D}: opens your turn at once. Press it again to finish, or while Claude talks to cut it off and speak. Does nothing during Do Not Disturb. Esc closes: Claude stops talking, or listening stops and what you said is kept, not sent (Claude\u{2019}s question waits as a voicemail). Esc twice resets: nothing is kept.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Your Voice", value: conductor.voiceEnrolled ? "Learned" : "Not learned")
                if let line = conductor.voiceLine {
                    Text(line).font(.title3.weight(.medium))
                } else {
                    HStack {
                        Button(conductor.voiceEnrolled ? "Learn My Voice Again" : "Learn My Voice") { Task { _ = await conductor.learnVoice() } }
                            .disabled(conductor.busy)
                        if conductor.voiceEnrolled { Button("Forget My Voice") { Task { await conductor.forgetVoice() } } }
                    }
                }
            } footer: {
                Text(conductor.voiceEnrolled ? "Other voices are ignored." : "Any voice can wake it until it has learned yours.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Wake phrase field (live advice), Use / Default buttons, and the Test readout.
    @ViewBuilder private var wakePhraseRows: some View {
        let draft = phraseDraft ?? wakePhrase
        let check = WakeMatcher.check(draft)
        let changed = WakeMatcher(phrase: draft).phrase != phrase
        TextField("Phrase", text: Binding(get: { phraseDraft ?? wakePhrase }, set: { phraseDraft = $0 }), prompt: Text(WakeMatcher.defaultPhrase))
            .onSubmit(usePhrase)
        if let w = check.warning {
            Text(w).font(.caption).foregroundStyle(.orange)
        } else if changed {
            Text("Looks good. Press Return or Use to switch to it.").font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            if changed { Button("Use", action: usePhrase).disabled(!check.usable) }
            if !WakeMatcher(phrase: wakePhrase).isDefault || changed {
                Button("Back to \u{201C}\(WakeMatcher.defaultPhrase)\u{201D}") { phraseDraft = nil; wakePhrase = WakeMatcher.defaultPhrase; voice.refresh() }
            }
            Spacer()
            Button(voice.testing ? "Testing\u{2026}" : "Test") { voice.startTest() }
                .disabled(voice.testing || !voice.enabled)
        }
        if voice.testing || voice.testWoke != nil || !voice.lastHeard.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if voice.testing { Text("Say \u{201C}\(phrase)\u{201D} now. A wake only chimes; nothing is sent.").font(.caption) }
                if !voice.lastHeard.isEmpty {
                    Text("Heard: \u{201C}\(voice.lastHeard)\u{201D} (\(voice.lastHeardWakes ? "matches" : "no match"))")
                        .font(.caption).foregroundStyle(voice.lastHeardWakes ? Color.green : Color.secondary)
                }
                if let w = voice.testWoke { Text(w).font(.caption.weight(.medium)) }
            }
        } else if !voice.enabled {
            Text("Turn on listening to test the phrase.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func usePhrase() {
        guard let d = phraseDraft, WakeMatcher.check(d).usable else { return }
        wakePhrase = WakeMatcher(phrase: d).phrase
        phraseDraft = nil
        voice.refresh()
    }
}

// MARK: Voice

struct VoicePane: View {
    @AppStorage("localVoice") private var localVoice = "af_heart"
    @AppStorage("volume") private var volume = 0.9
    @AppStorage("soundVolume") private var soundVolume = 1.0
    @AppStorage(Ducker.defaultsKey) private var duckWhileListening = true
    @AppStorage(SoundSet.key) private var soundSet = SoundSet.rosewood.rawValue
    @AppStorage("subtitlesOnScreen") private var subtitlesOnScreen = true
    @AppStorage("islandStyle") private var islandStyle = Island.Style.automatic.rawValue
    @State private var previewing = false
    @State private var playingAll = false
    @State private var note: String?
    @ObservedObject private var native = NativeVoices.shared
    @State private var previewingLanguage: String?
    private let player = Player()

    static func voiceLabel(_ id: String) -> String {
        let parts = id.split(separator: "_")
        guard parts.count == 2, let p = parts.first, p.count == 2 else { return id }
        let accent = p.first == "b" ? "British" : "American"
        let sex = p.last == "f" ? "female" : "male"
        return "\(parts[1].capitalized) (\(accent) \(sex))"
    }

    var body: some View {
        Pane(height: 720) {
            Section {
                Picker("English Voice", selection: $localVoice) {
                    ForEach(LocalTTS.voices, id: \.self) { Text(Self.voiceLabel($0)).tag($0) }
                }
                LabeledContent("Volume") {
                    Slider(value: $volume, in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("") {
                    Button(previewing ? "Playing\u{2026}" : "Preview Voice") { preview() }
                        .disabled(previewing)
                }
            }
            Section {
                Toggle("Lower Other Audio While You Talk", isOn: $duckWhileListening)
                    .onChange(of: duckWhileListening) { _, on in if !on { Ducker.shared.releaseAll() } }
            } footer: {
                Text("Music and videos get quieter after \u{201C}\(Wake.phrase)\u{201D} or the turn shortcut, and while you answer, the same way they do while Needs You speaks.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(VoiceRouting.native, id: \.self) { code in nativeRow(code) }
            } header: {
                Text("Other Languages")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(nativeNote).foregroundStyle(.secondary)
                    if let e = native.lastError { Text(e).foregroundStyle(.red) }
                }
            }
            Section {
                Toggle("Subtitles on Screen", isOn: $subtitlesOnScreen)
                    .onChange(of: subtitlesOnScreen) { _, on in if !on { Subtitles.shared.disable() } }
                Picker("Island Style", selection: $islandStyle) {
                    ForEach(Island.Style.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } footer: {
                Text("Subtitles show what you and Needs You say, with a glow along the screen edges. The island at the top of the screen shows what Needs You is doing; Automatic grows it out of the notch on a MacBook screen and shows a pill under the menu bar elsewhere.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Sounds", selection: $soundSet) {
                    ForEach(SoundSet.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: soundSet) { _, _ in DispatchQueue.global().async { Sounds.shared.preload() } }
                LabeledContent("Sound Volume") { Slider(value: $soundVolume, in: 0...1) }
                LabeledContent("") {
                    Button(playingAll ? "Playing\u{2026}" : "Play All Sounds") { playAll() }.disabled(playingAll)
                }
            } footer: {
                if let note { Text(note).foregroundStyle(.secondary) }
            }
        }
    }

    /// One language (HM-1368): its voice, or a Download button with the size.
    @ViewBuilder private func nativeRow(_ code: String) -> some View {
        let _ = native.revision
        let ready = NativeVoices.ready(code)
        LabeledContent {
            HStack(spacing: 8) {
                if native.downloading == code {
                    ProgressView(value: native.progress).frame(width: 140)
                } else if ready {
                    Picker("Voice", selection: Binding(get: { NativeVoices.voice(for: code) },
                                                       set: { v in Task { await native.choose(v, for: code) } })) {
                        ForEach(VoiceRouting.voices, id: \.self) { Text(VoiceRouting.voiceLabel($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Delete") { Task { await native.delete(code) } }
                } else {
                    Button(NativeVoices.modelOnDisk ? "Download" : "Download (\(NativeVoices.downloadMB) MB)") {
                        Task { await native.download(code) }
                    }
                    .disabled(native.downloading != nil)
                }
                Button { previewLanguage(code) } label: { Image(systemName: "play.fill") }
                    .help("Preview")
                    .disabled(previewingLanguage != nil || native.downloading == code)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(SpokenLanguages.name(code))
                Text(nativeStatus(code, ready: ready)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func nativeStatus(_ code: String, ready: Bool) -> String {
        if ready { return "Native voice on this Mac" }
        let mac = SystemVoice.voiceName(code).map { "macOS voice (\($0))" } ?? "macOS voice"
        return NativeVoices.removed.contains(code) ? mac : "\(mac) until the native voice is downloaded"
    }

    private var nativeNote: String {
        let _ = native.revision
        var s = "Each sentence is spoken in its own language, so a mixed reply switches voice. English stays with the voice above. The other languages share one voice model (\(NativeVoices.downloadMB) MB), downloaded once the first time a language comes up or with Download; Delete on the last language removes it. Until then, or if it fails, macOS voices speak."
        let bytes = native.diskBytes
        if bytes > 0 { s += " On disk: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))." }
        return s
    }

    private func previewLanguage(_ code: String) {
        previewingLanguage = code
        Task { @MainActor in
            defer { previewingLanguage = nil }
            do {
                let data = try await VoiceMix.speech(VoiceRouting.samples[code] ?? "").audio
                try await player.play(data, volume: Float(volume))
            } catch { note = error.localizedDescription }
        }
    }

    private func playAll() {
        playingAll = true
        Task { @MainActor in
            for cue in Cue.allCases {
                note = cue.label
                await Sounds.shared.playAndWait(cue)
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
            note = nil
            playingAll = false
        }
    }

    private func preview() {
        previewing = true
        Task { @MainActor in
            defer { previewing = false }
            do {
                let line = "Hi\(UserName.spaceName). This is how I sound when an agent needs you."
                let data = try await LocalTTS.shared.speech(line, voice: localVoice)
                try await player.play(data, volume: Float(volume))
            } catch { note = error.localizedDescription }
        }
    }
}

// MARK: Microphones

struct MicrophonesPane: View {
    @ObservedObject private var voice = VoiceCommands.shared
    @AppStorage("micUID") private var micUID = ""
    @AppStorage("waitSeconds") private var waitSeconds = 30.0
    @AppStorage("endSilence") private var endSilence = 4.0
    @AppStorage("judgePause") private var judgePause = 2.0
    @AppStorage("transcriptMode") private var transcriptMode = TranscriptMode.removeFillers.rawValue
    @AppStorage(SpokenLanguages.defaultsKey) private var spokenLanguages = "en"
    @AppStorage(SpokenLanguages.strictKey) private var onlyThese = false
    @AppStorage("localSTTModel") private var sttModel = "wturbo+p"
    @State private var mics: [InputDevice] = []

    /// One language on: always that one. A language can be turned off only while another is on (HM-1351).
    private func languageBinding(_ code: String) -> Binding<Bool> {
        Binding(get: { SpokenLanguages.parse(spokenLanguages).contains(code) }, set: { on in
            var codes = SpokenLanguages.parse(spokenLanguages)
            if on { codes.append(code) } else if codes.count > 1 { codes.removeAll { $0 == code } }
            spokenLanguages = SpokenLanguages.store(codes)
        })
    }

    private var languagesNote: String {
        let codes = SpokenLanguages.parse(spokenLanguages)
        let names = codes.map(SpokenLanguages.name).joined(separator: ", ")
        var note: String
        if onlyThese {
            note = codes.count == 1
                ? "Everything you say is written down in \(names)."
                : "Each time you speak, the most likely of these is picked and your words are written down in it, never translated."
        } else {
            note = "\(names) \(codes.count == 1 ? "is" : "are") favoured. Speak another language and it switches to it once it is sure, after about 2 s; subtitles wait until then. Never translated."
        }
        note += " The wake phrase and \u{201C}Stop\u{201D} stay as they are. Needs You speaks each sentence in its own language (Settings \u{2192} Voice)."
        if !sttModel.hasPrefix("w") { note += " Other languages need a Whisper model (Settings \u{2192} Models)." }
        return note
    }

    var body: some View {
        Pane(height: 700) {
            Section {
                Picker("Microphone", selection: $micUID) {
                    Text("System Default").tag("")
                    ForEach(mics) { m in Text(m.name).tag(m.id) }
                }
                Toggle("Also Use the iPhone Mic", isOn: $voice.phoneMic)
                LabeledContent("iPhone Mic", value: !voice.phoneMic ? "Off" : voice.phoneInUse.map { "Listening (\($0))" } ?? "Not nearby, using the Mac mic")
            }
            Section("Your Answer") {
                Stepper(value: $waitSeconds, in: 5...120, step: 5) {
                    LabeledContent("Wait for an answer", value: "\(Int(waitSeconds)) s")
                }
                Stepper(value: $judgePause, in: 0.5...10, step: 0.25) {
                    LabeledContent("Pause before checking if you\u{2019}re done", value: String(format: "%.2g s", judgePause))
                }
                Stepper(value: $endSilence, in: 1.5...10, step: 0.5) {
                    LabeledContent("Longest pause in your turn", value: String(format: "%.1f s", endSilence))
                }
            }
            Section {
                ForEach(SpokenLanguages.all) { lang in
                    Toggle(lang.name, isOn: languageBinding(lang.code))
                }
                Toggle("Only These Languages", isOn: $onlyThese)
            } header: {
                Text("Languages I Usually Speak")
            } footer: {
                Text(languagesNote)
                    .foregroundStyle(sttModel.hasPrefix("w") ? Color.secondary : Color.orange)
            }
            Section {
                Picker("Transcript", selection: $transcriptMode) {
                    ForEach(TranscriptMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } footer: {
                Text(transcriptNote)
                    .foregroundStyle(transcriptMode == TranscriptMode.polish.rawValue ? Color.orange : Color.secondary)
            }
        }
        .task { mics = AudioDevices.inputs() }
    }

    private var transcriptNote: String {
        switch TranscriptMode(rawValue: transcriptMode) ?? .removeFillers {
        case .verbatim: return "Exactly what was heard."
        case .removeFillers: return "Drops uh, um, ähm, stutters and repeated words. Every other word stays as you said it."
        case .polish:
            return TranscriptCleaner.polishAvailable
                ? "Rewrites into clear English with Apple\u{2019}s on-device model. This can change nuance. History keeps what you said."
                : "Apple Intelligence is not available on this Mac, so Polish falls back to Remove Fillers."
        }
    }
}

// MARK: Models

struct ModelsPane: View {
    var body: some View {
        Pane(height: 480) { ModelSettings() }
    }
}

// MARK: Do Not Disturb

struct DoNotDisturbPane: View {
    @ObservedObject private var conductor = Conductor.shared
    @ObservedObject private var dnd = DoNotDisturb.shared
    @State private var customEnd = Date().addingTimeInterval(2 * 3600)
    private var phrase: String { Wake.phrase }

    var body: some View {
        Pane(height: 450) {
            Section {
                Toggle("Do Not Disturb", isOn: Binding(get: { dnd.on }, set: { dnd.set($0) }))
                if dnd.on, let since = dnd.state.since {
                    LabeledContent(dnd.state.goodNight ? "Good Night Since" : "On Since", value: since.formatted(date: .omitted, time: .shortened))
                    LabeledContent("Ends", value: dnd.untilText.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "When you turn it off or say you\u{2019}re back")
                }
                // HM-1433: on for a while, or until a time; it turns itself off then.
                HStack {
                    Menu(dnd.on ? "Change the End" : "Turn On For\u{2026}") {
                        ForEach(DoNotDisturb.presets(), id: \.0) { label, end in
                            Button(label) { dnd.turnOn(until: end) }
                        }
                        Button("Until I Turn It Off") { dnd.turnOn(until: nil) }
                    }
                    .fixedSize()
                    Spacer()
                }
                HStack {
                    DatePicker("Until", selection: $customEnd, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Button(dnd.on ? "Set End" : "Turn On") { dnd.turnOn(until: customEnd) }
                        .disabled(customEnd <= Date())
                }
            } footer: {
                Text("While it is on, agents cannot speak, play sounds or open the mic: what they wanted to say is kept as a voicemail. With an end it turns itself off then. Say \u{201C}\(phrase), I\u{2019}m out for two hours\u{201D}, \u{201C}\(phrase), do not disturb until 3 p.m.\u{201D} or \u{201C}\(phrase), good night\u{201D} to turn it on, and \u{201C}\(phrase), I\u{2019}m back\u{201D} or \u{201C}good morning\u{201D} to turn it off and hear the voicemails one by one. \u{201C}What did you work on last night?\u{201D} gives a summary.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Unheard Voicemails", value: "\(dnd.unheard.count)")
                HStack {
                    Button("Play Voicemails") { Task { await conductor.playVoicemails(greeting: nil, summary: false) } }
                        .disabled(dnd.unheard.isEmpty || conductor.busy)
                    Button("Show Voicemails\u{2026}") { Nav.shared.show(.voicemails) }
                    Spacer()
                    Button("Clear Heard") { dnd.clearHeard() }
                        .disabled(!dnd.voicemails.contains { $0.heard })
                }
            }
        }
    }
}

// MARK: Agents (HM-1355)

/// Connect an agent so its chats can be reached by voice (HM-1364).
struct ReachByVoiceSection: View {
    @ObservedObject private var connect = AgentConnect.shared
    @ObservedObject private var registry = ChatRegistry.shared

    var body: some View {
        Section {
            ForEach(AgentConnect.Agent.allCases) { agent in
                Toggle(isOn: Binding(get: { connect.connected[agent] ?? false },
                                     set: { connect.set(agent, connected: $0) })) {
                    Label { Text(agent.name) } icon: { AppIcon(bundle: agent.appBundle, fallback: "terminal") }
                }
                .disabled(!(connect.installed[agent] ?? false))
            }
            if connect.claudeAppNeedsRestart {
                HStack {
                    Label("The Claude app loads the change when it restarts.", systemImage: "arrow.clockwise")
                    Spacer()
                    Button("Restart Claude") { connect.restartClaudeApp() }
                }
            }
            ChatGPTRow()
            LabeledContent("Chats reachable now", value: "\(registry.reachable.count)")
            if let e = connect.lastError { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red) }
        } header: {
            Text("Reach by Voice")
        } footer: {
            Text("Adds the Needs You MCP server and hooks to the agent (a backup of each file is kept). Each chat then tells Needs You what it is working on. A message for an idle chat is typed into it through Accessibility; a busy chat gets it at its next step. Chats of agents that are not connected cannot be reached by voice. New chats pick it up; restart open ones. Codex asks once to trust the new hooks. The Claude app gets the MCP server only, so its chats can answer out loud; \u{201C}Hey Mac, new chat on Claude desktop, ...\u{201D} reaches it either way.")
                .foregroundStyle(.secondary)
        }
        .onAppear { connect.refresh() }
    }
}

/// An installed app's own icon at label size, or an SF Symbol when it has none.
struct AppIcon: View {
    var bundle: String?
    var fallback: String
    var size: CGFloat = 16

    var body: some View {
        if let b = bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: fallback).frame(width: size, height: size)
        }
    }
}

/// ChatGPT (HM-1385): its Codex tasks read ~/.codex/config.toml, so the Codex switch covers
/// them. Plain ChatGPT chats only take connectors on the internet (Settings, Apps &
/// Connectors, Developer mode), which can't reach a server on this Mac; voice still types into them.
struct ChatGPTRow: View {
    @ObservedObject private var connect = AgentConnect.shared
    @State private var guide = false

    var body: some View {
        if let url = connect.chatGPTApp {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(connect.connected[.codex] == true ? "Codex tasks connected" : "Turn on Codex above")
                        .foregroundStyle(.secondary)
                    Button("How\u{2026}") { guide.toggle() }
                        .popover(isPresented: $guide, arrowEdge: .trailing) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("ChatGPT").font(.headline)
                                Text("1. Codex tasks in the ChatGPT app use the Codex connection. Turn on Codex above, then start a new task. They answer out loud like Claude Code.")
                                Text("2. Plain ChatGPT chats can only use connectors on the internet, so they can't reach Needs You on this Mac. You can still talk to them: \u{201C}Hey Mac, use ChatGPT to ask \u{2026}\u{201D} opens a new chat and types your question. The answer stays on screen.")
                                Button("Open ChatGPT") { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
                            }
                            .font(.callout)
                            .frame(width: 320)
                            .padding()
                        }
                }
            } label: {
                Label { Text("ChatGPT app") } icon: { AppIcon(bundle: "com.openai.codex", fallback: "bubble.left") }
            }
        }
    }
}

struct AgentsPane: View {
    @ObservedObject private var store = AgentsStore.shared
    @AppStorage(AgentsStore.enabledKey) private var enabled = true
    @State private var showingDiff = false
    @State private var showingLegacy = false
    @ObservedObject private var permissions = PermissionVoice.shared
    @State private var showingHook = false
    static var demoSheet: String?

    var body: some View {
        Pane(height: 560) {
            Section {
                Toggle("Install Agent Instructions", isOn: Binding(get: { enabled }, set: { store.setEnabled($0); enabled = $0 }))
                LabeledContent("File", value: (store.model.fileURL.path as NSString).abbreviatingWithTildeInPath)
                LabeledContent("Status", value: statusText)
                HStack {
                    Button("Edit\u{2026}") { store.edit() }
                    Button("Show in Finder") { store.reveal() }
                }
                .disabled(!FileManager.default.fileExists(atPath: store.model.fileURL.path))
            } footer: {
                Text("Needs You keeps its instructions for agents in needs-you.md and adds one import line to CLAUDE.md, so every Claude Code session knows how to ask you out loud. They update with the app. Edit the file as you like: your version is kept.")
                    .foregroundStyle(.secondary)
            }
            ReachByVoiceSection()
            if let s = store.status, s.newDefaultWaiting {
                Section {
                    Label("Your edited agent instructions differ from the new default.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Show Diff\u{2026}") { showingDiff = true }
                        Spacer()
                        Button("Keep Mine") { store.keepMine() }
                        Button("Use New Default") { store.useNewDefault() }
                    }
                }
            }
            if let s = store.status, let old = s.legacySection, s.enabled {
                Section {
                    Label("CLAUDE.md still has the old hand-written Needs You section.", systemImage: "doc.text.magnifyingglass")
                    HStack {
                        Spacer()
                        Button("Review and Remove\u{2026}") { showingLegacy = true }
                    }
                } footer: {
                    Text("Agents read both until it is gone. Nothing outside the Needs You lines changes without your click; a backup is kept as CLAUDE.md.needs-you-backup.")
                        .foregroundStyle(.secondary)
                }
                .sheet(isPresented: $showingLegacy) {
                    TextSheet(title: "Remove this section from CLAUDE.md?", text: old, confirm: "Remove Section") {
                        store.removeLegacySection()
                    }
                }
            }
            // HM-1369: a PermissionRequest hook in ~/.claude/settings.json.
            Section {
                Toggle("Approve Permission Prompts by Voice", isOn: Binding(
                    get: { permissions.installed && PermissionVoice.enabled },
                    set: { on in if on { showingHook = true } else { permissions.setEnabled(false) } }))
                LabeledContent("Hook", value: permissions.installed ? "Installed in settings.json" : "Not installed")
                if permissions.installed {
                    Button("Show settings.json in Finder") { permissions.revealSettings() }
                }
                if let e = permissions.lastError { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red) }
            } footer: {
                Text("When a Claude Code chat asks permission for something risky (git push, rm -rf, deploys, database writes, installs, sudo, ssh), Needs You asks you out loud: \u{201C}website wants to force-push to main. Allow?\u{201D} Say yes, no, or \u{201C}always\u{201D}. Everything else, Do Not Disturb, no answer or an unclear one shows the normal prompt on screen; it never allows anything on its own. Adds one hook to ~/.claude/settings.json (a backup is kept as settings.json.needs-you-backup); turning it off removes it. New chats pick it up.")
                    .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showingHook) {
                TextSheet(title: "Add this hook to ~/.claude/settings.json?",
                          text: permissions.preview + "\n\nThe rest of the file stays as it is. A copy is saved first as settings.json.needs-you-backup.",
                          confirm: "Add Hook") {
                    permissions.setEnabled(true)
                }
            }
            if let e = store.lastError {
                Section { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red) }
            }
        }
        .onAppear {
            store.sync()
            permissions.sync()
            if Self.demoSheet == "hook" { showingHook = true }
            // --ui-demo --sheet legacy|diff
            if Self.demoSheet == "diff" { showingDiff = true }
            if Self.demoSheet == "legacy" { showingLegacy = true }
            Self.demoSheet = nil
        }
        .sheet(isPresented: $showingDiff) {
            TextSheet(title: "Your file and the new default", text: store.diff(), confirm: "Use New Default") {
                store.useNewDefault()
            }
        }
    }

    private var statusText: String {
        guard let s = store.status else { return Prefs.readOnly ? "Not checked in the demo" : "Not checked yet" }
        if !s.enabled { return "Off" }
        if !s.imported { return "Not imported in CLAUDE.md" }
        if s.newDefaultWaiting { return "Edited, new default available" }
        return s.edited ? "Installed, edited by you" : "Installed, up to date"
    }
}

// MARK: Apps (HM-1415)

/// Which apps voice messages may go to: herdr, the terminals and editors chats run in, and
/// the chat apps found on this Mac. A turned-off app's chats are never offered, chosen or typed into.
struct AppsPane: View {
    @ObservedObject private var registry = ChatRegistry.shared
    @State private var apps: [ChatApps.App] = []
    @State private var disabled: Set<String> = []

    var body: some View {
        Pane(height: 520) {
            let hosts = apps.filter { $0.kind != .chatApp }
            let chatApps = apps.filter { $0.kind == .chatApp }
            Section {
                if hosts.isEmpty { Text("None yet. Connect an agent in Agents; the apps its chats run in show up here.").foregroundStyle(.secondary) }
                ForEach(hosts) { row($0) }
            } header: {
                Text("Terminals and Editors")
            } footer: {
                Text("A chat in a herdr or tmux pane follows that switch; any other chat follows the app it runs in.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if chatApps.isEmpty { Text("None found. Apps with a chat list and a message field show up here once they run.").foregroundStyle(.secondary) }
                ForEach(chatApps) { row($0) }
            } header: {
                Text("Chat Apps")
            } footer: {
                Text("When an app is off, its chats are never offered when Needs You asks which chat, never picked for a message, and nothing is typed into it.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: ChatApps.changed)) { _ in load() }
    }

    private func row(_ a: ChatApps.App) -> some View {
        Toggle(isOn: Binding(get: { !disabled.contains(a.id) },
                             set: { on in ChatApps.set(a.id, enabled: on); disabled = ChatApps.disabled })) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name)
                    if let s = detail(a) { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: {
                AppIcon(bundle: a.kind == .mux ? nil : a.id, fallback: a.kind == .mux ? "rectangle.split.3x1" : "app", size: 20)
            }
        }
    }

    private func detail(_ a: ChatApps.App) -> String? {
        let n = registry.reachable.filter { ChatApps.owner($0)?.id == a.id }.count
        if n > 0 { return n == 1 ? "1 chat open" : "\(n) chats open" }
        if a.kind == .chatApp { return NSRunningApplication.runningApplications(withBundleIdentifier: a.id).isEmpty ? "Not running" : "Running" }
        return nil
    }

    private func load() {
        apps = ChatApps.all
        disabled = ChatApps.disabled
    }
}

/// A sheet with monospaced text and Cancel / confirm buttons.
struct TextSheet: View {
    var title: String
    var text: String
    var confirm: String
    var action: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Self.colored(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm) { action(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 400)
    }

    /// Diff lines in system red and green; other text as is.
    static func colored(_ text: String) -> Text {
        text.components(separatedBy: "\n").enumerated().reduce(Text("")) { acc, item in
            let (n, line) = item
            let t = Text((n == 0 ? "" : "\n") + line)
            if line.hasPrefix("+ ") { return acc + t.foregroundColor(.green) }
            if line.hasPrefix("- ") { return acc + t.foregroundColor(.red) }
            return acc + t
        }
    }
}
