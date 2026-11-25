import FluidAudio
import AVFoundation
import AppKit
import Foundation
import NeedsYouShared

struct Conversation: Identifiable, Codable, Hashable {
    enum Outcome: String, Codable { case open, answered, noAnswer = "no_answer", done, error, sent, cancelled }

    var id: String
    var title: String
    var message: String
    var context: String?
    var project: String?
    var cwd: String?
    var startedAt: Date
    var endedAt: Date?
    var turns: [Turn] = []
    var outcome: Outcome = .open
    var artifactURL: String?
    var error: String?
    var kind: String?   // nil = ask, "send" = Hey Claude message
    var target: String?
    /// Hey Claude sends: how the chat was chosen (heard name, top matches, why). HM-1364.
    var route: String?
}

enum Phase: Equatable {
    case idle, speaking, listening, transcribing, publishing

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .speaking: return "Speaking"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .publishing: return "Publishing artifact"
        }
    }
}

enum Prefs {
    static let defaults = UserDefaults.standard
    /// The --ui-demo windows: nothing is written to the app's files.
    static var readOnly = false
    static func registerDefaults() {
        defaults.register(defaults: [
            "volume": 0.9,
            "waitSeconds": 30.0,
            "micUID": "",
            "endSilence": 4.0,
            "judgePause": 2.0,
            "openDuringConversation": true,
            "subtitlesOnScreen": true,
        ])
    }
    static var volume: Float { Float(defaults.double(forKey: "volume")) }
    static var waitSeconds: Double { max(3, defaults.double(forKey: "waitSeconds")) }
    static var micUID: String { defaults.string(forKey: "micUID") ?? "" }
    /// Seconds of quiet, after he has started talking, that end his turn.
    static var endSilence: Double { min(10, max(1.5, defaults.double(forKey: "endSilence"))) }
    /// Pause after which Smart Turn judges whether he is done (23 Nov: 2 s, 4 s at most).
    static var judgePause: Double { min(endSilence, max(0.5, defaults.double(forKey: "judgePause"))) }
}

/// Runs one conversation at a time. Every CLI request ends up here.
@MainActor
final class Conductor: ObservableObject {
    static let shared = Conductor()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var hearingSpeech = false
    @Published private(set) var current: Conversation?
    @Published private(set) var history: [Conversation] = []
    @Published private(set) var queued = 0
    @Published var lastError: String?

    private let voice = VoicePlayer()
    private let fallbackPlayer = Player()
    /// True while Needs You speaks or records (the Hey Claude listener pauses).
    @Published private(set) var micInUse = false
    private var recorder: Recorder?
    /// True while the voice plays (Escape and the turn shortcut can stop it).
    private(set) var voicePlaying = false
    /// How the last spoken turn was cut off (nil: it played to the end).
    private var stoppedBy: SpeechStop?
    /// The turn shortcut stopped the voice: open his Hey Claude turn when nothing listens after.
    private var openTurnAfter = false
    @Published private(set) var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var turnInFlight = false
    private var idleTimer: Task<Void, Never>?
    private static let idleClose: UInt64 = 180 // seconds an answered conversation stays open for `say`

    private var historyURL: URL { Wire.supportDir.appendingPathComponent("history.json") }

    init() {
        if let data = try? Data(contentsOf: historyURL),
           let list = try? LineIO.decoder.decode([Conversation].self, from: data) {
            history = list.map { c in
                var c = c
                if c.outcome == .open { c.outcome = .done }
                return c
            }
        }
    }

    // MARK: Queue

    private func acquire() async {
        if !busy { busy = true; return }
        queued += 1
        await withCheckedContinuation { waiters.append($0) }
        queued -= 1
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    // MARK: Entry point

    func handle(_ req: Request, clientAlive: @escaping () -> Bool) async -> Response {
        // Every request from an agent's MCP server or hook keeps its chat registered (HM-1364).
        if let u = req.chat { ChatRegistry.shared.apply(u) }
        switch req.command {
        case .register:
            var r = Response(status: "status")
            if let u = req.chat, HookSetup.delivers(u.event) {
                // Messages that waited while the chat was busy: the hook hands them over.
                let m = ChatRegistry.shared.takeInbox(ChatInfo.id(pid: u.agentPid))
                if !m.isEmpty { r.messages = m }
            }
            return r
        case .inbox:
            var r = Response(status: "status")
            if let u = req.chat { r.messages = ChatRegistry.shared.takeInbox(ChatInfo.id(pid: u.agentPid)) }
            return r
        case .chats:
            var r = Response(status: "status")
            r.chats = ChatRegistry.shared.reachable
            return r
        case .status:
            var r = Response(status: "status")
            r.state = phase.label + " | \(Wake.phrase): " + VoiceCommands.shared.status
                + (VoiceCommands.shared.noiseReduction ? " (noise reduction on)" : "")
            r.queued = queued
            r.conversationID = current?.id
            return r
        case .clean:
            // Test hook: needs-you clean-test "<text>" [--title verbatim|removeFillers|polish|speech]
            // speech: what Needs You would say for an agent's line (HM-1370).
            if req.context == "speech" {
                var r = Response(status: "status")
                r.transcript = SpeechText.spoken(req.text ?? "")
                r.transcriptVerbatim = req.text
                return r
            }
            let mode = req.context.flatMap(TranscriptMode.init(rawValue:)) ?? .removeFillers
            var r = Response(status: "status")
            r.transcript = await TranscriptCleaner.clean(req.text ?? "", mode: mode)
            r.transcriptVerbatim = req.text
            return r
        case .stt:
            // Test hook: needs-you stt-test <audio> --title apple|v2|v3|ultra|bark3|cohere
            guard let path = req.inputFile else { return errorResponse("stt-test needs an audio file") }
            // "<engine>@en,tr" (HM-1351): transcribe as if those languages were turned on;
            // state then also says which language was heard.
            let (engine, langs) = STTLanguage.split(req.context ?? "v2")
            let strict = STTLanguage.strictFlag(req.context ?? "")
            let url = URL(fileURLWithPath: path)
            var r = Response(status: "measured")
            do {
                if engine.hasPrefix("langpick:") {
                    // stt-test <audio> --title langpick:<whisper model>@en/tr[!] (HM-1362): the
                    // subtitle decision for this clip (all languages, his favoured; "!" = only these).
                    let m = String(engine.dropFirst(9))
                    let samples = try AudioConverter().resampleAudioFile(url)
                    let t0 = Date()
                    let d = try await STTLanguage.$spokenOverride.withValue(langs) {
                        try await STTLanguage.$strictOverride.withValue(strict) {
                            try await WhisperSTT.shared.detect(samples, model: m, speech: Double(samples.count) / 16_000)
                        }
                    }
                    r.transcript = d.map { String(format: "%@ %@ top %.3f margin %.3f", $0.code, $0.confident ? "confident" : "unsure", $0.top, $0.margin) } ?? "none"
                    r.state = String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)
                    return r
                }
                if engine.hasPrefix("langid:") {
                    // stt-test <audio> --title langid:<whisper model>: language probabilities (top 5).
                    let m = String(engine.dropFirst(7))
                    let t0 = Date()
                    let p = try await WhisperSTT.shared.languageProbabilities(try AudioConverter().resampleAudioFile(url), model: m, among: langs)
                    r.transcript = p.sorted { $0.value > $1.value }.prefix(5).map { String(format: "%@ %.3f", $0.key, $0.value) }.joined(separator: ", ")
                    r.state = String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)
                    return r
                }
                if engine != "apple" { try await LocalSTT.shared.warm(engine) } // load outside the timing
                let t0 = Date()
                var heard: String?
                switch engine {
                case "apple":
                    if #available(macOS 26, *) { r.transcript = try await AppleSTT.transcribe(url: url) }
                default:
                    let h = try await STTLanguage.$spokenOverride.withValue(langs) {
                        try await STTLanguage.$strictOverride.withValue(strict) {
                            try await LocalSTT.shared.hear(url: url, model: engine, language: langs == nil ? .english : .spoken)
                        }
                    }
                    r.transcript = h.text
                    if langs != nil { heard = h.language }
                }
                r.state = String(format: "%.0f", Date().timeIntervalSince(t0) * 1000) + (heard.map { " lang=\($0)" } ?? "")
            } catch { r.status = "error"; r.error = error.localizedDescription }
            return r
        case .stop:
            // Test hook: needs-you stop-test <audio>: plays the file in real time through
            // both stop detectors; state = ms from start to each detection.
            guard let path = req.inputFile else { return errorResponse("stop-test needs an audio file") }
            var r = Response(status: "measured")
            r.state = await StopBench.run(URL(fileURLWithPath: path))
            return r
        case .voice where (req.context ?? "").hasPrefix("record:"):
            // needs-you voice-test <out-prefix> --title record:<seconds>: Mac mic + iPhone mic, raw.
            guard let prefix = req.text, let secs = Double((req.context ?? "").dropFirst(7)),
                  let phone = AudioDevices.continuityMic() else { return errorResponse("record:<seconds> <out-prefix>, with the iPhone nearby") }
            let mac = Prefs.micUID.isEmpty ? (AudioDevices.inputs().first { $0.id.contains("BuiltIn") }?.id ?? "") : Prefs.micUID
            micInUse = true
            defer { micInUse = false }
            try? await Task.sleep(nanoseconds: 300_000_000) // the wake listeners let go of the mics
            do {
                let r = try await DualRecorder().record(uids: [mac, phone.id], seconds: secs)
                try Recorder.wav(r.samples[0]).write(to: URL(fileURLWithPath: prefix + "-mac.wav"))
                try Recorder.wav(r.samples[1]).write(to: URL(fileURLWithPath: prefix + "-iphone.wav"))
                var out = Response(status: "recorded")
                out.state = String(format: "mac %.1fs, iphone %.1fs, iphone starts %.3fs after mac", Double(r.samples[0].count) / 16_000, Double(r.samples[1].count) / 16_000, r.hostStart[1] - r.hostStart[0])
                return out
            } catch { return errorResponse(error.localizedDescription) }
        case .voice where ["merge-selftest", "merge", "train-process", "train-eval", "train-restore", "wake-latency"].contains(req.context?.split(separator: ":").first.map(String.init) ?? ""):
            // Test hooks (silent, files only):
            //   voice-test <voice.wav> <game.wav> --title merge-selftest
            //   voice-test <a.wav> <b.wav> <out-prefix> --title merge
            //   voice-test --title train-process      (re-enroll, threshold, eval set)
            //   voice-test --title train-eval:<model>[,<model>...]
            //   voice-test --title train-restore      (undo the last train-process)
            //   voice-test <wav>... --title wake-latency[:fast|:slow][:cmd]
            let files = (req.text ?? "").split(separator: " ").map(String.init)
            var r = Response(status: "measured")
            let t0 = Date()
            switch req.context ?? "" {
            case "merge-selftest":
                guard files.count == 2 else { return errorResponse("merge-selftest <voice.wav> <game.wav>") }
                let v = try? AudioConverter().resampleAudioFile(URL(fileURLWithPath: files[0]))
                let g = try? AudioConverter().resampleAudioFile(URL(fileURLWithPath: files[1]))
                guard let v, let g else { return errorResponse("could not read the files") }
                r.state = await Task.detached { TwoMic.selfTest(voice: v, game: g) + " || " + TwoMic.selfTest(voice: v, game: g, room: true) }.value
            case "merge":
                guard files.count == 3 else { return errorResponse("merge <a.wav> <b.wav> <out-prefix>") }
                let a = (try? AudioConverter().resampleAudioFile(URL(fileURLWithPath: files[0]))) ?? []
                let b = (try? AudioConverter().resampleAudioFile(URL(fileURLWithPath: files[1]))) ?? []
                r.state = await MicMerge.experiment(a, b, prefix: files[2])
            case "train-process":
                await MainActor.run { TrainingLab.shared.reload() }
                r.state = await TrainingLab.shared.process()
            case "train-restore":
                r.state = await TrainingLab.shared.restore()
            case let c where c.hasPrefix("wake-latency"):
                // voice-test <wav>... --title wake-latency[:fast|:slow]: wake timing on clips (silent).
                // [:cmd] also waits for the command to end and says why it ended.
                let opts = (req.context ?? "").split(separator: ":").dropFirst().map(String.init)
                r.state = await WakeBench.run(files: files, fast: opts.contains("fast") ? true : opts.contains("slow") ? false : nil, untilCommand: opts.contains("cmd"))
            default:
                let models = String((req.context ?? "").dropFirst("train-eval:".count)).split(separator: ",").map(String.init)
                await TrainingLab.shared.evaluate(models: models)
                let res = await MainActor.run { TrainingLab.shared.results.filter { models.contains($0.model) } }
                r.state = res.map { x in
                    x.error.map { "\(x.model): \($0)" } ?? String(format: "%@ %@: wake %d/%d, false %d/%d, WER %.0f%%, %.0f ms, CPU %.0f%%, %.0f MB",
                                                               x.model, x.source ?? "mac", x.wakeCaught, x.wakeTotal, x.falseWakes, x.otherTotal, x.wer * 100, x.medianMs, x.cpuPercent, x.footprintMB)
                }.joined(separator: " | ")
            }
            r.transcript = String(format: "%.0f ms", Date().timeIntervalSince(t0) * 1000)
            return r
        case .voice where (req.context ?? "").hasPrefix("keys"):
            // Silent shortcut hooks (HM-1353, HM-1354), never any audio:
            //   voice-test --title keys          what the turn shortcut would do now
            //   voice-test --title keys:turn     run the turn shortcut's handler (under DND: only the moon)
            //   voice-test --title keys:escape   run Escape's handler (does nothing unless the voice plays)
            var r = Response(status: "measured")
            let keys = Hotkeys.shared
            switch req.context ?? "" {
            case "keys:turn": r.transcript = "pressed: \(TurnShortcut.pressed())"
            case "keys:escape": r.transcript = voicePlaying ? "stopped the voice" : "nothing playing"; escapePressed()
            default: break
            }
            r.state = "turn \(keys.turn?.display ?? "none")" + (keys.turnProblem.map { " (\($0))" } ?? " registered")
                + ", escape registered \(keys.escapeOn), would do: \(TurnKey.action(TurnShortcut.state()))"
            return r
        case .voice where (req.context ?? "").hasPrefix("dnd"):
            // Silent do-not-disturb hooks (HM-1352), never any audio:
            //   voice-test --title dnd                 state and unheard count
            //   voice-test --title dnd:on|dnd:night    turn it on (away / good night)
            //   voice-test --title dnd:off-silent      turn it off without reading voicemails
            //   voice-test --title dnd:spoken          what would be read out, one line per voicemail
            //   voice-test --title dnd:summary         the spoken summary as text
            //   voice-test <id> [<id>...] --title dnd:forget   delete voicemails (test ones)
            //   voice-test --title dnd:selftest        muted ask/say through handle(), cleans up after itself
            let dnd = DoNotDisturb.shared
            var r = Response(status: "measured")
            switch req.context ?? "" {
            case "dnd:on": dnd.turnOn(goodNight: false)
            case "dnd:night": dnd.turnOn(goodNight: true)
            case "dnd:off-silent": dnd.turnOff()
            case "dnd:spoken": r.transcript = dnd.unheard.map { DoNotDisturb.spoken($0) }.joined(separator: " | ")
            case "dnd:summary": r.transcript = dnd.summary()
            case "dnd:forget": dnd.remove(ids: Set((req.text ?? "").split(separator: " ").map(String.init)))
            case "dnd:selftest":
                // The real handle() path with muted test requests (no audio, no mic):
                // ask and say under do not disturb, then an unanswered ask without it.
                let before = dnd.state.on, night = dnd.state.goodNight
                let known = Set(dnd.voicemails.map(\.id))
                var lines: [String] = []
                func probe(_ cmd: Request.Command, _ text: String, noListen: Bool = false) -> Request {
                    var q = Request(command: cmd); q.text = text; q.title = "DND self-test"; q.mute = true
                    q.simulateSilence = true; q.waitSeconds = 1; q.noListen = noListen; q.cwd = req.cwd; return q
                }
                dnd.turnOn(goodNight: true)
                var t0 = Date()
                let a1 = await handle(probe(.ask, "Self-test ask under do not disturb."), clientAlive: { true })
                lines.append(String(format: "dnd ask -> %@ in %.0f ms", a1.status, Date().timeIntervalSince(t0) * 1000))
                t0 = Date()
                let s1 = await handle(probe(.say, "Self-test say under do not disturb.", noListen: true), clientAlive: { true })
                lines.append(String(format: "dnd say --no-listen -> %@ in %.0f ms", s1.status, Date().timeIntervalSince(t0) * 1000))
                dnd.turnOff()
                t0 = Date()
                let a2 = await handle(probe(.ask, "Self-test ask that nobody answers."), clientAlive: { true })
                lines.append(String(format: "unanswered ask -> %@ in %.1f s, turns %d", a2.status, Date().timeIntervalSince(t0), a2.turns?.filter { $0.role == .agent }.count ?? -1))
                let made = dnd.voicemails.filter { !known.contains($0.id) }
                lines.append("voicemails stored: " + made.map { "\($0.kind.rawValue) from \($0.source)" }.joined(separator: ", "))
                lines.append("spoken: " + made.map { DoNotDisturb.spoken($0) }.joined(separator: " / "))
                lines.append("summary: " + dnd.summary())
                dnd.remove(ids: Set(made.map(\.id)))
                history.removeAll { $0.title == "DND self-test" }
                if let data = try? LineIO.encoder.encode(history) { try? data.write(to: historyURL, options: .atomic) }
                if before { dnd.turnOn(goodNight: night) }
                r.transcript = lines.joined(separator: " | ")
            default: break
            }
            r.state = "on \(dnd.on), good night \(dnd.state.goodNight), unheard \(dnd.unheard.count): " + dnd.unheard.map(\.id).joined(separator: " ")
            return r
        case .voice where req.context == "overlay-demo":
            // needs-you voice-test --title overlay-demo: subtitles and glow with sample
            // text for both sides, about 7 s, no audio.
            guard Subtitles.enabled else { return errorResponse("Subtitles on Screen is off in Settings.") }
            await Subtitles.shared.demo()
            return Response(status: "measured")
        case .voice where req.context == "learn":
            // needs-you voice-test --title learn: the same guided enrollment as Settings, by voice.
            return await learnVoice()
        case .voice:
            // Test hook: needs-you voice-test <wav> [<wav>...] --title enroll|score|filter|forget
            //   enroll: learn the voice from the files; score: per-window similarity;
            //   filter <in> <out>: write only his parts.
            let files = (req.text ?? "").split(separator: " ").map(String.init)
            var r = Response(status: "measured")
            do {
                let audio = try files.filter { !$0.isEmpty }.prefix(req.context == "filter" || req.context == "ps4" ? 1 : files.count).map { try AudioConverter().resampleAudioFile(URL(fileURLWithPath: $0)) }
                let t0 = Date()
                switch req.context ?? "score" {
                case "enroll": _ = try await SpeakerID.shared.enroll(audio); voiceEnrolled = true; r.state = "enrolled from \(files.count) files"
                case "forget": await forgetVoice(); r.state = "forgotten"
                case "filter":
                    guard audio.count == 1, files.count == 2, let only = try await SpeakerID.shared.onlyHim(audio[0]) else { throw NSError(domain: "NeedsYou", code: 9, userInfo: [NSLocalizedDescriptionKey: "filter <in.wav> <out.wav>, after enrolling"]) }
                    try Recorder.wav(only).write(to: URL(fileURLWithPath: files[1]))
                    r.state = "written"
                case let m where m.hasPrefix("embed"):
                    // embed[:window]: raw embeddings of each window, one JSON array per file
                    let w = Int(m.split(separator: ":").last.flatMap { Int($0) } ?? SpeakerID.window)
                    var all: [[[Float]]] = []
                    for a in audio {
                        var rows: [[Float]] = []
                        var i = 0
                        repeat { let end = min(a.count, i + w); rows.append(try await SpeakerID.shared.embed(Array(a[i..<end]))); i += w / 3 } while i + w <= a.count
                        all.append(rows)
                    }
                    try JSONEncoder().encode(all).write(to: URL(fileURLWithPath: "/tmp/needs-you-embed.json"))
                    r.state = "written"
                case "ps4":
                    // needs-you voice-test <in.wav> <out.wav> --title ps4: PS4 extraction on a file,
                    // also when the Settings switch is off. Writes the original if PS4 keeps it.
                    guard audio.count == 1, files.count == 2 else { throw NSError(domain: "NeedsYou", code: 9, userInfo: [NSLocalizedDescriptionKey: "ps4 <in.wav> <out.wav>"]) }
                    let only = await PS4.shared.extract(audio[0], force: true)
                    try Recorder.wav(only ?? audio[0]).write(to: URL(fileURLWithPath: files[1]))
                    r.state = only == nil ? "kept original (see audio.log)" : "written"
                default:
                    let s = try await SpeakerID.shared.scores(audio.first ?? []) ?? []
                    r.state = s.map { String(format: "%.2f", $0) }.joined(separator: " ")
                }
                r.transcript = String(format: "%.0f ms", Date().timeIntervalSince(t0) * 1000)
            } catch { r.status = "error"; r.error = error.localizedDescription }
            return r
        case .turn:
            // Test hook: needs-you turn-test <audio> [--title smart|smart@0.75|silero|old|probs]: when
            // would each end-of-turn method end this recording? state = JSON.
            guard let path = req.inputFile else { return errorResponse("turn-test needs an audio file") }
            var r = Response(status: "measured")
            r.state = await TurnBench.run(URL(fileURLWithPath: path), method: req.context ?? "smart")
            return r
        case .tts:
            return await Self.ttsTest(req)
        case .sounds:
            for cue in Cue.allCases { await Sounds.shared.playAndWait(cue); try? await Task.sleep(nanoseconds: 450_000_000) }
            return Response(status: "done")
        // Do not disturb: agents never speak, play a sound or open the mic (HM-1352).
        case .ask where DoNotDisturb.shared.on:
            return DoNotDisturb.shared.response(DoNotDisturb.shared.store(req, kind: .ask))
        case .say where DoNotDisturb.shared.on:
            return DoNotDisturb.shared.response(DoNotDisturb.shared.store(req, kind: .say, conversationID: req.conversationID ?? current?.id))
        case .done where DoNotDisturb.shared.on && !(req.text ?? "").isEmpty:
            let v = DoNotDisturb.shared.store(req, kind: .say, conversationID: req.conversationID ?? current?.id)
            var quiet = req; quiet.text = nil
            _ = await done(quiet)
            return DoNotDisturb.shared.response(v)
        case .permission:
            return await permission(req, clientAlive: clientAlive) // HM-1369, PermissionVoice.swift
        case .ask, .say, .done:
            let r = req.command == .ask ? await ask(req, clientAlive: clientAlive)
                : req.command == .say ? await say(req) : await done(req)
            if req.mute != true {
                // Escape: quiet, fold the island back (no "thinking": he closed it).
                if r.status == "interrupted" && stoppedBy == .escape { Island.shared.idle() }
                else { Island.shared.finished(r.status, error: r.error) }
            }
            return r
        case .wake:
            if req.armPane == "none" {
                Router.armedPanes.removeAll()
                return Response(status: "armed")
            }
            if let pane = req.armPane {
                if await Router.targets().contains(where: { $0.kind == .herdrAgent && $0.id == pane }) {
                    var r = Response(status: "error"); r.error = "\(pane) is a Claude chat, not a test pane."; return r
                }
                Router.armedPanes = [pane: Date().addingTimeInterval(600)]
                var r = Response(status: "armed"); r.state = pane; return r
            }
            Router.testRoot = req.projectsRoot
            defer { Router.testRoot = nil }
            if req.vadFile == nil, let text = req.context, req.dryRun == false {
                return await VoiceCommands.shared.route(text, dryRun: false, testOnly: true)
            }
            if req.vadFile == nil, let text = req.context {
                // Parse-only test: where would this transcript go?
                if let rest = Wake.afterWakeWord(text), let p = PresenceCommand.parse(rest) {
                    var r = Response(status: "dry_run"); r.state = "presence: \(p)"; return r
                }
                let targets = await Router.targets()
                var r = Response(status: "dry_run")
                switch Router.parse(text, targets: targets) {
                case .send(let t, let m): r.state = t.title; r.transcript = m
                case .choose(let o, let m, let h): r.status = "choose"; r.state = o.map(\.title).joined(separator: " | "); r.transcript = m; r.error = "heard name: \(h)"
                case .nothing(let why): r.status = "nothing"; r.error = why
                case .newChat(let name, let m): r.status = "new_chat"; r.state = name ?? "~"; r.transcript = m
                }
                return r
            }
            guard let file = req.vadFile else { return errorResponse("wake-test needs an audio file or --arm-pane") }
            return await VoiceCommands.shared.test(file: file, dryRun: req.dryRun == true)
        }
    }

    /// Test hook: needs-you tts-test "<text>" [--title <kokoro voice>|fallback] [--tts-out file].
    /// Nothing plays. state = ms, engines = which voice spoke each part (HM-1368),
    /// transcript = Kokoro's phonemes for English text. "fallback": macOS voices for
    /// the other languages. Also `NeedsYou --tts-test` (in-process, no socket).
    static func ttsTest(_ req: Request) async -> Response {
        var r = Response(status: "measured")
        let text = SpeechText.spoken(req.text ?? "")
        let title = req.context
        let kokoro = title.flatMap { LocalTTS.voices.contains($0) ? $0 : nil }
        do {
            let t0 = Date()
            let mix = try await VoiceMix.speech(text, englishVoice: kokoro, nativeOff: title == "fallback")
            r.state = String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)
            r.engines = mix.engines
            if mix.engines.allSatisfy({ $0.hasPrefix("en=kokoro") }) { r.transcript = try? await LocalTTS.shared.phonemes(text) }
            if let out = req.ttsOut { try mix.audio.write(to: URL(fileURLWithPath: out)) }
        } catch { r.status = "error"; r.error = error.localizedDescription }
        return r
    }

    func ask(_ req: Request, clientAlive: () -> Bool) async -> Response {
        await acquire()
        guard clientAlive() else { release(); return Response(status: "error") }
        // Do not disturb came on while this ask waited its turn.
        if DoNotDisturb.shared.on { release(); return DoNotDisturb.shared.response(DoNotDisturb.shared.store(req, kind: .ask)) }

        let message = req.text ?? ""
        var convo = Conversation(id: Self.newID(), title: Self.title(req.title, message), message: message,
                                 context: req.context, project: req.project, cwd: req.cwd, startedAt: Date())
        current = convo
        lastError = nil

        do {
            // Asked once (24 Nov: never repeat the question).
            let wait = req.waitSeconds ?? Prefs.waitSeconds
            convo.turns.append(Turn(role: .agent, text: message))
            current = convo
            if let until = try await speak(message, req) {
                return try await interrupted(&convo, spokenUntil: until, req: req)
            }
            if let heard = try await listen(wait: wait, req), !heard.isEmpty {
                let text = await TranscriptCleaner.clean(heard)
                convo.turns.append(Turn(role: .user, text: text, original: heard))
                convo.outcome = .answered
                current = convo
                save(convo)
                armIdleTimer()
                var r = response("answered", convo, transcript: text)
                if heard != text { r.transcriptVerbatim = heard }
                return r
            }
            guard clientAlive() else { return finish(convo, status: "error") }
            if req.mute != true { Sounds.shared.play(.noAnswer) }
            convo.outcome = .noAnswer
            if req.once == true {
                // The caller has its own fallback (the on-screen question): no voicemail.
                return finish(convo, status: "no_answer")
            }
            // Nobody answered: keep it as a voicemail for when he is back.
            DoNotDisturb.shared.store(req, kind: .noAnswer, conversationID: convo.id)
            var r = finish(convo, status: "voicemail")
            r.state = "\(UserName.ForAgents) did not answer, left as a voicemail. They hear it later: go on with other work and do not ask again."
            return r
        } catch {
            convo.outcome = .error
            convo.error = error.localizedDescription
            lastError = error.localizedDescription
            var r = finish(convo, status: "error")
            r.error = error.localizedDescription
            return r
        }
    }

    private func say(_ req: Request) async -> Response {
        let open = current.map { $0.outcome == .answered || $0.outcome == .open } ?? false
        // One-way reply with nothing open: speak it on its own, in turn with the queue.
        if !open && req.noListen == true && req.conversationID == nil { return await announce(req) }
        guard var convo = current, open else {
            return errorResponse("No open conversation. Start one with `needs-you ask`, or use `say --no-listen`.")
        }
        if let id = req.conversationID, id != convo.id {
            return errorResponse("Conversation \(id) is not the open one (open: \(convo.id)).")
        }
        guard !turnInFlight else { return errorResponse("Needs You is already speaking or listening in this conversation.") }
        turnInFlight = true
        defer { turnInFlight = false }
        idleTimer?.cancel()

        let text = req.text ?? ""
        convo.turns.append(Turn(role: .agent, text: text))
        current = convo
        do {
            if let until = try await speak(text, req) {
                return try await interrupted(&convo, spokenUntil: until, req: req)
            }
            if req.noListen == true {
                micInUse = false
                save(convo)
                armIdleTimer()
                return response("spoken", convo, transcript: nil)
            }
            if let heard = try await listen(wait: req.waitSeconds ?? Prefs.waitSeconds, req), !heard.isEmpty {
                let text = await TranscriptCleaner.clean(heard)
                convo.turns.append(Turn(role: .user, text: text, original: heard))
                current = convo
                save(convo)
                armIdleTimer()
                var r = response("answered", convo, transcript: text)
                if heard != text { r.transcriptVerbatim = heard }
                return r
            }
            if req.mute != true { Sounds.shared.play(.noAnswer) }
            convo.outcome = .done
            return finish(convo, status: "no_answer")
        } catch {
            convo.error = error.localizedDescription
            lastError = error.localizedDescription
            var r = finish(convo, status: "error")
            r.error = error.localizedDescription
            return r
        }
    }

    /// `say --no-listen` without an open conversation: waits its turn, speaks, ends.
    private func announce(_ req: Request) async -> Response {
        await acquire()
        if DoNotDisturb.shared.on { release(); return DoNotDisturb.shared.response(DoNotDisturb.shared.store(req, kind: .say)) }
        let text = req.text ?? ""
        var convo = Conversation(id: Self.newID(), title: Self.title(req.title, text), message: text,
                                 context: req.context, project: req.project, cwd: req.cwd, startedAt: Date())
        convo.turns.append(Turn(role: .agent, text: text))
        current = convo
        lastError = nil
        do {
            if let until = try await speak(text, req) {
                return try await interrupted(&convo, spokenUntil: until, req: req)
            }
            convo.outcome = .done
            return finish(convo, status: "spoken")
        } catch {
            convo.outcome = .error
            convo.error = error.localizedDescription
            var r = finish(convo, status: "error")
            r.error = error.localizedDescription
            return r
        }
    }

    func done(_ req: Request) async -> Response {
        guard var convo = current else { return Response(status: "done") }
        if let id = req.conversationID, id != convo.id {
            return errorResponse("Conversation \(id) is not the open one (open: \(convo.id)).")
        }
        idleTimer?.cancel()
        if let text = req.text, !text.isEmpty {
            convo.turns.append(Turn(role: .agent, text: text))
            current = convo
            if let until = try? await speak(text, req) {
                if let r = try? await interrupted(&convo, spokenUntil: until, req: req) { return r }
            }
        }
        if convo.outcome == .open || convo.outcome == .answered { convo.outcome = .done }
        return finish(convo, status: "done")
    }

    /// Drops a test conversation from the history (muted self-tests).
    func forget(conversationID id: String) {
        history.removeAll { $0.id == id }
        if let data = try? LineIO.encoder.encode(history) { try? data.write(to: historyURL, options: .atomic) }
    }

    /// Cancels whatever is running (menu: Stop).
    func stop() {
        if voicePlaying { stoppedBy = .menu }
        voice.stop()
        recorder?.stop()
    }

    /// Cuts the voice off now. `.voice` is the "Stop, Claude" path (he gets listened to);
    /// `.escape` ends there (HM-1353).
    func stopSpeaking(_ why: SpeechStop, thenOpenTurn: Bool = false) {
        guard voicePlaying else { return }
        stoppedBy = why
        openTurnAfter = thenOpenTurn
        Isolation.note("voice: stopped by \(why.rawValue)")
        voice.stop()
        fallbackPlayer.stop()
    }

    /// Escape, registered only while the voice plays.
    func escapePressed() { stopSpeaking(.escape) }

    /// The turn shortcut while he answers an ask: ends his answer like "done".
    func endAnswer() { recorder?.stop() }

    /// He pressed Escape during the last spoken turn.
    private var escaped: Bool { stoppedBy == .escape }

    // MARK: Steps

    /// Speaks `text`. Returns what was said before "Stop, Claude", or nil if it finished.
    @discardableResult
    private func speak(_ text: String, _ req: Request, interruptible: Bool = true, usersTurn: Bool = false) async throws -> String? {
        Task.detached(priority: .utility) { try? await LocalSTT.shared.warm() } // ready for the answer
        let t0 = Date()
        let audio = try await SpeechIO.speech(text)
        Isolation.note(String(format: "tts: %.0f ms for %d chars", Date().timeIntervalSince(t0) * 1000, text.count))
        if let out = req.ttsOut { try audio.write(to: URL(fileURLWithPath: out)) }
        guard req.mute != true else { phase = .speaking; return nil }
        if !usersTurn { await waitForUser() }
        micInUse = true
        phase = .speaking
        let r: VoicePlayer.Result
        stoppedBy = nil
        openTurnAfter = false
        Subtitles.shared.claudeSpeaks(text, audio: audio)
        defer { Subtitles.shared.claudeDone() }
        // Escape stops the voice, but only while it plays (HM-1353).
        voicePlaying = true
        Hotkeys.shared.escapeWhileSpeaking(true)
        defer { voicePlaying = false; Hotkeys.shared.escapeWhileSpeaking(false) }
        do {
            r = try await voice.play(audio, text: text, volume: Prefs.volume, listen: interruptible)
        } catch {
            // Speech must always play: last resort is the plain player (no barge-in).
            Isolation.note("voice: engine playback failed (\(error.localizedDescription)); AVAudioPlayer")
            try await fallbackPlayer.play(audio, volume: Prefs.volume)
            return nil
        }
        guard r.interrupted else { return nil }
        if stoppedBy == nil { stoppedBy = .voice } // "Stop, Claude"
        await Sounds.shared.playAndWait(.stopped)
        return r.spokenUntil
    }

    /// Agents never talk over the user: wait while he is speaking a Hey Claude command
    /// (or one is being sent), and briefly while the room mic hears him talk.
    private func waitForUser() async {
        var plainTalk = 0.0
        while true {
            let vc = VoiceCommands.shared
            if vc.userHasFloor { try? await Task.sleep(nanoseconds: 300_000_000); continue }
            if vc.hearingSomeone && plainTalk < 20 {
                plainTalk += 0.3
                try? await Task.sleep(nanoseconds: 300_000_000); continue
            }
            return
        }
    }

    /// Turns an interrupted turn into the reply for the agent.
    private func interrupted(_ convo: inout Conversation, spokenUntil: String, req: Request) async throws -> Response {
        if let i = convo.turns.lastIndex(where: { $0.role == .agent }) {
            convo.turns[i].text = spokenUntil.isEmpty ? "(stopped before speaking)" : spokenUntil + " (stopped)"
        }
        if escaped {
            // Escape (HM-1353): he wants quiet. No listening; the conversation ends.
            convo.outcome = .done
            var r = finish(convo, status: "interrupted")
            r.spokenUntil = spokenUntil
            r.transcript = ""
            r.state = "\(UserName.ForAgents) pressed Escape to stop you. The conversation is closed; do not repeat it. Ask again later only if it still matters."
            return r
        }
        let heard = try await listen(wait: req.waitSeconds ?? Prefs.waitSeconds, req) ?? ""
        let text = heard.isEmpty ? "" : await TranscriptCleaner.clean(heard)
        if !heard.isEmpty { convo.turns.append(Turn(role: .user, text: text, original: heard)) }
        convo.outcome = .answered
        current = convo
        save(convo)
        armIdleTimer()
        var r = response("interrupted", convo, transcript: text)
        r.spokenUntil = spokenUntil
        if heard != text { r.transcriptVerbatim = heard }
        return r
    }

    private func listen(wait: Double, _ req: Request) async throws -> String? {
        micInUse = req.mute != true || req.vadFile != nil
        defer { micInUse = false }
        phase = .listening
        hearingSpeech = false
        level = 0
        defer { level = 0; hearingSpeech = false }

        if req.simulateSilence == true {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            return nil
        }
        if let path = req.inputFile {
            phase = .transcribing
            return try await SpeechIO.transcribe(fileURL: URL(fileURLWithPath: path))
        }

        let testFile = try req.vadFile.map { try AVAudioFile(forReading: URL(fileURLWithPath: $0)) }
        if testFile == nil {
            guard await Self.micAllowed() else {
                throw NSError(domain: "NeedsYou", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "Microphone access is off. Turn on Needs You in System Settings > Privacy & Security > Microphone."])
            }
        }
        let cues = req.mute != true
        if cues { await Sounds.shared.playAndWait(.listening) }

        // The wait applies until he starts talking. A filler-only turn ("ähm")
        // does not count: keep listening, with the wait starting over.
        var deadline = Date().addingTimeInterval(wait)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0.3 { return nil }
            phase = .listening
            let rec = Recorder()
            recorder = rec
            let live = cues || testFile != nil
            if live { Subtitles.shared.userBegan(source: "ask") }
            rec.onLevel = { [weak self] value, speaking in
                DispatchQueue.main.async {
                    self?.level = value
                    self?.hearingSpeech = speaking
                    if live { Subtitles.shared.level(value, .user, source: "ask") }
                }
            }
            // The language of his answer, once a quick check found it (HM-1351).
            let answerLanguage = LanguageBox()
            // Subtitles: what he has said so far, about every 0.8 s while he talks
            // (every 2 s when Whisper reads another language).
            let partials = live ? Task { [weak self] in
                var last = Date.distantPast
                // HM-1362: subtitles start at once in his likeliest language (the last one
                // this session, else his first); detection runs beside them and swaps.
                let assumed = SpokenLanguages.onlyEnglish ? "en" : (LocalSTT.lastLanguage ?? SpokenLanguages.enabled[0])
                var settled = SpokenLanguages.onlyEnglish
                var swap = false
                var first = true
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: first ? 400_000_000 : 800_000_000)
                    guard let self, self.hearingSpeech || self.level > 0.2 else { continue }
                    let audio = rec.snapshot()
                    guard audio.count >= 8_000 else { continue }
                    let speech = Double(audio.count) / 16_000 - 1 // starts about 1 s before his first word
                    if !settled, speech >= LanguagePick.minSpeech,
                       let d = await LocalSTT.shared.language(Array(audio.suffix(240_000)), speech: speech) {
                        if d.confident {
                            settled = true
                            LocalSTT.lastLanguage = d.code
                            if answerLanguage.value == nil { answerLanguage.value = d.code }
                            if d.code != assumed { swap = true; last = .distantPast }
                        } else if speech >= 5 { settled = true }
                    }
                    let known = answerLanguage.value ?? assumed
                    if known != "en", Date().timeIntervalSince(last) < 2 { continue }
                    last = Date()
                    let text = await LocalSTT.shared.quick(Array(audio.suffix(240_000)), known: known, detect: false).text
                    guard !text.isEmpty, !Task.isCancelled, Script.fits(text, languages: [known]) else { continue }
                    first = false
                    Subtitles.shared.userPartial(text, source: "ask", swap: swap)
                    swap = false
                }
            } : nil
            defer { partials?.cancel() }
            // On each short pause, check whether he just said "done" / "that's it" / "over".
            var checking = false
            rec.onPause = { audio in
                DispatchQueue.main.async {
                    guard !checking else { return }
                    checking = true
                    Task {
                        defer { checking = false }
                        // English: Parakeet as before. Other languages on: the first pause
                        // with 2.5 s of his words finds the language (Whisper), then
                        // English stays on Parakeet and any other is read by Whisper.
                        let samples = Recorder.samples(fromWav: audio)
                        let known = answerLanguage.value
                        let clip = SpokenLanguages.onlyEnglish || known == "en" ? samples : Array(samples.suffix(160_000))
                        let (text, lang) = await LocalSTT.shared.quick(clip, known: known, detect: samples.count >= 40_000)
                        if known == nil, let lang { answerLanguage.value = lang }
                        if Speech.endsWithStopPhrase(text) { rec.stop() }
                    }
                }
            }
            // HM-1360: a pause after "I think I like" keeps the answer open a bit longer.
            rec.holdOpen = { audio in
                let (open, text) = await EndOfTurn.heldOpen(audio, language: answerLanguage.value)
                Isolation.note(open ? "ask: pause kept open, not finished: \(text)" : "ask: pause ends the answer: \(text)")
                return open
            }
            let result = try await rec.record(wait: remaining, deviceUID: Prefs.micUID,
                                              silenceToStop: Prefs.endSilence, judgePause: Prefs.judgePause, maxSpeech: 120, testFile: testFile)
            recorder = nil
            partials?.cancel()
            if live { Subtitles.shared.userStopped() }
            guard let result else { return nil }
            defer { try? FileManager.default.removeItem(at: result.file.deletingLastPathComponent()) }
            if cues { Sounds.shared.play(.gotIt) } // no longer listening
            phase = .transcribing
            SpeechIO.keepSample(try? Data(contentsOf: result.file), kind: "answer")
            let t0 = Date()
            let raw = try await SpeechIO.transcribe(fileURL: result.file)
            Isolation.note(String(format: "stt: %.0f ms for %.1f s of speech", Date().timeIntervalSince(t0) * 1000, result.duration))
            if live { Subtitles.shared.userFinal(Speech.isFillerOnly(raw) ? "" : Speech.stripStopPhrase(raw)) }
            if Speech.isFillerOnly(raw) {
                deadline = Date().addingTimeInterval(wait)
                if cues { await Sounds.shared.playAndWait(.listening) }
                continue
            }
            return Speech.stripStopPhrase(raw)
        }
    }

    static func micAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Bookkeeping

    private func armIdleTimer() {
        phase = .idle
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleClose * 1_000_000_000)
            guard !Task.isCancelled, let self, var convo = self.current, !self.turnInFlight else { return }
            convo.outcome = .done
            _ = self.finish(convo, status: "done")
        }
    }

    private func finish(_ convo: Conversation, status: String) -> Response {
        var c = convo
        c.endedAt = Date()
        idleTimer?.cancel()
        save(c)
        current = nil
        phase = .idle
        micInUse = false
        release()
        return response(status, c, transcript: c.turns.last(where: { $0.role == .user })?.text)
    }

    private func save(_ convo: Conversation) {
        if let i = history.firstIndex(where: { $0.id == convo.id }) { history[i] = convo } else { history.insert(convo, at: 0) }
        if history.count > 200 { history = Array(history.prefix(200)) }
        guard !Prefs.readOnly else { return }
        try? FileManager.default.createDirectory(at: Wire.supportDir, withIntermediateDirectories: true)
        if let data = try? LineIO.encoder.encode(history) { try? data.write(to: historyURL, options: .atomic) }
    }

    /// Adds a finished entry (Hey Claude sends) to the history.
    func record(_ convo: Conversation) { save(convo) }

    /// Asks one short question by voice for the Hey Claude router, in the queue like any ask.
    /// Part of the user's own turn, so it goes ahead of queued asks (never waits behind one).
    func voiceClarify(_ question: String) async -> String? {
        let previous = current, wasBusy = busy
        busy = true
        var convo = Conversation(id: Self.newID(), title: "Which chat?", message: question, startedAt: Date())
        convo.kind = "clarify"
        current = convo
        defer {
            current = previous; phase = .idle
            if !wasBusy { release() }
        }
        let req = Request(command: .ask)
        micInUse = true
        defer { micInUse = false }
        do {
            try await speak(question, req, usersTurn: true)
            if escaped { return nil } // Escape: he does not want to pick one
            return try await listen(wait: Prefs.waitSeconds, req)
        } catch {
            return nil
        }
    }

    /// Router announcements ("Started a new chat in orchard"): part of the user's turn too.
    // MARK: Own voice

    /// Lines he reads to teach the app his voice (about 30 s of speech).
    static var voiceLines: [String] { voiceLinesTemplate.map { $0.replacingOccurrences(of: "Hey Claude", with: Wake.phrase) } }
    static let voiceLinesTemplate = [
        "Hey Claude.",
        "Hey Claude, this one: run the tests and tell me what failed.",
        "Hey Claude, orchard: what's the status of the deploy?",
        "I'm teaching this Mac what my voice sounds like, so it can ignore the game and the TV.",
        "Tomorrow I'll check the build, answer a few emails and go for a walk.",
        "Hey Claude.",
    ]
    /// The line he should read now, shown in Settings while learning.
    @Published private(set) var voiceLine: String?
    @Published private(set) var voiceEnrolled = SpeakerID.isEnrolled

    /// Reads each line out, records him repeating it, then saves his voiceprint.
    func learnVoice() async -> Response {
        await acquire()
        defer { phase = .idle; voiceLine = nil; release() }
        micInUse = true
        defer { micInUse = false }
        var clips: [[Float]] = []
        do {
            try? await speak("I'll learn your voice. After each beep, repeat the line. It's also on screen.", Request(command: .say), usersTurn: true)
            for line in Self.voiceLines { for attempt in 0..<3 {
                voiceLine = "Line \(Self.voiceLines.firstIndex(of: line).map { $0 + 1 } ?? 1) of \(Self.voiceLines.count): \u{201C}\(line)\u{201D}"
                try? await Task.sleep(nanoseconds: 60_000_000)
                try? await speak(line, Request(command: .say), usersTurn: true)
                await Sounds.shared.playAndWait(.listening)
                phase = .listening
                let rec = Recorder()
                recorder = rec
                rec.onLevel = { [weak self] value, speaking in
                    DispatchQueue.main.async { self?.level = value; self?.hearingSpeech = speaking }
                }
                let result = try await rec.record(wait: 15, deviceUID: Prefs.micUID, silenceToStop: 1.5, judgePause: 1.0, maxSpeech: 15)
                recorder = nil
                guard let result else {
                    if attempt < 2 { try? await speak("I didn't hear you. Once more.", Request(command: .say), usersTurn: true) }
                    continue
                }
                defer { try? FileManager.default.removeItem(at: result.file.deletingLastPathComponent()) }
                Sounds.shared.play(.gotIt)
                let audio = try AudioConverter().resampleAudioFile(result.file)
                // Only his reading of this line goes into the voiceprint: a missed
                // line (noise, the game, my own voice) must not train it.
                let heard = (try? await LocalSTT.shared.transcribe(samples: audio)) ?? ""
                if Self.matches(heard, line) { clips.append(audio); break }
                if attempt < 2 { try? await speak("That didn't sound like the line. Once more.", Request(command: .say), usersTurn: true) }
            } }
            voiceLine = nil
            guard clips.count >= 4 else { throw NSError(domain: "NeedsYou", code: 8, userInfo: [NSLocalizedDescriptionKey: "I heard only \(clips.count) of the lines"]) }
            _ = try await SpeakerID.shared.enroll(clips)
            voiceEnrolled = true
            try? await speak("Got it. From now on I only listen to your voice.", Request(command: .say), usersTurn: true)
            var r = Response(status: "enrolled"); r.state = "learned from \(clips.count) lines"; return r
        } catch {
            try? await speak("I couldn't learn your voice: \(error.localizedDescription).", Request(command: .say), usersTurn: true)
            var r = Response(status: "error"); r.error = error.localizedDescription; return r
        }
    }

    /// At least half of the line's words were heard.
    static func matches(_ heard: String, _ line: String) -> Bool {
        func words(_ s: String) -> [String] { s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 1 } }
        let want = words(line)
        var got = Set(words(heard))
        // His own wake phrase counts when the matcher hears it (mishearings included).
        if Wake.matcher.contains(heard, voiceLearned: false) { got.formUnion(Wake.matcher.words) }
        guard !want.isEmpty else { return false }
        return Double(want.filter { got.contains($0) || ($0 == "claude" && !got.isDisjoint(with: ["cloud", "claud", "clawed", "clod"])) }.count) / Double(want.count) >= 0.5
    }

    /// Training records the mics itself: the wake listeners let go meanwhile.
    func borrowMics(_ on: Bool) { micInUse = on }

    func forgetVoice() async {
        await SpeakerID.shared.forget()
        voiceEnrolled = false
    }

    // MARK: Voicemails (HM-1352)

    /// "I'm back" / "Good morning": the greeting, optionally the summary, then each
    /// unheard voicemail in order with a few seconds to answer it. An answer goes to
    /// that agent's chat; "next" or silence goes on; "stop" or "that's all" ends it.
    func playVoicemails(greeting: String?, summary: Bool, only ids: Set<String>? = nil) async {
        await acquire()
        micInUse = true
        defer { micInUse = false; current = nil; phase = .idle; Island.shared.done(); release() }
        let dnd = DoNotDisturb.shared
        let req = Request(command: .say)
        let list = ids.map { ids in (dnd.voicemails.filter { ids.contains($0.id) }).sorted { $0.at < $1.at } } ?? dnd.unheard
        var intro = greeting ?? ""
        if summary { intro += " " + dnd.summary() }
        if list.isEmpty { intro += " No new voicemails." }
        else if ids != nil { } // one picked in the menu or the window: straight to it
        else if !summary { intro += list.count == 1 ? " One voicemail." : " \(list.count) voicemails." }
        else { intro += " Here they are." }
        let opening = intro.trimmingCharacters(in: .whitespaces)
        if !opening.isEmpty { try? await speak(opening, req, usersTurn: true) }
        if escaped { return } // Escape: keep them all for later
        for v0 in list {
            var v = v0
            var convo = Conversation(id: Self.newID(), title: "Voicemail from \(v.source)", message: v.text,
                                     context: v.context, project: v.project, cwd: v.cwd, startedAt: Date())
            convo.kind = "voicemail"
            convo.turns.append(Turn(role: .agent, text: DoNotDisturb.spoken(v)))
            current = convo
            _ = try? await speak(DoNotDisturb.spoken(v), req, usersTurn: true)
            if escaped { convo.outcome = .cancelled; convo.endedAt = Date(); save(convo); return } // kept unheard
            v.heard = true
            dnd.update(v)
            let heard = ((try? await listen(wait: 8, req)) ?? nil) ?? ""
            let words = PresenceCommand.normalize(heard).split(separator: " ")
            let said = words.joined(separator: " ")
            if heard.isEmpty || (words.count <= 3 && said.range(of: #"^(next|skip|later|nothing|no|nope|move on|go on|keep going|ok|okay)\b"#, options: .regularExpression) != nil) {
                convo.outcome = .done; convo.endedAt = Date(); save(convo)
                continue
            }
            if words.count <= 4, said.range(of: #"^(stop|thats all|that is all|enough|not now|stop reading)\b"#, options: .regularExpression) != nil {
                convo.outcome = .done; convo.endedAt = Date(); save(convo)
                break
            }
            let text = await TranscriptCleaner.clean(heard)
            convo.turns.append(Turn(role: .user, text: text, original: heard))
            v.answer = text
            dnd.update(v)
            if let why = await Self.deliverAnswer(v, text) {
                convo.outcome = .error; convo.error = why
                Sounds.shared.play(.cancelled)
                try? await speak("I couldn't send that to the chat: \(why) Your answer is in the history.", req, usersTurn: true)
            } else {
                convo.outcome = .sent; convo.target = v.source
                Sounds.shared.play(.sent)
            }
            convo.endedAt = Date()
            save(convo)
        }
        if !list.isEmpty, ids == nil { try? await speak(dnd.unheard.isEmpty ? "That's all." : "I'll keep the rest for later.", req, usersTurn: true) }
    }

    /// "What did you work on last night?"
    func speakSummary() async {
        let dnd = DoNotDisturb.shared
        let n = dnd.unheard.count
        await speakOnly(dnd.summary() + (n > 0 ? " Say \u{201C}\(Wake.phrase), play my voicemails\u{201D} to hear them." : ""))
    }

    /// Types his answer into the chat the voicemail came from (its herdr pane, or the
    /// one chat in its folder). Returns why not, or nil when sent. Fails closed like
    /// every voice send while a test pane is armed.
    static func deliverAnswer(_ v: Voicemail, _ answer: String) async -> String? {
        let testOnly = !Router.armedPanes.isEmpty
        let targets = await Router.targets(testOnly: testOnly)
        var target = targets.first { $0.id == v.pane && $0.kind != .desktop }
        if target == nil, !testOnly, let folder = v.cwd?.split(separator: "/").last.map(String.init) {
            let inFolder = targets.filter { $0.kind == .herdrAgent && $0.aliases.contains(folder) }
            if inFolder.count == 1 { target = inFolder[0] }
        }
        guard let target else { return "that chat is gone." }
        let quote = DoNotDisturb.firstSentence(v.text)
        let text = "\(UserName.ForAgents)'s answer to your voicemail from \(DoNotDisturb.when(v.at)) (\u{201C}\(quote)\u{201D}): \(answer)\n" + Router.voiceSuffix
        do { try await Router.deliver(text, to: target); return nil } catch { return error.localizedDescription }
    }

    func speakOnly(_ text: String) async {
        let wasBusy = busy
        busy = true
        defer { phase = .idle; if !wasBusy { release() } }
        micInUse = true
        defer { micInUse = false }
        try? await speak(text, Request(command: .say), usersTurn: true)
        // The turn shortcut cut this off: nothing listens after it, so open his turn.
        if openTurnAfter, stoppedBy == .voice {
            openTurnAfter = false
            Task { await VoiceCommands.shared.openTurn() }
        }
    }

    func deleteHistory(ids: Set<String>) {
        history.removeAll { ids.contains($0.id) && $0.id != current?.id }
        guard !Prefs.readOnly else { return }
        if let data = try? LineIO.encoder.encode(history) { try? data.write(to: historyURL, options: .atomic) }
    }

    func clearHistory() {
        history.removeAll { $0.id != current?.id }
        guard !Prefs.readOnly else { return }
        if let data = try? LineIO.encoder.encode(history) { try? data.write(to: historyURL, options: .atomic) }
    }

    private func response(_ status: String, _ c: Conversation, transcript: String?) -> Response {
        var r = Response(status: status)
        r.conversationID = c.id
        r.transcript = transcript
        r.turns = c.turns
        r.artifactURL = c.artifactURL
        return r
    }

    private func errorResponse(_ message: String) -> Response {
        var r = Response(status: "error")
        r.error = message
        return r
    }

    private static func newID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: Date()))-\(UUID().uuidString.prefix(4).lowercased())"
    }

    private static func title(_ given: String?, _ message: String) -> String {
        if let g = given, !g.isEmpty { return g }
        let words = message.split(separator: " ").prefix(8).joined(separator: " ")
        return words.count < message.count ? words + "…" : words
    }
}

/// The language of one utterance, shared by its quick checks.
final class LanguageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var code: String?
    var value: String? {
        get { lock.withLock { code } }
        set { lock.withLock { code = newValue } }
    }
}

/// Text rules for a spoken turn.
enum Speech {
    static let fillers: Set<String> = ["äh", "ähm", "ahm", "äm", "öhm", "eh", "ehm", "uh", "uhm", "um", "umm", "hmm", "hm", "mm", "mhm", "er", "erm", "ah", "ehh", "uhh"]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    static func isFillerOnly(_ text: String) -> Bool {
        words(text).allSatisfy { fillers.contains($0) }
    }

    private static let stopPattern = #"(?i)[\s,.;:!?-]*\b(that'?s it|that is it|i'?m done|done|over)[\s.!?]*$"#

    /// English "done" / "that's it" / "over", plus the standalone end words of the
    /// other languages he turned on (HM-1351; none with English only).
    static func endsWithStopPhrase(_ text: String) -> Bool {
        text.range(of: stopPattern, options: .regularExpression) != nil || SpokenLanguages.endsWithEndWord(text)
    }

    static func stripStopPhrase(_ text: String, keepsPeriod: Bool = true) -> String {
        var t = SpokenLanguages.onlyEnglish ? text : SpokenLanguages.stripEndWord(text)
        if let r = t.range(of: stopPattern, options: .regularExpression) { t.removeSubrange(r) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, let last = t.last, last.isLetter || last.isNumber, keepsPeriod { t += "." }
        return t
    }
}
