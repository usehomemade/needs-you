import AVFoundation
import Foundation
import NeedsYouShared
import Speech

/// Plays Needs You's voice and listens for "Stop, Mac" while it plays.
///
/// The voice goes out through the same engine whose mic has Apple's voice
/// processing on (echo cancellation), so the detector does not hear Needs You
/// itself. If voice processing will not start, it falls back to a plain engine
/// (mic + speaker), and as a second guard ignores a stop phrase that is part of
/// the text being spoken.
final class VoicePlayer {
    struct Result { var interrupted: Bool; var spokenUntil: String }


    /// A lone "Stop." heard on its own: the recognizer often gives "Stop" a second
    /// or more before it settles on the name. Only used when the spoken text has no "stop".
    static let bareStopPattern = #"(?i)(^|[.!?]\s*)stop[.!]?\s*$"#

    /// "Stop, <name>" from the wake phrase ("Stop, Mac" by default), mishearings
    /// included (WakeMatcher.isStop). It only listens while Needs You is talking.
    static func isStop(_ heard: String) -> Bool {
        Wake.matcher.isStop(heard, voiceLearned: SpeakerID.isEnrolled)
    }
    private var bareStopOK = false
    private var spoken = ""

    /// "Stop, Mac" from him: a stop phrase that is not the voice's own words leaking back.
    private func heardStop(_ heard: String, fast: Bool) -> Bool {
        let stop = Self.isStop(heard) || (bareStopOK && heard.range(of: Self.bareStopPattern, options: .regularExpression) != nil)
        guard stop else { return false }
        if SpokenEcho.isEcho(heard, spoken: spoken) {
            Isolation.note("voice: stop phrase ignored, it is the spoken text\(fast ? " (fast)" : ""): \(heard)")
            return false
        }
        return true
    }

    private var engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var session: AnyObject?
    private var fast: FastStopDetector?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    /// Plays `audio` (WAV or MP3). With `listen`, "Stop, Mac" ends it early.
    func play(_ audio: Data, text: String, volume: Float, listen: Bool) async throws -> Result {
        let ext = audio.prefix(4) == Data("RIFF".utf8) ? "wav" : "mp3"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("needs-you-voice-\(UUID().uuidString).\(ext)")
        try audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "NeedsYou", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot decode speech audio"])
        }
        try file.read(into: buf)
        let total = Double(buf.frameLength) / file.processingFormat.sampleRate

        // What is being said: the detector ignores words that come from it (HM-1410),
        // so a line that contains "Stop, Mac" no longer turns the detector off.
        spoken = text
        var detecting = listen && WakeListener.authorized
        bareStopOK = text.range(of: #"(?i)\bstop"#, options: .regularExpression) == nil
        if detecting, #available(macOS 26, *), WakeListener.analyzerFormatCache == nil {
            // Hey Mac may be off: load the on-device model's format once.
            try? await WakeListener().prepare()
        }
        if WakeListener.analyzerFormatCache == nil { detecting = false }
        // Its voice processing ducks other audio on its own: the listening ducker
        // steps aside meanwhile (HM-1413) and takes over again after, if he still talks.
        defer { Ducker.shared.voice(false) }
        do {
            let vp = UserDefaults.standard.object(forKey: "bargeInVoiceProcessing") as? Bool ?? true
            if detecting && vp { Ducker.shared.voice(true) }
            try start(format: buf.format, volume: volume, detect: detecting, voiceProcessing: vp)
            Isolation.note("voice: playing, stop detector \(detecting ? "on" : "off"), voice processing \(detecting && vp ? "on" : "off")")
        } catch {
            Isolation.note("voice: voice processing failed (\(error.localizedDescription)); plain playback")
            teardown()
            Ducker.shared.voice(false)
            engine = AVAudioEngine()
            do { try start(format: buf.format, volume: volume, detect: detecting, voiceProcessing: false) } catch {
                Isolation.note("voice: detector failed (\(error.localizedDescription)); playing without it")
                teardown()
                engine = AVAudioEngine()
                detecting = false
                try start(format: buf.format, volume: volume, detect: false, voiceProcessing: false)
            }
        }

        lock.withLock { finished = false }
        let began = Date()
        let interrupted: Bool = await withCheckedContinuation { c in
            lock.lock(); continuation = c; lock.unlock()
            player.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.end(false)
            }
            player.play()
        }
        let elapsed = Date().timeIntervalSince(began)
        teardown()
        if !interrupted { return Result(interrupted: false, spokenUntil: text) }
        return Result(interrupted: true, spokenUntil: Self.prefix(of: text, fraction: elapsed / max(total, 0.1)))
    }

    /// Stops at once (menu Stop or the stop phrase).
    func stop() { end(true) }

    private func end(_ interrupted: Bool) {
        lock.lock()
        guard !finished, let c = continuation else { lock.unlock(); return }
        finished = true
        continuation = nil
        lock.unlock()
        if interrupted { player.stop() }
        c.resume(returning: interrupted)
    }

    private func start(format: AVAudioFormat, volume: Float, detect: Bool, voiceProcessing: Bool) throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.volume = volume
        if detect {
            let input = engine.inputNode
            if voiceProcessing {
                try input.setVoiceProcessingEnabled(true)
                if #available(macOS 14, *) {
                    // Do not duck his music or calls while Needs You talks.
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                }
            }
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
                throw NSError(domain: "NeedsYou", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
            }
            guard #available(macOS 26, *), let aFormat = WakeListener.analyzerFormatCache else {
                throw NSError(domain: "NeedsYou", code: 4, userInfo: [NSLocalizedDescriptionKey: "Speech model not ready"])
            }
            let s = AnalyzerSession(format: aFormat, fast: true, log: { Isolation.note("voice detector: \($0)") }) { [weak self] heard in
                if WakeListener.debug { Isolation.note("voice: detector heard: \(heard)") }
                guard let self else { return }
                if self.heardStop(heard, fast: false) {
                    Isolation.note("voice: stop phrase heard")
                    self.end(true)
                }
            }
            session = s
            do {
                let f = FastStopDetector(matches: { [weak self] heard in
                    self?.heardStop(heard, fast: true) ?? false
                }, onStop: { [weak self] heard in
                    Isolation.note("voice: stop phrase heard (fast: \(heard))")
                    self?.end(true)
                })
                fast = f
                f.start()
            }
            let mono = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1)
            Isolation.note("voice: detector input \(inFormat.sampleRate) Hz x\(inFormat.channelCount)")
            var taps = 0
            let fastRef = fast
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak s, weak fastRef] buf, _ in
                taps += 1
                fastRef?.append(buf)
                if WakeListener.debug, taps % 25 == 1, let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
                    var sum: Float = 0
                    for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
                    Isolation.note(String(format: "voice: detector tap %d level %.1f dB", taps, 20 * log10(max(sqrt(sum / Float(buf.frameLength)), 1e-7))))
                }
                // Voice processing may hand over several channels; the first is the cleaned mic.
                if buf.format.channelCount > 1, let mono, let one = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength),
                   let src = buf.floatChannelData?[0], let dst = one.floatChannelData?[0] {
                    one.frameLength = buf.frameLength
                    memcpy(dst, src, Int(buf.frameLength) * 4)
                    s?.append(one)
                } else {
                    s?.append(buf)
                }
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func teardown() {
        if #available(macOS 26, *) { (session as? AnalyzerSession)?.cancel() }
        session = nil
        fast?.stop(); fast = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        if engine.inputNode.isVoiceProcessingEnabled { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }

    /// The words spoken before the stop, estimated from how far playback got.
    static func prefix(of text: String, fraction: Double) -> String {
        let f = max(0, min(1, fraction))
        guard f < 0.98 else { return text }
        let cut = text.index(text.startIndex, offsetBy: Int(Double(text.count) * f))
        var head = String(text[..<cut])
        if cut < text.endIndex, text[cut].isLetter, let sp = head.lastIndex(where: { $0 == " " }) { head = String(head[..<sp]) }
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
