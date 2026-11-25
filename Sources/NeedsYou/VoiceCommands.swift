import AppKit
import AVFoundation
import Combine
import NeedsYouShared
import SwiftUI

/// "Hey Claude, <chat>: <message>" -> the message typed into that chat.
@MainActor
final class VoiceCommands: ObservableObject {
    static let shared = VoiceCommands()

    @Published private(set) var status = "Off"
    /// True while the mic is open for the wake word (menu bar dot).
    @Published private(set) var armed = false
    @Published private(set) var capturing = false
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "wakeEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "wakeEnabled")
            Task { await self.enabledChanged() }
        }
    }

    /// Settings → Test: for 20 s, show what the listener hears and whether the
    /// wake phrase matched; a wake then only chimes and is not sent anywhere.
    @Published private(set) var testing = false
    @Published private(set) var lastHeard = ""
    @Published private(set) var lastHeardWakes = false
    @Published private(set) var testWoke: String?
    private var testEnd: DispatchWorkItem?

    func startTest() {
        testEnd?.cancel()
        testing = true; lastHeard = ""; lastHeardWakes = false; testWoke = nil
        let end = DispatchWorkItem { [weak self] in self?.testing = false }
        testEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: end)
    }

    private func noteHeard(_ text: String) {
        guard testing else { return }
        lastHeard = text
        lastHeardWakes = Wake.containsWakeWord(text)
    }

    private let listener = WakeListener()
    /// The iPhone's Continuity microphone, listening beside the Mac mic.
    private let phoneListener = WakeListener()
    @Published var phoneMic: Bool = UserDefaults.standard.object(forKey: "iphoneMic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(phoneMic, forKey: "iphoneMic"); refresh() }
    }
    /// Name of the iPhone mic while it is in use (menu and Settings).
    @Published private(set) var phoneInUse: String?
    private var devicesWatch: AudioObjectPropertyListenerBlock?
    /// The first take of the current utterance, waiting briefly for the other mic's.
    private var firstTake: (source: String, wav: Data, score: Float?, snr: Float, at: Date)?
    private var lastWake = Date.distantPast
    private var prepared = false
    private var preparing = false
    private var handling = false
    /// The turn shortcut opened the mic while "Listen for Hey Claude" is off: on for one command.
    private var oneShot = false
    private var cancellables: Set<AnyCancellable> = []
    /// The 2 s before a command is typed into a chat (shown on the island).
    private var countdown: SendCountdown?

    func setUp() {
        phoneListener.source = "iphone"
        for (l, other) in [(listener, phoneListener), (phoneListener, listener)] {
            let src = l === listener ? "mac" : "iphone"
            l.onCommandPartial = { text, swap in DispatchQueue.main.async { Subtitles.shared.userPartial(text, source: src, swap: swap); ModelRouter.shared.partial(text) } }
            l.onCommandLevel = { v in DispatchQueue.main.async { Subtitles.shared.level(v, .user, source: src) } }
            l.onHeard = { [weak self] text in DispatchQueue.main.async { self?.noteHeard(text) } }
            l.onWake = { [weak self, weak other] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.testing {
                        // A test wake: chime, show it, and listen for the phrase again.
                        guard Date().timeIntervalSince(self.lastWake) > 3 else { return }
                        self.lastWake = Date()
                        self.testWoke = self.lastHeard.isEmpty ? "Woke" : "Woke on \u{201C}\(self.lastHeard)\u{201D}"
                        Sounds.shared.play(.listening)
                        self.listener.stop(); self.stopPhone()
                        self.refresh()
                        return
                    }
                    if other?.isRunning == true { other?.forceWake() }
                    // Both mics may wake on the same words: one cue.
                    guard Date().timeIntervalSince(self.lastWake) > 3 else { return }
                    self.lastWake = Date()
                    Sounds.shared.play(.listening)
                    self.capturing = true
                    Island.shared.wake(source: src)
                    ModelRouter.shared.wake()
                    Subtitles.shared.userBegan(source: src)
                }
            }
            l.onUtterance = { [weak self] wav, score, snr in
                DispatchQueue.main.async { self?.take(src, wav, score, snr) }
            }
        }
        watchDevices()
        listener.onCancelWord = { [weak self] in DispatchQueue.main.async { self?.countdown?.cancel() } }
        Conductor.shared.$micInUse.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        Task { await enabledChanged() }
    }

    private func enabledChanged() async {
        if enabled && !WakeListener.authorized {
            _ = await WakeListener.requestAuthorization()
        }
        refresh()
    }

    var speechAllowed: Bool { WakeListener.authorized }
    /// The user is saying a Hey Claude command, or one is being handled or sent.
    var userHasFloor: Bool { capturing || handling }
    /// The room mic hears someone talking (gate open), outside a command.
    var hearingSomeone: Bool { listener.isRunning && listener.hearingSomeone }
    var noiseReduction: Bool { listener.isRunning && listener.noiseReductionActive }

    /// Runs the mic only when nothing else is using it, so it never hears Needs You itself.
    func refresh() {
        guard enabled || oneShot else { stopListening("Off"); return }
        guard WakeListener.authorized else { stopListening("Speech Recognition is not allowed"); return }
        guard listener.supportsOnDevice else { stopListening("On-device speech recognition is not available"); return }
        if Conductor.shared.micInUse || handling {
            if !(handling && countdown != nil) { stopListening("Paused while Needs You is talking") }
            return
        }
        if !listener.isRunning {
            guard prepared else {
                status = "Preparing the on-device speech model"
                if !preparing {
                    preparing = true
                    Task {
                        do { try await listener.prepare(); try? await phoneListener.prepare(); prepared = true } catch { status = error.localizedDescription }
                        preparing = false
                        refresh()
                    }
                }
                return
            }
            listener.endSilence = Prefs.endSilence
            do { try listener.startMic(deviceUID: Prefs.micUID) } catch {
                status = error.localizedDescription; return
            }
        }
        refreshPhone()
        status = "Listening for \u{201C}\(Wake.phrase)\u{201D}"
        armed = true
    }

    private func stopListening(_ why: String) {
        armed = false
        if listener.isRunning { listener.stop() }
        stopPhone()
        status = why
    }

    // MARK: Turn shortcut (HM-1354)

    /// Same as a heard wake phrase: chime, ears, then listening and recording. Waits
    /// for the mic to come back when Needs You just stopped talking.
    func openTurn() async {
        guard !DoNotDisturb.shared.on else { Island.shared.moon(); return }
        if !enabled { oneShot = true }
        refresh()
        let until = Date().addingTimeInterval(10) // first use may load the speech model
        while (!listener.isRunning || Conductor.shared.micInUse || handling) && Date() < until {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !listener.isRunning { refresh() }
        }
        guard listener.isRunning, !capturing, !Conductor.shared.micInUse, !DoNotDisturb.shared.on else {
            Isolation.note("keys: turn not opened (\(status))")
            if oneShot && !capturing { oneShot = false; refresh() }
            if !listener.isRunning { Island.shared.error("Can\u{2019}t open the mic", status) }
            return
        }
        lastWake = .distantPast
        listener.openTurn()
        if oneShot {
            // Safety net: the one-shot mic never stays on past one command (2 min at most).
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 130_000_000_000)
                guard let self, self.oneShot, !self.capturing, !self.handling else { return }
                self.oneShot = false
                self.refresh()
            }
        }
    }

    /// The turn shortcut while he is saying a command: it ends now, like "done".
    func endTurn() {
        listener.endTurn()
        phoneListener.endTurn()
    }

    // MARK: iPhone mic (Continuity)

    /// Starts or stops the iPhone listener to match the switch and whether the
    /// iPhone is there. Never makes a sound: when it drops out, the Mac mic carries on.
    private func refreshPhone() {
        guard phoneMic, listener.isRunning, let phone = AudioDevices.continuityMic(),
              phone.id != Prefs.micUID else { stopPhone(); return }
        if phoneListener.isRunning { return }
        phoneListener.endSilence = Prefs.endSilence
        do {
            try phoneListener.startMic(deviceUID: phone.id)
            phoneInUse = phone.name
            Isolation.note("wake: iPhone mic on (\(phone.name))")
        } catch {
            Isolation.note("wake: iPhone mic unavailable (\(error.localizedDescription))")
            phoneListener.stop(); phoneInUse = nil
        }
    }

    private func stopPhone() {
        if phoneListener.isRunning { phoneListener.stop(); Isolation.note("wake: iPhone mic off") }
        phoneInUse = nil
    }

    /// The iPhone comes and goes (range, lock, Continuity): follow the device list.
    private func watchDevices() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.phoneListener.isRunning, AudioDevices.continuityMic() == nil { self.stopPhone() }
                self.refresh()
            }
        }
        devicesWatch = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }

    /// One utterance, heard by one or both mics: wait briefly for the second take,
    /// then send the better one (his voice score first, then SNR).
    private func take(_ source: String, _ wav: Data, _ score: Float?, _ snr: Float) {
        let mine = (source: source, wav: wav, score: score, snr: snr, at: Date())
        if let first = firstTake, first.source != source, Date().timeIntervalSince(first.at) < 4 {
            firstTake = nil
            pick([first, mine])
            return
        }
        if let first = firstTake { firstTake = nil; pick([first]) }
        firstTake = mine
        let otherRunning = source == "mac" ? phoneListener.isRunning : listener.isRunning
        let wait: Double = otherRunning ? 2.5 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, let f = self.firstTake, f.at == mine.at else { return }
            self.firstTake = nil
            self.pick([f])
        }
    }

    private func pick(_ takes: [(source: String, wav: Data, score: Float?, snr: Float, at: Date)]) {
        func value(_ t: (source: String, wav: Data, score: Float?, snr: Float, at: Date)) -> Float {
            (t.score ?? 0) + t.snr * 0.01 // 10 dB SNR weighs like 0.1 of voice score
        }
        let best = takes.max { value($0) < value($1) }!
        let line = takes.map { String(format: "%@ voice %.2f snr %.1f dB", $0.source, $0.score ?? -1, $0.snr) }.joined(separator: " | ")
        Isolation.note("mic pick: \(best.source) won (\(line))")
        Sounds.shared.play(.gotIt)
        capturing = false
        Subtitles.shared.userStopped()
        guard MicMerge.enabled, takes.count == 2, let other = takes.first(where: { $0.source != best.source }) else {
            MicLog.write("\(best.source) won: \(line)")
            Task { @MainActor in
                let r = await self.handle(wav: best.wav, dryRun: false)
                Island.shared.finished(r.status, error: r.error, errorTitle: "Not sent")
            }
            return
        }
        // Merge (experimental): only when it lines up and clearly beats the best mic.
        Task { @MainActor in
            let a = Recorder.samples(fromWav: best.wav), b = Recorder.samples(fromWav: other.wav)
            let merged = await MicMerge.merge(best: a, other: b)
            var wav = best.wav
            if let m = merged, let ms = m.score {
                let mv = ms + WakeListener.snr(m.audio) * 0.01
                if mv >= value(best) + 0.03 {
                    wav = Recorder.wav(m.audio)
                    MicLog.write(String(format: "merge (%@) won, %.2f vs best mic %.2f: %@", m.label, mv, value(best), line))
                } else {
                    MicLog.write(String(format: "\(best.source) won over merge (%@ %.2f vs %.2f): %@", m.label, mv, value(best), line))
                }
            } else {
                MicLog.write("\(best.source) won (merge skipped: takes did not line up): \(line)")
            }
            let r = await self.handle(wav: wav, dryRun: false)
            Island.shared.finished(r.status, error: r.error, errorTitle: "Not sent")
        }
    }

    // MARK: One command

    /// Test hook: plays a file through a separate listener, then handles the command.
    func test(file: String, dryRun: Bool) async -> Response {
        let wasEnabled = enabled
        if listener.isRunning { listener.stop() }
        handling = true
        defer { handling = false; if wasEnabled { refresh() } }
        guard WakeListener.authorized else { return errorResponse("Speech Recognition is not allowed for Needs You.") }

        let testListener = WakeListener()
        testListener.endSilence = Prefs.endSilence
        do { try await testListener.prepare() } catch { return errorResponse(error.localizedDescription) }
        let wav: Data? = await withCheckedContinuation { cont in
            var done = false
            let once: (Data?) -> Void = { d in
                DispatchQueue.main.async { if !done { done = true; testListener.stop(); cont.resume(returning: d) } }
            }
            testListener.onCommand = { once($0) }
            testListener.onEndOfFile = { once(nil) }
            do { try testListener.startFile(try AVAudioFile(forReading: URL(fileURLWithPath: file))) } catch { Isolation.note("wake-test: \(error.localizedDescription)"); once(nil) }
        }
        guard let wav else {
            var r = Response(status: "no_wake"); r.error = "No \"\(Wake.phrase)\" heard in the file."; return r
        }
        handling = false
        return await handle(wav: wav, dryRun: dryRun, testOnly: true)
    }

    func handle(wav: Data, dryRun: Bool, testOnly: Bool = false) async -> Response {
        handling = true
        defer { handling = false; countdown = nil; oneShot = false; refresh() }

        let transcript: String
        do {
            SpeechIO.keepSample(wav, kind: "command")
            let heard = try await SpeechIO.transcribe(audio: wav)
            // The listener already heard the wake word; if this second pass over the
            // command audio spells it differently, do not throw the command away.
            transcript = Wake.containsWakeWord(heard) || heard.isEmpty ? heard : Wake.phrase + ", " + heard
            if !testOnly { Subtitles.shared.userFinal(heard) }
        } catch {
            return record(nil, text: "", transcript: "", outcome: .error, error: error.localizedDescription)
        }
        return await route(transcript, dryRun: dryRun, testOnly: testOnly)
    }

    /// Test hook and second half of `handle`: route a transcript, count down on the island, deliver.
    func route(_ transcript: String, dryRun: Bool, testOnly requested: Bool = false) async -> Response {
        // Fail closed: once a test pane was armed, live voice commands go only to
        // armed panes, even after the lock expired (then nothing is sent) until
        // `needs-you wake-test --arm-pane none` ends the test. An expired lock once
        // sent "Test four." into a real chat.
        let testOnly = requested || !Router.armedPanes.isEmpty
        // "Good night", "I'm back", "What did you work on last night?" (HM-1352).
        if let rest = Wake.afterWakeWord(transcript), let p = PresenceCommand.parse(rest) {
            if requested || dryRun { var r = Response(status: "dry_run"); r.state = "presence: \(p)"; return r }
            handling = true
            defer { handling = false; refresh() }
            return await presence(p, transcript: transcript)
        }
        handling = true
        defer { handling = false; countdown = nil; refresh() }
        let targets = await Router.voiceTargets(testOnly: testOnly)
        if testOnly && targets.count != 1 {
            let why = Router.armedPanes.isEmpty
                ? "Not sent: tests need exactly one armed test pane (needs-you wake-test --arm-pane <pane>)."
                : "Not sent: the test lock expired or its pane is not a test pane. Re-arm it, or end the test with needs-you wake-test --arm-pane none."
            if requested { return errorResponse(why) }
            return record(nil, text: "", transcript: transcript, outcome: .error, error: why)
        }
        var (parsed, routeLog) = testOnly ? Router.parseLogged(transcript, targets: targets) : await Router.parseSmart(transcript, targets: targets)
        routeNote = routeLog
        defer { routeNote = nil }
        Isolation.note("route: " + routeLog)
        if testOnly {
            // Tests go to the one armed pane by its exact id: no title fuzzing, no focus, no voice questions.
            switch parsed {
            case .send(_, let m), .choose(_, let m, _): parsed = .send(targets[0], m)
            // No chat named and no explicit "new chat": a live test goes to the armed pane too.
            case .newChat(nil, let m) where Router.testRoot == nil: parsed = .send(targets[0], m)
            case .nothing, .newChat: break
            }
        }

        if case .choose(let options, let text, let heard) = parsed {
            if options.isEmpty { parsed = .nothing("No chats found.") }
            else {
                let names = options.map { Self.short($0.title) }
                let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + ", or " + names.last! : names[0]
                let q = heard.isEmpty ? "Which chat? \(list)?" : "I'm not sure which chat you meant. \(list)?"
                if let answer = await Conductor.shared.voiceClarify(q), let pick = Router.pick(answer, from: options) {
                    parsed = .send(pick, text)
                } else {
                    Sounds.shared.play(.cancelled)
                    await Conductor.shared.speakOnly("Okay, I didn't send it.")
                    return record(nil, text: text, transcript: transcript, outcome: .cancelled, error: "No chat chosen")
                }
            }
        }

        switch parsed {
        case .nothing(let why):
            Sounds.shared.play(.cancelled)
            Island.shared.error("Not sent", Island.oneLine(why))
            return record(nil, text: "", transcript: transcript, outcome: .cancelled, error: why)
        case .choose:
            return errorResponse("unreachable")
        case .newChat(let heardProject, let heardText):
            return await newChat(project: heardProject, heardText: heardText, transcript: transcript, dryRun: dryRun, testOnly: testOnly)
        case .send(let target, let heardText):
            let text = await TranscriptCleaner.clean(heardText)
            if dryRun {
                var r = Response(status: "dry_run"); r.transcript = text; r.state = target.title; return r
            }
            let previous = NSWorkspace.shared.frontmostApplication
            Sounds.shared.play(.sending)
            let go = await countDown(to: Self.short(target.title))
            if !go {
                Sounds.shared.play(.cancelled)
                if target.kind != .desktop && target.kind != .registered { previous?.activate() }
                return record(target, text: text, transcript: transcript, outcome: .cancelled, error: nil)
            }
            let delivered = text + "\n" + Router.voiceSuffix
            do {
                try await Router.deliver(delivered, to: target)
                Sounds.shared.play(.sent)
                if target.kind == .registered {
                    // Waits in the chat's inbox for its next tool call or turn end (HM-1364).
                    Island.shared.queued(for: Self.short(target.title))
                    var r = record(target, text: delivered, transcript: transcript, outcome: .sent, error: nil)
                    r.status = "queued"
                    return r
                }
                if target.kind != .desktop { previous?.activate() }
                return record(target, text: delivered, transcript: transcript, outcome: .sent, error: nil)
            } catch {
                Sounds.shared.play(.cancelled)
                Island.shared.error("Not sent", Island.oneLine(error.localizedDescription))
                return record(target, text: text, transcript: transcript, outcome: .error, error: error.localizedDescription)
            }
        }
    }

    /// Do not disturb on or off by voice, and the voicemails.
    private func presence(_ p: PresenceCommand, transcript: String) async -> Response {
        let dnd = DoNotDisturb.shared
        var c = Conversation(id: "dnd-" + UUID().uuidString.prefix(8).lowercased(), title: "Do not disturb",
                             message: transcript, startedAt: Date())
        c.kind = "send"
        c.turns = [Turn(role: .user, text: transcript)]
        c.outcome = .done
        c.endedAt = Date()
        switch p {
        case .away(let night):
            // On first, so an agent asking right now already gets a voicemail.
            await Sounds.shared.playAndWait(.dndOn)
            dnd.turnOn(goodNight: night)
            c.title = night ? "Good night: do not disturb" : "Do not disturb"
            Conductor.shared.record(c)
            await Conductor.shared.speakOnly(night ? "Good night\(UserName.commaName). I'll keep the messages for the morning."
                                                   : "Okay. I'll keep the messages until you're back.")
        case .back(let summary):
            let night = dnd.state.goodNight
            if dnd.on { await Sounds.shared.playAndWait(.dndOff) }
            dnd.turnOff()
            c.title = "Back: do not disturb off"
            Conductor.shared.record(c)
            await Conductor.shared.playVoicemails(greeting: night ? "Good morning\(UserName.commaName)." : "Welcome back\(UserName.commaName).", summary: summary)
        case .playVoicemails:
            c.title = "Play voicemails"
            Conductor.shared.record(c)
            await Conductor.shared.playVoicemails(greeting: nil, summary: false)
        case .summary:
            c.title = "What did you work on?"
            Conductor.shared.record(c)
            await Conductor.shared.speakSummary()
        }
        var r = Response(status: "done"); r.state = "presence: \(p)"; return r
    }

    /// "Hey Claude, new chat in <project>: ..." or nothing matched: open a new claude chat in herdr.
    private func newChat(project: String?, heardText: String, transcript: String, dryRun: Bool, testOnly: Bool) async -> Response {
        if testOnly && Router.testRoot == nil { return errorResponse("New-chat tests need --projects-root <throwaway folder>.") }
        let text = await TranscriptCleaner.clean(heardText)
        let home = testOnly ? Router.testRoot! : NSHomeDirectory()
        let projectsRoot = testOnly ? Router.testRoot! : NSHomeDirectory() + "/Projects"
        var dir = home, label = "your home folder", tabLabel = "voice"
        var missing: String?
        if let p = project, !p.isEmpty {
            let ranked = Router.rankFolders(p, Router.projectFolders(root: projectsRoot))
            if let best = ranked.first, testOnly || (best.score >= 0.6 && (ranked.dropFirst().first?.score ?? 0) <= best.score - 0.25) {
                dir = best.folder.path; label = best.folder.name; tabLabel = "voice: " + best.folder.name
            } else if !ranked.isEmpty {
                let opts = ranked.prefix(3).map(\.folder)
                let names = opts.map(\.name)
                let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + ", or " + names.last! : names[0]
                if let answer = await Conductor.shared.voiceClarify("Which project? \(list)?"),
                   let pick = Router.rankFolders(answer, Array(opts)).first?.folder {
                    dir = pick.path; label = pick.name; tabLabel = "voice: " + pick.name
                } else {
                    Sounds.shared.play(.cancelled)
                    await Conductor.shared.speakOnly("Okay, I didn't start a chat.")
                    return record(nil, text: text, transcript: transcript, outcome: .cancelled, error: "No project chosen")
                }
            } else {
                missing = p
            }
        }
        if dryRun {
            var r = Response(status: "dry_run"); r.state = "New chat in \(label)"; r.transcript = text; return r
        }
        let previous = NSWorkspace.shared.frontmostApplication
        Sounds.shared.play(.sending)
        let go = await countDown(to: "New chat in \(label)")
        guard go else {
            Sounds.shared.play(.cancelled)
            return record(nil, text: text, transcript: transcript, outcome: .cancelled, error: nil)
        }
        let delivered = text + "\n" + Router.voiceSuffix
        do {
            let target = try await Router.startNewChat(in: dir, label: testOnly ? "needs-you test: " + label : tabLabel, focus: !testOnly)
            try await Router.deliver(delivered, to: target)
            Sounds.shared.play(.sent)
            previous?.activate()
            let where_ = label == "your home folder" ? "in your home folder" : "in \(label)"
            let said = missing.map { "I couldn't find a project called \($0), so I started a new chat \(where_)." }
                ?? "Started a new chat \(where_)."
            await Conductor.shared.speakOnly(said)
            var t = target; t.title = "New chat in \(label)"
            return record(t, text: delivered, transcript: transcript, outcome: .sent, error: nil)
        } catch {
            Sounds.shared.play(.cancelled)
            Island.shared.error("Not sent", Island.oneLine(error.localizedDescription))
            return record(nil, text: delivered, transcript: transcript, outcome: .error, error: error.localizedDescription)
        }
    }

    /// Escape during the countdown (Hotkeys): true if a send was waiting.
    func cancelPendingSend() -> Bool {
        guard let countdown else { return false }
        countdown.cancel()
        return true
    }

    /// Shows the send on the island and waits; false if he cancelled.
    private func countDown(to target: String, seconds: Double = 2) async -> Bool {
        let c = SendCountdown()
        countdown = c
        Island.shared.sending(to: target, seconds: seconds)
        Hotkeys.shared.escapeWhileSending(true)
        if listener.isRunning { listener.startCancelWatch() }
        let go = await c.run(seconds: seconds)
        listener.stopCancelWatch()
        Hotkeys.shared.escapeWhileSending(false)
        if !go { Island.shared.sendCancelled() }
        return go
    }

    static func short(_ title: String) -> String {
        title.split(separator: " ").prefix(6).joined(separator: " ")
    }

    private func record(_ target: ChatTarget?, text: String, transcript: String, outcome: Conversation.Outcome, error: String?) -> Response {
        var c = Conversation(id: "send-" + UUID().uuidString.prefix(8).lowercased(),
                             title: target.map { "To \($0.title)" } ?? "Hey Claude",
                             message: text.isEmpty ? transcript : text, startedAt: Date())
        c.kind = "send"
        c.target = target?.title
        c.route = routeNote
        c.turns = [Turn(role: .user, text: text.isEmpty ? transcript : text, original: transcript)]
        c.outcome = outcome
        c.error = error
        c.endedAt = Date()
        Conductor.shared.record(c)
        var r = Response(status: outcome.rawValue)
        r.transcript = text.isEmpty ? transcript : text
        r.state = target?.title
        r.error = error
        r.conversationID = c.id
        return r
    }

    /// The routing log line of the command being handled, saved with its history entry.
    private var routeNote: String?

    private func errorResponse(_ m: String) -> Response { var r = Response(status: "error"); r.error = m; return r }
}

// MARK: - Send countdown

/// The 2 s between hearing a command and typing it: the island shows where it goes
/// (`Island.sending`), and "cancel" or Escape stops it. No window of its own.
@MainActor
final class SendCountdown {
    private(set) var cancelled = false

    func cancel() { cancelled = true }

    /// True if it ran out without being cancelled.
    func run(seconds: Double) async -> Bool {
        let steps = 40
        for _ in 1...steps {
            try? await Task.sleep(nanoseconds: UInt64(seconds / Double(steps) * 1_000_000_000))
            if cancelled { break }
        }
        return !cancelled
    }
}
