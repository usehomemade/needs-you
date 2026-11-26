import AVFoundation
import Foundation
import os
import Speech
import NeedsYouShared

/// Always-on "Hey Claude" listener.
///
/// Everything before the wake word stays on the Mac: a cheap energy gate wakes
/// Apple's on-device SpeechAnalyzer (SpeechTranscriber, macOS 26+; it does not
/// need Siri or Dictation, unlike SFSpeechRecognizer) only while someone is
/// talking, and only that model hears the audio. After "Hey
/// Claude" it keeps recording the same utterance until a long pause, then hands
/// the WAV of the whole utterance to `onCommand` (transcribed on the Mac).
final class WakeListener {
    enum Mode { case gate, hearing, pending, command, cancelWatch }

    var onCommand: ((Data) -> Void)?
    /// The command with how good this mic's take was: his voice score (nil when not
    /// enrolled) and SNR in dB. Used to pick between the Mac and iPhone mics.
    var onUtterance: ((Data, Float?, Float) -> Void)?
    /// Which mic this listener uses, for logs ("mac", "iphone").
    var source = "mac"
    var onWake: (() -> Void)?
    /// Text heard while waiting for the wake phrase (Settings → Test).
    var onHeard: ((String) -> Void)?
    /// "Cancel" heard during the send countdown, with what was heard.
    var onCancelWord: ((String) -> Void)?
    var onEndOfFile: (() -> Void)?
    var onLongPause: (() -> Void)?
    /// On-screen subtitles: the command so far (Parakeet, about every 0.8 s) and the
    /// mic level (0...1 above the room), while a command is being recorded.
    /// The Bool is true when the text replaces the last one in another language (HM-1362).
    var onCommandPartial: ((String, Bool) -> Void)?
    var onCommandLevel: ((Float) -> Void)?
    private var partialBusy = false
    private var lastPartialText: String?
    private var lastPartial = 0.0
    private var longPauseReported = false
    var endSilence: Double = 3.0
    /// If he says nothing this long after the wake, the command ends (longer after the
    /// turn shortcut: he starts talking after the chime, not right after the phrase).
    private var noSpeechLimit = 2.5
    /// Test hook (wake bench): every log line, also when debug logging is off.
    var trace: ((String) -> Void)?
    /// SpeechAnalyzer `.fastResults` for the wake word (setting "wakeFastResults").
    var fastResults = UserDefaults.standard.object(forKey: "wakeFastResults") as? Bool ?? true

    private var engine = AVAudioEngine()
    private var usingEngine = false
    private var isoNodes: [AVAudioNode] = []
    private var meter: IsoMeter?
    private var isoLevel: Float = -100
    private var isoActive = false
    private var running = false
    private var session: AnyObject? // AnalyzerSession (macOS 26+)
    private var analyzerFormat: AVAudioFormat?
    private let q = DispatchQueue(label: "needs-you.wake")

    /// A command starts (after the wake phrase or the turn shortcut) or ends, on every
    /// path out: sent, silence, Escape, stop (HM-1413: other audio is lowered meanwhile).
    var onCommandMode: ((Bool) -> Void)?
    private var mode: Mode = .gate {
        didSet {
            guard (mode == .command) != (oldValue == .command) else { return }
            commandFlag.withLock { $0 = mode == .command }
            onCommandMode?(mode == .command)
        }
    }
    private let commandFlag = OSAllocatedUnfairLock(initialState: false)
    /// A command is being recorded right now (readable from any thread).
    var commandOpen: Bool { commandFlag.withLock { $0 } }
    private var floor: Float = -60
    private var loudRun = 0.0, quietRun = 0.0, segmentTime = 0.0
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0
    private var samples: [Float] = []
    private var pendingTime = 0.0
    private var pendingBufs: [AVAudioPCMBuffer] = []
    private var recent: [Float] = []
    private var generation = 0

    static let rate = 16_000.0
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    static var authorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
    }
    var supportsOnDevice: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// Downloads the on-device model if needed and picks the audio format it wants.
    func prepare() async throws {
        guard #available(macOS 26, *) else { return }
        guard analyzerFormat == nil else { return }
        let t = try await AnalyzerSession.makeTranscriber()
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) { try await req.downloadAndInstall() }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
        if Self.analyzerFormatCache == nil { Self.analyzerFormatCache = analyzerFormat }
    }

    /// The recognizer's input format, once any listener has prepared (used by VoicePlayer).
    nonisolated(unsafe) static var analyzerFormatCache: AVAudioFormat?

    /// True while the gate hears speech or a command is being recorded.
    var hearingSomeone: Bool { q.sync { mode == .hearing || mode == .pending || mode == .command } }

    // MARK: Start / stop

    func startMic(deviceUID: String?) throws {
        guard !running else { return }
        do {
            try setUpMic(deviceUID: deviceUID, iso: true)
        } catch {
            Isolation.note("wake: isolation graph failed (\(error.localizedDescription)); plain input")
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine = AVAudioEngine()
            isoNodes = []
            isoActive = false
            try setUpMic(deviceUID: deviceUID, iso: false)
        }
        usingEngine = true
        running = true
    }

    var noiseReductionActive: Bool { isoActive }

    private func setUpMic(deviceUID: String?, iso: Bool) throws {
        let input = engine.inputNode
        if let uid = deviceUID, !uid.isEmpty,
           let device = AudioDevices.inputs().first(where: { $0.id == uid }), let unit = input.audioUnit {
            var devID = device.deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: Self.format) else {
            throw NSError(domain: "NeedsYou", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        // Apple's on-device voice isolation (AUSoundIsolation) runs beside the raw
        // signal: its level drives the speech gate (measured: wake detection at
        // 0 dB SNR 0/6 -> 4/6, no false openings, ~1 % CPU). The recognizer still
        // gets the raw audio, which it understands better than the denoised one.
        // Owned here, never by the tap block: AVAudioEngine releases tap blocks on its
        // own messenger queue, and an engine torn down there deadlocks (crash).
        meter = (iso && (UserDefaults.standard.object(forKey: "noiseReduction") as? Bool ?? true)) ? IsoMeter() : nil
        isoActive = meter != nil
        Isolation.note("wake: mic \(inFormat.sampleRate) Hz x\(inFormat.channelCount), noise reduction \(meter != nil ? "on" : "off")")
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            guard let self else { return }
            self.meter?.submit(buf) { [weak self] in self?.isoLevel = $0 }
            self.ingest(buf, converter: conv)
        }
        engine.prepare()
        try engine.start()
    }

    /// Test hook: plays a file through the same path in real time.
    func startFile(_ file: AVAudioFile) throws {
        guard let conv = AVAudioConverter(from: file.processingFormat, to: Self.format) else {
            throw NSError(domain: "NeedsYou", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot convert test audio"])
        }
        running = true
        // Same gate as the mic: isolation levels for the file, computed up front.
        // Buffers as long as the live tap's (4096 frames at 48 kHz), so timings match.
        let chunk = AVAudioFrameCount(max(256, file.processingFormat.sampleRate * 4096 / 48_000))
        let isoLevels = (UserDefaults.standard.object(forKey: "noiseReduction") as? Bool ?? true) ? Isolation.levels(of: file, chunk: chunk) : nil
        file.framePosition = 0
        isoActive = isoLevels != nil
        if let l = isoLevels, !l.isEmpty {
            let sorted = l.sorted()
            Isolation.note("file iso levels n=\(l.count) min=\(sorted.first ?? 0) p15=\(sorted[sorted.count * 15 / 100]) p50=\(sorted[sorted.count / 2]) max=\(sorted.last ?? 0)")
        }
        Thread.detachNewThread { [self] in
            log("file playback start")
            var tail = 0.0
            var index = 0
            while running {
                let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
                if (try? file.read(into: buf, frameCount: chunk)) == nil || buf.frameLength == 0 {
                    buf.frameLength = chunk
                    for c in 0..<Int(buf.format.channelCount) { memset(buf.floatChannelData![c], 0, Int(chunk) * 4) }
                    tail += Double(chunk) / file.processingFormat.sampleRate
                    if tail > endSilence + 6 { running = false; onEndOfFile?(); break }
                }
                if let isoLevels { isoLevel = index < isoLevels.count ? isoLevels[index] : -100 }
                index += 1
                ingest(buf, converter: conv)
                Thread.sleep(forTimeInterval: Double(buf.frameLength) / file.processingFormat.sampleRate)
            }
        }
    }

    func stop() {
        running = false
        if usingEngine {
            Isolation.detach(engine, &isoNodes)
            isoActive = false
            meter?.shutdown(); meter = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            usingEngine = false
        }
        q.async { self.reset() }
    }

    var isRunning: Bool { running }

    /// While a voice command counts down before it is sent: listen only for "cancel".
    func startCancelWatch() {
        q.async {
            self.reset()
            self.mode = .cancelWatch
            self.beginRecognition()
        }
    }

    func stopCancelWatch() {
        q.async { if self.mode == .cancelWatch { self.reset() } }
    }

    // MARK: Audio

    private func ingest(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: cap) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard out.frameLength > 0 else { return }
        let db = isoActive ? isoLevel : Self.rmsDB(out)
        q.async { self.process(out, db: db) }
    }

    /// Silero voice activity + Smart Turn; the level gate is only the fallback.
    private let gate = SpeechGate(cap: 4.0, useTurnModel: false)

    private func process(_ buf: AVAudioPCMBuffer, db: Float) {
        let dt = Double(buf.frameLength) / Self.rate
        let vad: SpeechGate? = gate.available ? gate : nil
        vad?.push(Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))))
        // Noise floor: drops fast to quieter readings, rises slowly (only between
        // utterances) so a fan or music does not count as speech forever.
        // Noise floor = 15th percentile of the last ~8 s of levels. Speech has gaps,
        // so this tracks the room (fan, music) even while he talks.
        recent.append(db)
        if recent.count > Int(8 / dt) { recent.removeFirst(recent.count - Int(8 / dt)) }
        if recent.count >= 5 { floor = recent.sorted()[recent.count * 15 / 100] }
        let loud = vad.map { $0.isSpeech } ?? (db > max(floor + (isoActive ? 6 : 10), isoActive ? -75 : -55))
        // Hysteresis for "has he stopped talking": a bit below the speech threshold.
        let quiet = vad.map { !$0.isSpeech } ?? (db < max(floor + (isoActive ? 4 : 6), isoActive ? -78 : -58))

        switch mode {
        case .gate:
            preroll.append(buf); prerollFrames += buf.frameLength
            // 2 s before the onset: far away, "Hey" can stay under the gate and only
            // "Claude" opens it, so a long pre-roll keeps the whole wake word.
            while prerollFrames > 32_000, preroll.count > 1 { prerollFrames -= preroll.removeFirst().frameLength }
            loudRun = loud ? loudRun + dt : 0
            // Silero already needs a 256 ms chunk of speech; the level gate needs 0.15 s.
            if loud && (vad != nil || loudRun >= 0.15) {
                log("onset db=\(db) floor=\(floor)")
                mode = .hearing
                segmentTime = 0; quietRun = 0; hintUntil = 0
                samples = []; lastCheck = 0
                beginRecognition()
                for b in preroll { feed(b) }
                preroll.removeAll(); prerollFrames = 0
            }
        case .hearing:
            feed(buf)
            segmentTime += dt
            quietRun = quiet ? quietRun + dt : 0
            // Second opinion: Parakeet re-reads the last 4 s every 1.5 s. Catches a
            // far-field or noisy "Hey Claude" that SpeechAnalyzer misses.
            if segmentTime - lastCheck >= 1.5 { lastCheck = segmentTime; secondOpinion() }
            // Right after the analyzer heard a "Hey": Parakeet back to back for 2 s,
            // so a misheard "Hey Mom" / "Hey bro" is re-read within ~0.6 s (HM-1344).
            else if segmentTime < hintUntil { secondOpinion() }
            if quietRun >= 1.4 || segmentTime >= 12 {
                secondOpinion()
                // The on-device model lags about a second: keep recording while it
                // delivers its last words, then give up if there was no wake word.
                sessionFinish()
                mode = .pending
                pendingTime = 0
                pendingBufs = []
            }
        case .pending:
            append(buf)
            pendingBufs.append(buf)
            pendingTime += dt
            // One more Parakeet look once the pause has settled (the check at the
            // segment end may have been skipped while another was running).
            if pendingTime >= 0.6 && pendingTime - dt < 0.6 { secondOpinion() }
            quietRun = quiet ? quietRun + dt : 0
            if pendingTime >= 2.5 {
                // He kept talking while the last segment was closing: start a new
                // segment with that audio, so a "Hey Claude" said in this window
                // (and the words after it) is not lost.
                let resumed = loud || quietRun < 1.0
                // Overlap: the end of the last segment too, so a wake word cut at
                // the 12 s boundary is heard whole by the next session.
                let carry = tailBufs + pendingBufs
                reset()
                if resumed {
                    log("speech resumed during pending: new segment with \(carry.count) buffers")
                    mode = .hearing
                    segmentTime = 0; quietRun = 0; lastCheck = 0
                    beginRecognition()
                    for b in carry { feed(b) }
                }
            }
        case .command:
            append(buf)
            quietRun = quiet ? quietRun + dt : 0
            // In a room with other voices (TV, a game) the pause never comes: every
            // 1.5 s, Parakeet checks whether he ended with "done" / "that's it" / "over".
            commandTime += dt
            speechLog.append((dt, loud))
            var span = speechLog.reduce(0) { $0 + $1.0 }
            while span > Double(SpeakerID.window) / Self.rate, let first = speechLog.first { span -= first.0; speechLog.removeFirst() }
            if commandTime - lastCheck >= 1.5 { lastCheck = commandTime; endWordCheck() }
            onCommandLevel?(max(0, min(1, (db - floor) / 30)))
            // Another language than English (HM-1351): Whisper reads the subtitles, every 2 s.
            let partialEvery = (commandLanguage ?? "en") == "en" ? 0.8 : 2.0
            // Whisper subtitles wait while Whisper finds the language (one model, one at a time).
            let whisperBusy = (commandLanguage ?? "en") != "en" && langChecking
            if onCommandPartial != nil, !partialBusy, !whisperBusy, commandTime - lastPartial >= partialEvery { lastPartial = commandTime; livePartial() }
            if quietRun == 0 { longPauseReported = false }
            if quietRun >= 1.5 && !longPauseReported && endSilence > 2 { longPauseReported = true; onLongPause?() }
            if Self.debug, Int(Double(samples.count) / Self.rate * 2) % 4 == 0, buf.frameLength > 0 {
                log(String(format: "command db=%.1f floor=%.1f quiet=%.1fs", db, floor, quietRun))
            }
            // With Silero: Smart Turn after a 0.75 s pause, at most `endSilence`; if he
            // says nothing after the wake word, stop after 2.5 s.
            // Own-voice filter: every second, is the last 3 s still his voice? Game
            // voices and a TV count as speech for Silero, so without this his turn
            // would never end while they talk.
            if SpeakerID.isEnrolled, commandTime - lastSpeakerCheck >= 1.0 { lastSpeakerCheck = commandTime; speakerCheck() }
            // HM-1362: subtitles start at once in the language he most likely speaks; the
            // detection runs beside them from 1.5 s of his words and swaps if it differs.
            if loud { voicedSinceWake += dt }
            if !languageSettled, !langChecking,
               voicedSinceWake >= LanguagePick.minSpeech, commandTime - lastLangCheck >= 0.8 {
                lastLangCheck = commandTime; languageCheck()
            }
            // Only after a grace period (the first window still holds the wake word),
            // and only after two checks in a row heard real speech that was not his.
            let othersOnly = commandTime >= Self.othersGrace && otherRun >= 2 && (otherSince.map { commandTime - $0 >= 1.0 } ?? false)
            // Nothing after the wake (Silero heard no speech): before giving up, the
            // recognizer reads what came after the wake phrase. Silero missed his "I think
            // I like" right after a wake on 25 Nov (HM-1360) and the turn ended mid-sentence.
            let silentStart = vad.map { !$0.hasSpoken && commandTime >= noSpeechLimit } ?? false
            if silentStart && noSpeech == .unchecked { noSpeech = .checking; wordsAfterWakeCheck() }
            let over = othersOnly || (vad.map { $0.turnEnded || (silentStart && noSpeech == .nothing) } ?? (quietRun >= endSilence))
            if over || Double(samples.count) / Self.rate >= 120 {
                if othersOnly { log("command ended: only other voices for the last seconds") }
                else if let vad, vad.turnEnded { log("command ended: \(vad.endReason)") }
                else if silentStart { log(String(format: "command ended: nothing said %.1f s after the wake", commandTime)) }
                else if vad == nil { log("command ended: level gate pause") }
                else { log("command ended: 2 minutes") }
                finishCommand()
            }
        case .cancelWatch:
            sessionAppend(buf)
        }
    }

    // A late final result can still carry the wake word after the gate closed.
    private var modeAfterEnd = -1

    private func feed(_ buf: AVAudioPCMBuffer) {
        sessionAppend(buf)
        append(buf)
        tailBufs.append(buf); tailFrames += buf.frameLength
        while tailFrames > 24_000, tailBufs.count > 1 { tailFrames -= tailBufs.removeFirst().frameLength }
    }

    private var tailBufs: [AVAudioPCMBuffer] = []
    private var tailFrames: AVAudioFrameCount = 0
    private var lastCheck = 0.0
    /// Segment time until which Parakeet re-reads continuously (after a "Hey").
    private var hintUntil = 0.0
    private var checking = false

    private var commandTime = 0.0
    /// The language of this command, once the quick checks found it (HM-1351; always
    /// "en" with English only). Parakeet reads English, Whisper any other language.
    private var commandLanguage: String?

    private enum NoSpeech { case unchecked, checking, heardWords, nothing }
    private var noSpeech = NoSpeech.unchecked
    /// Where the command starts in `samples` (after the wake phrase).
    private var wakeIndex = 0
    /// Seconds of his speech (Silero) since the wake.
    private var voicedSinceWake = 0.0
    private var langChecking = false
    private var lastLangCheck = -10.0

    /// Silero heard nothing after the wake: does the recognizer hear words there?
    private func wordsAfterWakeCheck() {
        // From a second before the wake, so the wake phrase is whole and can be cut off.
        let clip = Array(samples[max(0, wakeIndex - 16_000)...])
        let gen = generation, known = commandLanguage
        Task.detached(priority: .userInitiated) { [weak self] in
            let text = await LocalSTT.shared.quick(clip, known: known ?? "en", detect: false).text
            guard let self else { return }
            self.q.async {
                guard gen == self.generation, self.mode == .command else { return }
                let rest = Wake.wakeRange(text).map { String(text[$0.upperBound...]) } ?? text
                let words = rest.trimmingCharacters(in: CharacterSet.letters.inverted)
                if !words.isEmpty && !Speech.isFillerOnly(words) {
                    self.log("Silero heard nothing after the wake, the recognizer did: \(words)")
                    self.noSpeech = .heardWords
                    self.voicedSinceWake = max(self.voicedSinceWake, LanguagePick.minSpeech)
                    self.gate.markSpoken()
                } else {
                    self.noSpeech = .nothing
                }
            }
        }
    }

    /// HM-1362: the language of his words since the wake. Clear: subtitles start in it.
    /// Still unclear after 5 s of speech: the best of his languages.
    /// The detection found the language (or gave up after 5 s of speech).
    private var languageSettled = false
    /// The next subtitle replaces the shown one in a new language.
    private var languageSwapped = false

    private func languageCheck() {
        langChecking = true
        let clip = Array(samples[min(wakeIndex, samples.count)...].suffix(240_000))
        let gen = generation, speech = voicedSinceWake
        Task.detached(priority: .userInitiated) { [weak self] in
            let d = await LocalSTT.shared.language(clip, speech: speech)
            guard let self else { return }
            self.q.async {
                self.langChecking = false
                guard gen == self.generation, self.mode == .command, !self.languageSettled, let d else { return }
                if d.confident {
                    self.languageSettled = true
                    LocalSTT.lastLanguage = d.code
                    let was = self.commandLanguage
                    self.log(String(format: "command language: %@ (clear, top %.2f, margin %.2f, %.1f s speech; assumed %@)", d.code, d.top, d.margin, speech, was ?? "-"))
                    if d.code != was {
                        // Re-read the whole command in the new language right away.
                        self.commandLanguage = d.code
                        self.languageSwapped = true
                        self.lastPartial = -10
                    }
                } else if speech >= 5 {
                    self.languageSettled = true
                    self.log(String(format: "command language: kept %@ (not clear: %@ top %.2f, margin %.2f)", self.commandLanguage ?? "-", d.code, d.top, d.margin))
                }
            }
        }
    }

    private func endWordCheck() {
        guard !checking, samples.count >= 16_000 else { return }
        checking = true
        let clip = Array(samples.suffix(48_000))
        let gen = generation
        // The language comes from `languageCheck`; until then Parakeet listens for the
        // English end words.
        let known = commandLanguage
        Task.detached(priority: .userInitiated) { [weak self] in
            let (text, _) = await LocalSTT.shared.quick(clip, known: known, detect: false)
            guard let self else { return }
            self.q.async {
                self.checking = false
                guard gen == self.generation, self.mode == .command else { return }
                guard Speech.endsWithStopPhrase(text) else { return }
                self.log("command ended on end word: \(text)")
                self.finishCommand()
            }
        }
    }

    /// Subtitles: Parakeet over the last 15 s of the command.
    private func livePartial() {
        guard samples.count >= 8_000 else { return }
        partialBusy = true
        let clip = Array(samples.suffix(240_000))
        let gen = generation
        let known = commandLanguage ?? "en"
        let swap = languageSwapped
        languageSwapped = false
        Task.detached(priority: .userInitiated) { [weak self] in
            let text = await LocalSTT.shared.quick(clip, known: known, detect: false).text
            guard let self else { return }
            self.q.async {
                self.partialBusy = false
                guard gen == self.generation, self.mode == .command, !text.isEmpty else { return }
                // Never a script his language does not use (HM-1362: Turkish shown as Hindi).
                guard Script.fits(text, languages: [known]) else { self.log("subtitle dropped, wrong script for \(known): \(text)"); return }
                if gen == self.generation, self.lastPartialText == nil { self.log(String(format: "first subtitle %.2f s after the wake (%@): %@", self.commandTime, known, text)) }
                self.lastPartialText = text
                self.onCommandPartial?(text, swap)
            }
        }
    }

    /// Runs Parakeet over the last 4 s of this segment; wakes if it hears the wake word.
    private func secondOpinion() {
        guard !checking, samples.count >= 8_000 else { return }
        checking = true
        let clip = Array(samples.suffix(64_000))
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let text = (try? await LocalSTT.shared.transcribe(samples: clip, model: LocalSTT.wakeModel)) ?? ""
            guard let self else { return }
            self.q.async {
                self.checking = false
                self.log("parakeet gen=\(gen) cur=\(self.generation) mode=\(self.mode): \(text)")
                guard gen == self.generation, self.mode == .hearing || self.mode == .pending else { return }
                if !text.isEmpty { self.onHeard?(text) }
                guard Wake.containsWakeWord(text) else { return }
                self.log("wake via parakeet")
                self.wake()
            }
        }
    }

    private func append(_ buf: AVAudioPCMBuffer) {
        samples += UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))
    }

    private func beginRecognition() {
        guard #available(macOS 26, *), let format = analyzerFormat else { log("analyzer not ready"); return }
        generation += 1
        let gen = generation
        session = AnalyzerSession(format: format, fast: fastResults && mode != .cancelWatch, log: { [weak self] in self?.log($0) }) { [weak self] text in
            guard let self else { return }
            self.q.async { self.heard(text, generation: gen) }
        }
    }

    private func sessionAppend(_ buf: AVAudioPCMBuffer) {
        if #available(macOS 26, *) { (session as? AnalyzerSession)?.append(buf) }
    }

    private func sessionFinish() {
        if #available(macOS 26, *) { (session as? AnalyzerSession)?.finish() }
    }

    private func sessionCancel() {
        if #available(macOS 26, *) { (session as? AnalyzerSession)?.cancel() }
        session = nil
    }

    static let debug = UserDefaults.standard.bool(forKey: "debugWake")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private func log(_ m: String) {
        trace?(m)
        guard Self.debug else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("needs-you-wake-debug.log")
        let line = "\(Self.stamp.string(from: Date())) \(source) \(m)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    private func heard(_ text: String, generation gen: Int) {
        log("heard gen=\(gen) cur=\(generation) mode=\(mode): \(text)")
        guard gen == generation else { return }
        if mode == .hearing || mode == .pending { onHeard?(text) }
        if mode == .hearing, Wake.hint(text), segmentTime >= hintUntil {
            hintUntil = segmentTime + 2.0
            secondOpinion()
        }
        switch mode {
        case .hearing where Wake.containsWakeWord(text):
            wake()
        case .hearing where Wake.startsWakeWord(text):
            // "Hey Cl…" as the newest partial: the rest of "Claude" takes the
            // analyzer up to a second more (HM-1344). Needs his voice, like every wake.
            log("wake on partial")
            wake()
        case .pending where Wake.containsWakeWord(text):
            // Wake word recognized just after the pause closed the segment.
            wake()
        case .cancelWatch where ChatMatcher.words(text).contains(where: { $0.hasPrefix("cancel") }):
            // Only audio heard after the countdown started reaches here (startCancelWatch resets).
            onCancelWord?(text)
            reset()
        case .cancelWatch:
            Isolation.note("countdown: heard \u{201C}\(text)\u{201D}, not a stop")
        default:
            break
        }
    }

    private var verifying = false
    private var rewake = false
    private var lastSpeakerCheck = 0.0
    private var speakerChecking = false
    /// Command time when the last 3 s stopped sounding like him.
    private var otherSince: Double?
    /// Speaker checks in a row that heard speech, but not his.
    private var otherRun = 0
    /// Speech (Silero) per buffer over the last 3 s of the command.
    private var speechLog: [(Double, Bool)] = []
    /// No "only other voices" end in the first seconds after the wake word.
    static let othersGrace = 3.0
    /// A speaker window needs this much speech to count as someone else's voice.
    static let minVoiced = 1.0

    /// The wake word counts only in his voice once he has taught the app his voice:
    /// the best 3 s window of the last 5 s must match his voiceprint.
    private func wake() {
        guard mode == .hearing || mode == .pending else { return }
        // A newer wake text while the voice is checked: check again (with more of
        // his voice) if this check fails, e.g. after an early "Hey Cl…" partial.
        guard !verifying else { rewake = true; return }
        guard SpeakerID.isEnrolled else { commitWake(); return }
        verifying = true; rewake = false
        let clip = Array(samples.suffix(80_000))
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let best = try? await SpeakerID.shared.best(clip)
            guard let self else { return }
            self.q.async {
                self.verifying = false
                guard gen == self.generation, self.mode == .hearing || self.mode == .pending else { return }
                if let best, best < SpeakerID.threshold {
                    self.log(String(format: "wake word ignored: not his voice (%.2f < %.2f)", best, SpeakerID.threshold))
                    if self.rewake { self.rewake = false; self.wake() }
                    return
                }
                self.log(String(format: "wake: his voice %.2f", best ?? -1))
                self.commitWake()
            }
        }
    }

    private func speakerCheck() {
        guard !speakerChecking, samples.count >= 24_000 else { return }
        speakerChecking = true
        let clip = Array(samples.suffix(SpeakerID.window))
        let gen = generation, at = commandTime
        // Silence or near-silence is nobody's voice: CAM++ scores it near 0, which
        // used to end his turn as "only other voices" while he paused (HM-1345).
        let voiced = speechLog.reduce(0) { $0 + ($1.1 ? $1.0 : 0) }
        let level = Self.peakLevel(clip)
        guard voiced >= Self.minVoiced, level > Self.silentBelow else {
            log(String(format: "speaker check skipped: too little speech (%.1f s, %.0f dB), not other voices", voiced, level))
            otherSince = nil; otherRun = 0; speakerChecking = false
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let score = try? await SpeakerID.shared.best(clip)
            guard let self else { return }
            self.q.async {
                self.speakerChecking = false
                guard gen == self.generation, self.mode == .command, let score else { return }
                if score >= SpeakerID.otherBelow { self.otherSince = nil; self.otherRun = 0 }
                else {
                    self.otherRun += 1
                    if self.otherSince == nil { self.otherSince = at }
                    self.log(String(format: "not his voice in the last 3 s (%.2f, %.1f s speech, %.0f dB, %d in a row)", score, voiced, level, self.otherRun))
                }
            }
        }
    }

    /// Hands the command over; with a voiceprint, stretches without his voice
    /// (game dialogue, TV) are silenced first so they do not end up in the message.
    private func finishCommand() {
        let audio = samples
        reset()
        let snr = Self.snr(audio)
        guard SpeakerID.isEnrolled else { deliver(Recorder.wav(audio), nil, snr); return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let score = try? await SpeakerID.shared.best(audio)
            let only = (try? await SpeakerID.shared.onlyHim(audio)) ?? nil
            let wav = Recorder.wav(only ?? audio)
            guard let self else { return }
            self.q.async { self.deliver(wav, score ?? nil, snr) }
        }
    }

    private func deliver(_ wav: Data, _ score: Float?, _ snr: Float) {
        if let onUtterance { onUtterance(wav, score, snr) } else { onCommand?(wav) }
    }

    /// Speech vs background in dB: loud 20 ms frames (90th percentile) over quiet ones (15th).
    static func snr(_ s: [Float]) -> Float {
        let n = 320
        guard s.count >= n * 10 else { return 0 }
        var db: [Float] = []
        var i = 0
        while i + n <= s.count {
            var e: Float = 0
            for j in i..<i + n { e += s[j] * s[j] }
            db.append(10 * log10(e / Float(n) + 1e-10)); i += n
        }
        db.sort()
        return db[db.count * 90 / 100] - db[db.count * 15 / 100]
    }

    /// The other mic woke: record this command too (even if this mic missed the
    /// wake word), so the better take can be picked.
    func forceWake() {
        q.async {
            guard self.running, self.mode != .command, self.mode != .cancelWatch else { return }
            if self.mode == .gate { self.samples = []; self.beginRecognition() }
            self.log("wake forced by the other mic")
            self.commitWake(notify: false)
        }
    }

    /// The turn shortcut (HM-1354): a command starts now, as if the wake phrase had
    /// been heard, without the wake word or the own-voice check.
    func openTurn() {
        q.async {
            guard self.running, self.mode != .command, self.mode != .cancelWatch else { return }
            self.reset()
            self.log("wake by the turn shortcut")
            self.commitWake(manual: true)
        }
    }

    /// The turn shortcut again while he talks: his command ends now, like "done".
    func endTurn() {
        q.async {
            guard self.mode == .command else { return }
            self.log("command ended by the turn shortcut")
            self.finishCommand()
        }
    }

    /// Escape once while he says a command (HM-1396): what he said so far is dropped and
    /// the command starts over, as if he had just opened his turn.
    func restartCommand() {
        q.async {
            guard self.mode == .command else { return }
            self.log("command restarted by Escape")
            self.reset()
            self.commitWake(notify: false, manual: true)
        }
    }

    /// Escape twice: the command is dropped; nothing is sent.
    func cancelCommand() {
        q.async {
            guard self.mode == .command else { return }
            self.log("command cancelled by Escape")
            self.reset()
        }
    }

    private func commitWake(notify: Bool = true, manual: Bool = false) {
        // A thinking pause right after "Hey Claude," is normal (HM-1360): 4 s, not 2.5.
        noSpeechLimit = manual ? 6 : 4
        sessionCancel()
        otherSince = nil; otherRun = 0; speechLog = []; lastSpeakerCheck = 0
        // Subtitles start at once, in his last language this session, else his first one.
        commandLanguage = SpokenLanguages.onlyEnglish ? "en" : (LocalSTT.lastLanguage ?? SpokenLanguages.enabled[0])
        languageSettled = SpokenLanguages.onlyEnglish; languageSwapped = false; lastPartialText = nil
        // First subtitle 0.4 s into the command, then every 0.8 s (2 s with Whisper).
        commandTime = 0; lastCheck = 0; lastPartial = commandLanguage == "en" ? -0.4 : -1.6
        noSpeech = .unchecked; wakeIndex = samples.count; voicedSinceWake = 0; langChecking = false; lastLangCheck = -10
        // A pause that would end the turn: is the thought left open ("I think I like")?
        gate.holdOpen = { [weak self] _ in
            guard let self else { return false }
            // The command so far, from a second before the wake: a pause right after
            // "Hey Claude, this one:" has no words of the message yet.
            let (lang, clip) = self.q.sync { (self.commandLanguage, Array(self.samples[max(0, self.wakeIndex - 16_000)...].suffix(128_000))) }
            var (open, text) = await EndOfTurn.heldOpen(clip, language: lang)
            if !open, !text.isEmpty, Router.messageAfterTarget(text).isEmpty {
                open = true // only the wake phrase and the chat name so far
            }
            self.q.async { self.log(String(format: "%@ (%.1f s read): ", open ? "pause kept open, the thought is not finished" : "pause ends the turn", Double(clip.count) / 16_000) + text) }
            return open
        }
        gate.cap = endSilence
        gate.judgeAfter = Prefs.judgePause
        gate.resetTurn()
        gate.useTurnModel = true
        mode = .command
        quietRun = min(quietRun, 1.0)
        if notify { onWake?() }
    }

    private func reset() {
        sessionCancel()
        mode = .gate
        samples = []
        pendingBufs = []
        tailBufs = []; tailFrames = 0
        loudRun = 0; quietRun = 0; segmentTime = 0; hintUntil = 0
        gate.useTurnModel = false
        gate.holdOpen = nil
        modeAfterEnd = -1
        generation += 1
    }

    /// Below this (loud 20 ms frames, dBFS) a window counts as silence.
    static let silentBelow: Float = -55

    /// Level of the loud part of a clip: the 90th percentile of 20 ms frame levels.
    static func peakLevel(_ s: [Float]) -> Float {
        let n = 320
        guard s.count >= n else { return -140 }
        var db: [Float] = []
        var i = 0
        while i + n <= s.count {
            var e: Float = 0
            for j in i..<i + n { e += s[j] * s[j] }
            db.append(10 * log10(e / Float(n) + 1e-14)); i += n
        }
        db.sort()
        return db[db.count * 90 / 100]
    }

    private static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        return 20 * log10(max(sqrt(sum / Float(buffer.frameLength)), 1e-7))
    }
}

/// The wake phrase (Settings → Hey Claude → Wake phrase, default "Hey Claude")
/// and its matcher (NeedsYouShared/WakeMatcher.swift).
enum Wake {
    static let defaultsKey = "wakePhrase"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached = WakeMatcher(phrase: WakeMatcher.defaultPhrase)
    nonisolated(unsafe) private static var cachedRaw = WakeMatcher.defaultPhrase

    /// The matcher for the phrase in Settings (rebuilt when it changes).
    static var matcher: WakeMatcher {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? WakeMatcher.defaultPhrase
        return lock.withLock {
            if cachedRaw != raw { cached = WakeMatcher(phrase: raw); cachedRaw = raw }
            return cached
        }
    }
    /// The phrase as he set it, e.g. "Hey Claude".
    static var phrase: String { matcher.phrase }
    /// The name in it ("Claude").
    static var name: String { matcher.name }

    static func wakeRange(_ text: String) -> Range<String.Index>? {
        matcher.range(in: text, voiceLearned: SpeakerID.isEnrolled)
    }

    static func containsWakeWord(_ text: String) -> Bool { wakeRange(text) != nil }

    /// A "Hey" (or the phrase's first word) among the newest words of a partial.
    static func hint(_ text: String) -> Bool { matcher.hint(text) }

    /// The analyzer's newest partial ends in "Hey Cl…" (the phrase with only the
    /// start of its last word). Only with his voice learned, since the voice check
    /// is what keeps "hey, close it" from waking.
    static func startsWakeWord(_ text: String) -> Bool {
        SpeakerID.isEnrolled && matcher.startsPhrase(text)
    }

    /// The words after the first wake phrase (a repeat right after it is skipped).
    static func afterWakeWord(_ text: String) -> String? {
        matcher.after(text, voiceLearned: SpeakerID.isEnrolled)
    }
}

/// One SpeechAnalyzer run over one stretch of speech.
@available(macOS 26, *)
final class AnalyzerSession {
    private let builder: AsyncStream<AnalyzerInput>.Continuation
    private var task: Task<Void, Never>?
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    static func makeTranscriber(fast: Bool = false) async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw NSError(domain: "NeedsYou", code: 5, userInfo: [NSLocalizedDescriptionKey: "English speech model not supported"])
        }
        // `fast` trades some accuracy for earlier results (used by the stop detector).
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: fast ? [.volatileResults, .fastResults] : [.volatileResults], attributeOptions: [])
    }

    /// `onText` gets the text so far (finished phrases plus the current guess).
    init(format: AVAudioFormat, fast: Bool = false, log: @escaping (String) -> Void, onText: @escaping (String) -> Void) {
        self.format = format
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        builder = cont
        task = Task {
            do {
                let transcriber = try await Self.makeTranscriber(fast: fast)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                // Bias toward the words that matter here (ignored where unsupported).
                let context = AnalysisContext()
                context.contextualStrings[.general] = Wake.matcher.contextualStrings + ["Stop Claude"] + Names.vocabulary
                try? await analyzer.setContext(context)
                try await analyzer.start(inputSequence: stream)
                var finals = ""
                let reader = Task {
                    for try await r in transcriber.results {
                        let text = String(r.text.characters)
                        if r.isFinal { finals += text; onText(finals) } else { onText(finals + text) }
                    }
                }
                await withTaskCancellationHandler {
                    try? await analyzer.finalizeAndFinishThroughEndOfInput()
                    _ = try? await reader.value
                } onCancel: {
                    reader.cancel()
                    Task { await analyzer.cancelAndFinishNow() }
                }
            } catch {
                log("analyzer error: \(error.localizedDescription)")
            }
        }
    }

    func append(_ buf: AVAudioPCMBuffer) {
        var input = buf
        if buf.format != format {
            if converter == nil { converter = AVAudioConverter(from: buf.format, to: format) }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * format.sampleRate / buf.format.sampleRate) + 64
            guard let conv = converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            input = out
        }
        builder.yield(AnalyzerInput(buffer: input))
    }

    func finish() { builder.finish() }

    func cancel() {
        builder.finish()
        task?.cancel()
    }
}

/// Voice isolation for live audio: an offline-rendering engine (player -> AUSoundIsolation)
/// fed one mic buffer at a time. A live graph on the input node fails to start on this
/// Mac (-10875); offline rendering works and costs ~1 % CPU.
final class IsoMeter {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private let out: AVAudioPCMBuffer

    init?() {
        guard let fx = Isolation.makeEffect() else { return nil }
        engine.attach(player); engine.attach(fx)
        engine.connect(player, to: fx, format: format)
        engine.connect(fx, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 16384)
            try engine.start()
        } catch {
            Isolation.note("iso meter: \(error.localizedDescription)")
            return nil
        }
        player.play()
        out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 16384)!
    }

    private let queue = DispatchQueue(label: "needs-you.iso")

    /// Stops rendering; call from the owner (not from a tap block).
    func shutdown() { queue.sync { engine.stop() } }
    private var pending = 0
    private let lock = NSLock()

    /// Queues a mic buffer; `done` gets the isolated level later, off the audio thread.
    /// Rendering inside a tap callback deadlocks AVAudioEngine, so it never happens there.
    func submit(_ buf: AVAudioPCMBuffer, done: @escaping (Float) -> Void) {
        lock.lock()
        if pending > 4 { lock.unlock(); return } // never pile up work if the queue falls behind
        pending += 1
        lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else { return }
        copy.frameLength = buf.frameLength
        for c in 0..<Int(buf.format.channelCount) {
            if let s = buf.floatChannelData?[c], let d = copy.floatChannelData?[c] { memcpy(d, s, Int(buf.frameLength) * 4) }
        }
        queue.async { [weak self] in
            guard let self else { return }
            if self.engine.isRunning, let l = self.level(copy) { done(l) }
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
        }
    }

    /// Synchronous level, for offline use (never from a tap block).
    func measure(_ buf: AVAudioPCMBuffer) -> Float? { queue.sync { level(buf) } }

    /// Level (dB) of the isolated voice in this buffer.
    private func level(_ buf: AVAudioPCMBuffer) -> Float? {
        if source != buf.format { converter = AVAudioConverter(from: buf.format, to: format); source = buf.format }
        guard let conv = converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 48_000 / buf.format.sampleRate) + 32
        guard cap <= 16384, let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var fed = false
        conv.convert(to: mono, error: nil) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true; s.pointee = .haveData; return buf
        }
        guard mono.frameLength > 0 else { return nil }
        player.scheduleBuffer(mono, completionHandler: nil)
        guard (try? engine.renderOffline(mono.frameLength, to: out)) == .success,
              let ch = out.floatChannelData?[0], out.frameLength > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<Int(out.frameLength) { sum += ch[i] * ch[i] }
        return 20 * log10(max(sqrt(sum / Float(out.frameLength)), 1e-7))
    }
}

/// Apple's on-device voice isolation audio unit (AUSoundIsolation, 'vois').
enum Isolation {
    static let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x766f6973,
                                                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    /// mic -> mono mixer -> voice isolation -> silent main mixer, with a level tap
    /// on the isolated signal. Returns the added nodes ([] when unavailable or off).
    static func attach(to engine: AVAudioEngine, input: AVAudioInputNode, inFormat: AVAudioFormat,
                       level: @escaping (Float) -> Void) -> [AVAudioNode] {
        guard UserDefaults.standard.object(forKey: "noiseReduction") as? Bool ?? true, let fx = makeEffect(),
              let mono = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1) else { return [] }
        let down = AVAudioMixerNode()
        engine.attach(down); engine.attach(fx)
        engine.connect(input, to: down, format: inFormat)
        engine.connect(down, to: fx, format: mono)
        engine.connect(fx, to: engine.mainMixerNode, format: mono)
        engine.mainMixerNode.outputVolume = 0 // never play the mic back
        fx.installTap(onBus: 0, bufferSize: 4096, format: mono) { buf, _ in
            guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            level(20 * log10(max(sqrt(sum / Float(buf.frameLength)), 1e-7)))
        }
        return [down, fx]
    }

    /// Audio setup problems, for diagnosis (no audio, no secrets).
    static func note(_ m: String) {
        let url = Wire.supportDir.appendingPathComponent("audio.log")
        let line = "\(Date()) \(m)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    static func detach(_ engine: AVAudioEngine, _ nodes: inout [AVAudioNode]) {
        if let fx = nodes.last { fx.removeTap(onBus: 0) }
        for n in nodes { engine.disconnectNodeOutput(n); engine.detach(n) }
        nodes = []
    }

    /// Starts the engine; if the isolation graph will not start, drops it and starts plain.
    static func start(_ engine: AVAudioEngine, nodes: inout [AVAudioNode], fellBack: () -> Void) throws {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            guard !nodes.isEmpty else { throw error }
            engine.stop()
            detach(engine, &nodes)
            fellBack()
            engine.prepare()
            try engine.start()
        }
    }

    static func makeEffect() -> AVAudioUnitEffect? {
        guard AVAudioUnitComponentManager.shared().components(matching: desc).first != nil else { return nil }
        let fx = AVAudioUnitEffect(audioComponentDescription: desc)
        AudioUnitSetParameter(fx.audioUnit, 95782 /* wet/dry % */, kAudioUnitScope_Global, 0, 100, 0)
        return fx
    }

    /// Level (dB) of the isolated signal for each `chunk` frames of the file, through the
    /// same meter (and 48 kHz conversion) as the live mic.
    static func levels(of file: AVAudioFile, chunk: AVAudioFrameCount) -> [Float]? {
        guard let meter = IsoMeter() else { return nil }
        defer { meter.shutdown() }
        file.framePosition = 0
        var out: [Float] = []
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                  (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 else { break }
            out.append(meter.measure(buf) ?? -100)
        }
        return out
    }
}
