import AppKit
import AVFoundation
import Combine
import NeedsYouShared
import SwiftUI

/// "Hey Mac, <chat>: <message>" -> the message typed into that chat.
@MainActor
final class VoiceCommands: ObservableObject {
    static let shared = VoiceCommands()

    @Published private(set) var status = "Off"
    /// True while the mic is open for the wake word (menu bar dot).
    @Published private(set) var armed = false
    @Published private(set) var capturing = false {
        didSet { if capturing != oldValue { Hotkeys.shared.escapeWhileCapturing(capturing) } }
    }
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
    /// The turn shortcut opened the mic while "Listen for Hey Mac" is off: on for one command.
    private var oneShot = false
    private var cancellables: Set<AnyCancellable> = []
    /// The 2 s before a command is typed into a chat (shown on the island).
    private var countdown: SendCountdown?

    /// A message he said whose chat he did not name clearly (HM-1364).
    struct Unsent { var text: String; var options: [ChatTarget]; var at: Date }
    private var unsent: Unsent?

    static func whichChatQuestion(_ names: [String], heardName: String, again: Bool) -> String {
        if again {
            return names.count > 1 ? "Sorry, which one? Say or press 1 to \(names.count)." : "Sorry, send it to \(names[0])? Say yes or no."
        }
        let list: String
        if names.count > 1 {
            // Numbered, so he can press 1 to 4 or say the number (HM-1364).
            let items = names.enumerated().map { "\($0.offset + 1), \($0.element)" }
            list = items.dropLast().joined(separator: ". ") + ". Or " + items.last!
        } else { list = names[0] }
        return heardName.isEmpty ? "Which chat? \(list)?" : "I'm not sure which chat you meant. \(list)?"
    }

    /// "Which chat then?" after an unclear answer (HM-1408): what it is about, or the closest chats by number.
    static func followUpQuestion(_ names: [String]) -> String {
        let base = "Which chat then? Tell me what it's about."
        guard !names.isEmpty else { return base }
        if names.count == 1 { return base + " Or is it \(names[0])?" }
        let items = names.enumerated().map { "\($0.offset + 1), \($0.element)" }
        return base + " Or pick one: " + items.dropLast().joined(separator: ". ") + ". Or " + items.last! + "."
    }

    enum ClarifyResult {
        /// `how`: "picked" (an offered chat, by voice or number) or "confirmed" (yes to "Send it to ...?").
        case picked(ChatTarget, how: String)
        case cancelled(String)
        /// He did not answer: the message is kept unsent.
        case unanswered
        /// He pressed Escape once (HM-1429): closed quietly, the message is kept unsent.
        case closed
    }

    /// "Which chat?" as a conversation with no round limit (HM-1408): keeps his message and every
    /// question and answer; after each answer every chat is searched again by meaning and by the
    /// on-device model, with the whole conversation. One clear fit: "Send it to ...?". Unclear:
    /// "Which chat then?". Only an explicit stop (the model reads it), Escape twice, or silence
    /// ends it without a chat. Pressing 1 to 4 picks an offered chat. `all`: every target.
    /// `test`: the clarify-test hook (muted, file input). Returns the turns for the history.
    func askWhichChat(_ options: [ChatTarget], heardName: String, message: String, all: [ChatTarget] = [], test: Request? = nil,
                      heard: ((String) -> Void)? = nil) async -> (ClarifyResult, [Turn]) {
        let everyone = options + all.filter { a in !options.contains { $0.key == a.key } }
        let allNames = everyone.map { Self.short($0.title) }
        var convo = ClarifyConversation(message: message, offered: Array(options.indices))
        var turns: [Turn] = []
        var question = Self.whichChatQuestion(options.map { Self.short($0.title) }, heardName: heardName, again: false)
        while true {
            convo.asked(question)
            turns.append(Turn(role: .agent, text: question))
            let offeredNames = convo.offered.map { allNames[$0] }
            let answer = await Conductor.shared.voiceClarify(question, choices: offeredNames.count, test: test)
            switch Conductor.shared.clarifyEscape {
            case .reset?:
                Isolation.note("clarify: Escape twice -> reset")
                return (.cancelled("Escape pressed twice"), turns)
            case .close?:
                Isolation.note("clarify: Escape -> closed, kept unsent")
                return (.closed, turns)
            case nil: break
            }
            guard let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Isolation.note("clarify: no answer -> kept unsent")
                return (.unanswered, turns)
            }
            heard?(answer)
            let number = Int(answer.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { convo.offered.indices.contains($0 - 1) ? $0 : nil }
            turns.append(Turn(role: .user, text: number.map { "Pressed \($0)" } ?? answer))
            let wasConfirming = convo.confirming != nil
            var reading = ClarifyConversation.Reading()
            var byName: Int?
            var missing: String?
            if number == nil {
                convo.answered(answer)
                let clean = ChoicePick.stripEcho(answer, question: question, names: offeredNames)
                byName = ChoicePick.name(clean, names: allNames)
                // The on-device model reads it with the whole conversation; without one, the names do.
                reading = await ModelRouter.shared.converse(convo, chats: everyone) ?? ClarifyConversation.Reading(chat: byName)
                // A name he said (HM-1425): matched against every chat's tab, workspace, folder and title.
                let named = ClarifyConversation.spokenName(reading.named, in: clean)
                if !named.isEmpty {
                    switch ClarifyConversation.nameMatch(named, everyone.map(\.candidate)) {
                    case .chat(let i): byName = i
                    case .missing: missing = named
                    case .unclear: break
                    }
                }
            }
            let meaning = MeaningIndex.shared.rank(convo.searchText(about: reading.about), everyone)
            let step = convo.next(reading, pressed: number, meaning: meaning.scores, byName: byName, missingName: missing)
            Isolation.note("clarify: \u{201C}\(answer)\u{201D} -> \(step); meaning \(Meaning.describe(meaning.scores)); name \(byName.map { String($0 + 1) } ?? "-")\(missing.map { "; no chat called \u{201C}\($0)\u{201D}" } ?? "")")
            switch step {
            case .send(let i): return (.picked(everyone[i], how: wasConfirming ? "confirmed" : "picked"), turns)
            case .cancel: return (.cancelled("He said not to send it"), turns)
            case .confirm(let i):
                question = (missing.map { "I can't find a chat called \($0). " } ?? "") + "Send it to \(allNames[i])?"
            case .ask(let idx): question = Self.followUpQuestion(idx.map { allNames[$0] })
            case .notFound(let name): question = "I can't find a chat called \(name). Which one? Tell me what it's about."
            }
        }
    }

    /// Test hook: needs-you clarify-test --title "recipebox|orchard" --vad-file <wav> [--mute].
    /// Runs "which chat?" through the real listening path with the file as the mic.
    func clarifyTest(_ req: Request) async -> Response {
        let names = (req.context ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { var r = Response(status: "error"); r.error = "clarify-test needs --title \"a|b\""; return r }
        let options = names.enumerated().map { ChatTarget(kind: .registered, id: "test-\($0.offset)", title: $0.element, aliases: [], focused: false) }
        var t = req; t.mute = true
        var answers: [String] = []
        let (result, _) = await askWhichChat(options, heardName: "", message: "test", test: t) { answers.append($0) }
        var r = Response(status: "measured")
        r.transcript = answers.joined(separator: " | ")
        switch result {
        case .picked(let p, let how): r.state = "\(how) \(p.title)"
        case .cancelled(let why): r.state = "cancelled: \(why)"
        case .unanswered: r.state = "unanswered"
        case .closed: r.state = "closed"
        }
        return r
    }

    func setUp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { ModelRouter.shared.wake() } // first pick not cold (HM-1364)
        phoneListener.source = "iphone"
        for (l, other) in [(listener, phoneListener), (phoneListener, listener)] {
            let src = l === listener ? "mac" : "iphone"
            l.onCommandPartial = { text, swap in DispatchQueue.main.async { Subtitles.shared.userPartial(text, source: src, swap: swap); ModelRouter.shared.partial(text) } }
            l.onCommandLevel = { v in DispatchQueue.main.async { Subtitles.shared.level(v, .user, source: src) } }
            l.onHeard = { [weak self] text in DispatchQueue.main.async { self?.noteHeard(text) } }
            l.onCommandMode = { [weak self, weak l] on in
                Ducker.shared.set("command:\(src)", on)
                if !on { DispatchQueue.main.async { self?.commandClosed(src, l) } }
            }
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
        listener.onCancelWord = { [weak self] heard in DispatchQueue.main.async { self?.countdown?.cancel(by: "spoken \u{201C}\(heard)\u{201D}") } }
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
    /// The user is saying a Hey Mac command, or one is being handled or sent.
    var userHasFloor: Bool { capturing || handling }
    /// The room mic hears someone talking (gate open), outside a command.
    var hearingSomeone: Bool { listener.isRunning && listener.hearingSomeone }
    var noiseReduction: Bool { listener.isRunning && listener.noiseReductionActive }

    /// Runs the mic only when nothing else is using it, so it never hears Needs You itself.
    func refresh() {
        guard enabled || oneShot else { stopListening("Off"); return }
        guard WakeListener.authorized else {
            stopListening("Speech Recognition is not allowed")
            PermissionSettings.needs(.speechRecognition) // HM-1405: only once it was denied, not before the first ask
            return
        }
        if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) {
            stopListening("Microphone access is off")
            PermissionSettings.needs(.microphone)
            return
        }
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
    /// HM-1414: a mic's command ended. Its words normally follow at once (take, pick); the
    /// island stops showing listening now. When no words ever come (the mic was stopped or
    /// the command dropped mid-way), his turn is over: nothing may stay "listening", and
    /// agents may talk again (`capturing` held them back).
    private func commandClosed(_ src: String, _ l: WakeListener?) {
        if l?.commandOpen == true { return } // a new command opened at once: still his turn
        Island.shared.micClosed(source: src)
        let at = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.capturing, self.firstTake == nil, !self.handling, self.lastTakeAt < at,
                  !self.listener.commandOpen, !self.phoneListener.commandOpen else { return }
            Isolation.note("voice: \(src) command ended without words; turn closed")
            self.escClosed = nil
            self.capturing = false
            Subtitles.shared.userStopped()
            Island.shared.idle()
            if self.oneShot { self.oneShot = false; self.refresh() }
        }
    }

    private var lastTakeAt = Date.distantPast

    private func take(_ source: String, _ wav: Data, _ score: Float?, _ snr: Float) {
        lastTakeAt = Date()
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
            if !testOnly && escClosed == nil { Subtitles.shared.userFinal(heard) }
        } catch {
            escClosed = nil
            return record(nil, text: "", transcript: "", outcome: .error, error: error.localizedDescription)
        }
        // Escape closed it (HM-1429): kept, not sent; nothing is routed.
        if !testOnly, let at = escClosed, Date().timeIntervalSince(at) < 60 {
            escClosed = nil
            let text = Wake.afterWakeWord(transcript) ?? transcript
            return await keepClosed(at, text: text, transcript: transcript, options: await Router.voiceTargets(testOnly: false))
        }
        return await route(transcript, dryRun: dryRun, testOnly: testOnly)
    }

    /// Test hook and second half of `handle`: route a transcript, count down on the island, deliver.
    func route(_ transcript: String, dryRun: Bool, testOnly requested: Bool = false, forced: ChatTarget? = nil) async -> Response {
        // Every return below records the command in the history (HM-1408), dry runs aside.
        // Fail closed: once a test pane was armed, live voice commands go only to
        // armed panes, even after the lock expired (then nothing is sent) until
        // `needs-you wake-test --arm-pane none` ends the test. An expired lock once
        // sent "Test four." into a real chat.
        let testOnly = requested || !Router.armedPanes.isEmpty
        handling = true
        defer { handling = false; countdown = nil; refresh() }
        let targets = await Router.voiceTargets(testOnly: testOnly)
        if testOnly && targets.count != 1 {
            let why = Router.armedPanes.isEmpty
                ? "Not sent: tests need exactly one armed test pane (needs-you wake-test --arm-pane <pane>)."
                : "Not sent: the test lock expired or its pane is not a test pane. Re-arm it, or end the test with needs-you wake-test --arm-pane none."
            return record(nil, text: "", transcript: transcript, outcome: .error, error: why)
        }
        // A message kept after "which chat?" got no clear answer: "Hey Mac, orchard" (or "two") sends it.
        if !testOnly, let u = unsent, Date().timeIntervalSince(u.at) < 300, let rest = Wake.afterWakeWord(transcript),
           rest.split(separator: " ").count <= 4 { // short: a name or a number for the kept message
            let names = u.options.map { Self.short($0.title) }
            let fresh = targets.filter { t in u.options.contains { $0.id == t.id } }
            let read = await ModelRouter.shared.choose(rest, question: Self.whichChatQuestion(names, heardName: "", again: false), chats: u.options)
            let i = read.map { $0.index } ?? ChoicePick.name(rest, names: names)
            if let i, fresh.contains(where: { $0.id == u.options[i].id }) {
                unsent = nil
                return await route(Wake.phrase + ", " + Self.short(u.options[i].title) + ": " + u.text, dryRun: dryRun, testOnly: requested, forced: u.options[i])
            }
        }
        // A test with an armed pane sends the whole sentence there; the model is not asked.
        var (parsed, routeLog): (Router.Parsed, String) = testOnly && Router.testRoot == nil
            ? (.send(targets[0], Router.clean(Wake.afterWakeWord(transcript) ?? transcript)), "test pane")
            : await Router.parseSmart(transcript, targets: targets)
        if let forced, case .send(_, let m) = parsed { parsed = .send(forced, m) }
        else if let forced, case .choose(_, let m, _) = parsed { parsed = .send(forced, m) }
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
            // Tests never open or type into a real chat app, or change do not disturb.
            case .app: parsed = .nothing("Tests never open chat apps.")
            case .presence: parsed = .nothing("Tests never change do not disturb.")
            }
        }

        // How the chat was found, saved with the message when it goes out (HM-1408).
        var matchedBy = forced != nil ? "kept" : Router.lastReading?.intent?.named.isEmpty == false ? "named" : "routed"
        var clarifyTurns: [Turn] = []
        if case .choose(let options, let text, let heard) = parsed {
            if options.isEmpty {
                // He named something no chat matches (HM-1383): say so, never send it elsewhere.
                let why = heard.isEmpty ? "No chats are open that I can reach." : "I can't find a chat called \(heard)."
                if !dryRun && !testOnly {
                    Sounds.shared.play(.cancelled)
                    await Conductor.shared.speakOnly(why + (heard.isEmpty ? " Connect one in Settings, Agents." : " Connect it in Settings, Agents, or say new chat in \(heard)."))
                }
                return record(nil, text: text, transcript: transcript, outcome: .notSent,
                              error: heard.isEmpty ? "no chat open" : "not found: no chat called \u{201C}\(heard)\u{201D}")
            }
            let (result, turns) = await askWhichChat(options, heardName: heard, message: text, all: targets)
            clarifyTurns = turns
            switch result {
            case .picked(let pick, let h):
                matchedBy = h
                parsed = .send(pick, text)
            case .closed:
                unsent = Unsent(text: text, options: options, at: Date())
                Island.shared.idle()
                var r = record(nil, text: text, transcript: transcript, outcome: .notSent, error: "closed with Escape; kept for 5 minutes", turns: turns)
                r.status = "kept"
                return r
            case .cancelled(let why) where why == "Escape pressed twice":
                return record(nil, text: text, transcript: transcript, outcome: .cancelled, error: why, turns: turns)
            case .cancelled(let why):
                Sounds.shared.play(.cancelled)
                await Conductor.shared.speakOnly("Okay, I didn't send it.")
                return record(nil, text: text, transcript: transcript, outcome: .cancelled, error: why, turns: turns)
            case .unanswered:
                // Never drop it: it waits for "Hey Mac, <chat>" (or a number) for 5 minutes.
                unsent = Unsent(text: text, options: options, at: Date())
                Sounds.shared.play(.cancelled)
                Island.shared.error("Not sent", "Say the chat: \u{201C}\(Wake.phrase), \(Self.short(options[0].title))\u{201D}")
                await Conductor.shared.speakOnly("I kept your message. Say \(Wake.phrase) and the chat's name to send it.")
                return record(nil, text: text, transcript: transcript, outcome: .notSent, error: "no chat chosen; kept for 5 minutes", turns: turns)
            }
        }

        switch parsed {
        case .presence(let p):
            // "Good night", "I'm back", "What did you work on last night?" (HM-1352), as the model read it.
            if dryRun { var r = Response(status: "dry_run"); r.state = "presence: \(p)"; return r }
            return await presence(p, transcript: transcript)
        case .nothing(let why):
            Sounds.shared.play(.cancelled)
            Island.shared.error("Not sent", Island.oneLine(why))
            return record(nil, text: "", transcript: transcript, outcome: .notSent, error: why)
        case .choose(_, let m, _):
            return record(nil, text: m, transcript: transcript, outcome: .error, error: "no chat chosen")
        case .newChat(let heardProject, let heardText):
            return await newChat(project: heardProject, heardText: heardText, transcript: transcript, dryRun: dryRun, testOnly: testOnly)
        case .app(let app, let heardText, let fresh):
            return await appChat(app, heardText: heardText, newChat: fresh, transcript: transcript, dryRun: dryRun)
        case .send(let target, let heardText):
            let text = await TranscriptCleaner.clean(heardText)
            if dryRun {
                var r = Response(status: "dry_run"); r.transcript = text; r.state = target.title; return r
            }
            Sounds.shared.play(.sending)
            let closedAt = Escape.lastClose
            let go = await countDown(to: Self.short(target.title))
            if !go, countdown?.cancelledBy?.hasPrefix("Escape") == true {
                return await keepClosed(Escape.lastClose ?? closedAt, text: text, transcript: transcript, options: [target], target: target, turns: clarifyTurns)
            }
            if !go {
                Sounds.shared.play(.cancelled)
                return record(target, text: text, transcript: transcript, outcome: .cancelled, error: nil, turns: clarifyTurns)
            }
            // A chat app without Needs You can't answer out loud: no voice line, and it stays in front.
            // One with it gets this Mac's name, so only this Mac speaks the reply (HM-1398).
            let quietApp = target.kind == .desktop && !Router.appHasNeedsYou(target.id)
            let delivered = quietApp ? text : text + "\n" + (target.kind == .desktop ? Router.appVoiceSuffix : Router.voiceSuffix)
            do {
                let how = try await Router.deliver(delivered, to: target, stayInFront: quietApp)
                Sounds.shared.play(.sent)
                // Every message that found its chat is learned: messages like it lean to that chat (HM-1408).
                if !testOnly { RouteLearningStore.shared.learn(heardText, target: target, source: target.byFocus ? "front" : matchedBy) }
                if case .queued(let why) = how {
                    // Busy, or a typing check failed (HM-1374): waits in the chat's inbox for its next hook or inbox call (HM-1364).
                    // History says "Queued" until the chat really takes it.
                    Isolation.note("queued for \(target.title): \(why)")
                    var r = record(target, text: delivered, transcript: transcript, outcome: .queued, error: nil, turns: clarifyTurns)
                    ChatRegistry.shared.enqueue(delivered, for: target.id, convoID: r.conversationID)
                    ChatRegistry.shared.spokeTo(target.id)
                    Island.shared.queued(for: Self.short(target.title))
                    r.status = "queued"
                    r.state = why
                    return r
                }
                // Typed (HM-1374): AXDelivery already put his app, window, field and clipboard back.
                return record(target, text: delivered, transcript: transcript, outcome: .sent, error: nil, turns: clarifyTurns)
            } catch {
                Sounds.shared.play(.cancelled)
                Island.shared.error("Not sent", Island.oneLine(error.localizedDescription))
                return record(target, text: text, transcript: transcript, outcome: .error, error: error.localizedDescription, turns: clarifyTurns)
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
        case .listChats:
            c.title = "List my chats"
            Conductor.shared.record(c)
            let reg = ChatRegistry.shared
            await Conductor.shared.speakOnly(ChatsSpeech.line(reg.reachable) { reg.queuedCount($0) })
        }
        var r = Response(status: "done"); r.state = "presence: \(p)"; return r
    }

    /// "Hey Mac, new chat in <project>: ..." or nothing matched: open a new claude chat in herdr.
    private func newChat(project: String?, heardText: String, transcript: String, dryRun: Bool, testOnly: Bool) async -> Response {
        if testOnly && Router.testRoot == nil { return record(nil, text: heardText, transcript: transcript, outcome: .error, error: "New-chat tests need --projects-root <throwaway folder>.") }
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
                    return record(nil, text: text, transcript: transcript, outcome: .notSent, error: "no project chosen")
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
            if countdown?.cancelledBy?.hasPrefix("Escape") == true {
                return await keepClosed(Escape.lastClose, text: text, transcript: transcript, options: [])
            }
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

    /// "Hey Mac, new chat on Claude desktop, ask ..." / "use ChatGPT to ask ..." (HM-1383).
    private func appChat(_ app: Router.ChatApp, heardText: String, newChat: Bool, transcript: String, dryRun: Bool) async -> Response {
        let text = await TranscriptCleaner.clean(heardText)
        let label = newChat ? "New chat in \(app.title)" : app.title
        if dryRun {
            var r = Response(status: "dry_run"); r.state = label; r.transcript = text; return r
        }
        Sounds.shared.play(.sending)
        guard await countDown(to: label) else {
            if countdown?.cancelledBy?.hasPrefix("Escape") == true {
                return await keepClosed(Escape.lastClose, text: text, transcript: transcript, options: [])
            }
            Sounds.shared.play(.cancelled)
            return record(nil, text: text, transcript: transcript, outcome: .cancelled, error: nil)
        }
        let voice = Router.appHasNeedsYou(app.bundle)
        let delivered = voice ? text + "\n" + Router.appVoiceSuffix : text // only this Mac speaks the reply (HM-1398)
        do {
            let target = newChat
                ? try await Router.startAppChat(app)
                : ChatTarget(kind: .desktop, id: app.bundle, title: app.title, aliases: app.aliases, focused: false)
            try await Router.deliver(delivered, to: target, stayInFront: !voice)
            Sounds.shared.play(.sent)
            var t = target; t.title = label
            return record(t, text: delivered, transcript: transcript, outcome: .sent, error: nil)
        } catch {
            Sounds.shared.play(.cancelled)
            Island.shared.error("Not sent", Island.oneLine(error.localizedDescription))
            return record(nil, text: text, transcript: transcript, outcome: .error, error: error.localizedDescription)
        }
    }

    /// When Escape closed his command (HM-1429): its words are kept, not sent.
    private var escClosed: Date?

    /// Escape once while he says a command (HM-1429): listening stops now and the pill
    /// folds away; what he said so far is kept, not sent (`handle` keeps it).
    func closeCommand() {
        escClosed = Escape.lastClose ?? Date()
        listener.endTurn(); phoneListener.endTurn()
        Subtitles.shared.userStopped()
        Island.shared.idle()
        Sounds.shared.play(.gotIt)
        if oneShot { oneShot = false }
        Isolation.note("keys: Escape, command closed (kept, not sent)")
    }

    /// Escape twice (HM-1429): everything in flight is cancelled and nothing is kept.
    func resetAll() {
        countdown?.cancel(by: "Escape twice")
        listener.cancelCommand(); phoneListener.cancelCommand()
        listener.stopCancelWatch()
        firstTake = nil
        unsent = nil
        escClosed = nil
        capturing = false
        if oneShot { oneShot = false }
        refresh()
        Isolation.note("keys: Escape twice, reset: command, kept message and countdown dropped")
    }

    /// Escape during the countdown (Hotkeys): true if a send was waiting.
    func closePendingSend() -> Bool {
        guard let countdown, !countdown.cancelled else { return false }
        countdown.cancel(by: "Escape")
        return true
    }

    /// After Escape closed something: the message is kept unsent (HM-1429), or dropped
    /// when a second Escape reset it. `options`: the chats "Hey Mac, <chat>" can send it to.
    private func keepClosed(_ at: Date?, text: String, transcript: String, options: [ChatTarget], target: ChatTarget? = nil, turns: [Turn] = []) async -> Response {
        Island.shared.idle()
        if await Escape.settle(at) == .reset {
            return record(target, text: text, transcript: transcript, outcome: .cancelled, error: "Escape pressed twice: dropped", turns: turns)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Response(status: "kept") }
        if !options.isEmpty { unsent = Unsent(text: text, options: options, at: Date()) }
        var r = record(target, text: text, transcript: transcript, outcome: .notSent,
                       error: options.isEmpty ? "closed with Escape; not sent" : "closed with Escape; kept for 5 minutes", turns: turns)
        r.status = "kept"
        return r
    }

    /// Shows the send on the island and waits; false if he cancelled.
    private func countDown(to target: String, seconds: Double = 2) async -> Bool {
        let c = SendCountdown()
        countdown = c
        Island.shared.sending(to: target, seconds: seconds)
        Hotkeys.shared.escapeWhileSending(true)
        // After "which chat?" the room mic is still off (it was the answer's): then only Escape stops it.
        let watching = listener.isRunning
        if watching { listener.startCancelWatch() }
        Isolation.note("countdown: \(seconds) s to \(target), \(watching ? "Escape or saying cancel stops it" : "Escape stops it (mic off)")")
        let go = await c.run(seconds: seconds)
        listener.stopCancelWatch()
        Hotkeys.shared.escapeWhileSending(false)
        if !go {
            if c.cancelledBy?.hasPrefix("Escape") == true { Island.shared.idle() } else { Island.shared.sendCancelled() }
            Isolation.note("countdown: cancelled by \(c.cancelledBy ?? "?")")
        }
        return go
    }

    static func short(_ title: String) -> String {
        title.split(separator: " ").prefix(6).joined(separator: " ")
    }

    private func record(_ target: ChatTarget?, text: String, transcript: String, outcome: Conversation.Outcome, error: String?, turns: [Turn] = []) -> Response {
        var c = Conversation(id: "send-" + UUID().uuidString.prefix(8).lowercased(),
                             title: target.map { "To \($0.title)" } ?? "Hey Mac",
                             message: text.isEmpty ? transcript : text, startedAt: Date())
        c.kind = "send"
        c.target = target?.title
        c.route = routeNote
        if let t = target {
            switch t.kind {
            case .registered:
                if let chat = ChatRegistry.shared.chats[t.id] { c.agent = chat.agent; if !chat.cwd.isEmpty { c.cwd = chat.cwd } }
            case .desktop: c.agent = t.id == Router.desktopBundleID ? "claude-app" : t.id.hasPrefix("com.openai.") ? "chatgpt" : nil
            case .herdrAgent: c.agent = "claude"
            case .herdrPane: break
            }
        }
        // His command, then the "which chat?" conversation, if there was one (HM-1408).
        c.turns = [Turn(role: .user, text: text.isEmpty ? transcript : text, original: transcript)] + turns
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
/// (`Island.sending`), and "cancel" or Escape stops it (Escape keeps it unsent, HM-1429). No window of its own.
@MainActor
final class SendCountdown {
    private(set) var cancelled = false
    /// What stopped it ("Escape", or the words heard), for the log (HM-1425).
    private(set) var cancelledBy: String?

    func cancel(by why: String) {
        guard !cancelled else { return }
        cancelled = true; cancelledBy = why
    }

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
