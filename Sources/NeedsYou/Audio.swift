import NeedsYouShared
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Playback

final class Player: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?

    @MainActor
    func play(_ data: Data, volume: Float) async throws {
        let p = try AVAudioPlayer(data: data)
        p.volume = volume
        p.delegate = self
        player = p
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            if !p.play() { finish() }
        }
        player = nil
    }

    /// Stops at once (Escape, the turn shortcut).
    func stop() { player?.stop(); finish() }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finish() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { finish() }

    private func finish() {
        let c = continuation
        continuation = nil
        c?.resume()
    }
}

// MARK: - Input devices

struct InputDevice: Identifiable, Hashable {
    var id: String // CoreAudio UID
    var name: String
    var deviceID: AudioDeviceID
}

enum AudioDevices {
    static func inputs() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: uid, name: name, deviceID: id)
        }
    }

    /// The iPhone's Continuity microphone, when the iPhone is nearby.
    static func continuityMic() -> InputDevice? {
        inputs().first { d in
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var t: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(d.deviceID, &addr, 0, nil, &size, &t) == noErr else { return false }
            return t == kAudioDeviceTransportTypeContinuityCaptureWired || t == kAudioDeviceTransportTypeContinuityCaptureWireless
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

// MARK: - Recording with voice activity detection

/// Opens the mic (or, for tests, plays a file through the same path in real
/// time), waits up to `wait` seconds for speech to start, then records until
/// `silenceToStop` seconds of quiet, `stop()`, or `maxSpeech`. Audio is kept
/// as 16 kHz mono, starting a second before the speech did.
final class Recorder {
    struct Result { var file: URL; var duration: Double }

    var onLevel: ((Float, Bool) -> Void)? // normalized 0...1, speaking
    /// Called once per pause of `pauseCheck` seconds after speech started,
    /// with a WAV of everything so far (used to catch "done" / "that's it").
    var onPause: ((Data) -> Void)?
    var pauseCheck: Double = 0.9
    /// Once per pause of 1.5 s: "still listening" tick.
    var onLongPause: (() -> Void)?
    private var longPauseReported = false

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Result?, Error>?
    private var usingEngine = false
    private var isoNodes: [AVAudioNode] = []
    private var meter: IsoMeter?
    private var isoLevel: Float = -100
    private var isoActive = false

    // VAD state (touched only on the audio thread, or the file feeder thread).
    private var samples: [Float] = []
    private var preroll: [Float] = []
    private var noise: [Float] = []
    private var threshold: Float = -42
    private var speaking = false
    private var elapsed = 0.0, loudRun = 0.0, quietRun = 0.0, speechTime = 0.0
    private var pauseReported = false
    private var wait = 30.0, silenceToStop = 3.0, maxSpeech = 120.0
    private var dir: URL?
    /// Silero + Smart Turn; the level gate below is only the fallback.
    private var gate: SpeechGate?
    /// HM-1360: asked when a pause would end the answer; true keeps it open a bit longer.
    var holdOpen: (([Float]) async -> Bool)?

    static let rate = 16_000.0
    private static let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    func record(wait: Double, deviceUID: String?, silenceToStop: Double, judgePause: Double = 2.0, maxSpeech: Double = 120,
                testFile: AVAudioFile? = nil) async throws -> Result? {
        self.wait = wait; self.silenceToStop = silenceToStop; self.maxSpeech = maxSpeech
        gate = SpeechGate(cap: silenceToStop, judgeAfter: judgePause)
        gate?.holdOpen = holdOpen
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("needs-you-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        dir = d
        finished = false

        if let file = testFile {
            guard let conv = AVAudioConverter(from: file.processingFormat, to: Self.outFormat) else {
                throw NSError(domain: "NeedsYou", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot convert test audio"])
            }
            Thread.detachNewThread { [self] in
                let chunk: AVAudioFrameCount = 2048
                while !isFinished {
                    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                    if (try? file.read(into: buf, frameCount: chunk)) == nil || buf.frameLength == 0 {
                        // End of file counts as silence until the VAD decides.
                        let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
                        silence.frameLength = chunk
                        for c in 0..<Int(silence.format.channelCount) {
                            memset(silence.floatChannelData![c], 0, Int(chunk) * MemoryLayout<Float>.size)
                        }
                        process(silence, converter: conv)
                        Thread.sleep(forTimeInterval: Double(chunk) / file.processingFormat.sampleRate)
                        continue
                    }
                    process(buf, converter: conv)
                    Thread.sleep(forTimeInterval: Double(buf.frameLength) / file.processingFormat.sampleRate)
                }
            }
        } else {
            // Never leave the user without a mic. Each failed attempt (e.g. -10875 while the
            // device is still leaving voice processing) starts again on a fresh engine:
            // isolation meter, then plain input, then plain input on the default mic.
            let attempts: [(iso: Bool, uid: String?, delay: Double)] = [(true, deviceUID, 0), (false, deviceUID, 0.3), (false, nil, 0.8)]
            for (i, a) in attempts.enumerated() {
                if a.delay > 0 { try await Task.sleep(nanoseconds: UInt64(a.delay * 1_000_000_000)) }
                do {
                    try setUpMic(deviceUID: a.uid, iso: a.iso)
                    if i > 0 { Isolation.note("recorder: started on attempt \(i + 1) (iso \(a.iso))") }
                    break
                } catch {
                    Isolation.note("recorder: mic attempt \(i + 1) failed (\(error.localizedDescription))")
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    meter?.shutdown(); meter = nil
                    engine = AVAudioEngine()
                    isoNodes = []
                    isoActive = false
                    usingEngine = false
                    if i == attempts.count - 1 { throw error }
                }
            }
        }

        let result = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Result?, Error>) in
            lock.lock(); continuation = c; let done = finished; lock.unlock()
            if done { c.resume(returning: nil) }
        }
        if result == nil { try? FileManager.default.removeItem(at: d) }
        return result
    }

    private func setUpMic(deviceUID: String?, iso: Bool) throws {
        do {
            let input = engine.inputNode
            if let uid = deviceUID, !uid.isEmpty,
               let device = AudioDevices.inputs().first(where: { $0.id == uid }),
               let unit = input.audioUnit {
                var devID = device.deviceID
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
                  let conv = AVAudioConverter(from: inFormat, to: Self.outFormat) else {
                throw NSError(domain: "NeedsYou", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
            }
            // Gate on Apple's voice isolation level, like the Hey Mac listener.
            meter = (iso && (UserDefaults.standard.object(forKey: "noiseReduction") as? Bool ?? true)) ? IsoMeter() : nil
            isoActive = meter != nil
            input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
                guard let self else { return }
                self.meter?.submit(buffer) { [weak self] in self?.isoLevel = $0 }
                self.process(buffer, converter: conv)
            }
            usingEngine = true
            engine.prepare()
            try engine.start()
        }
    }

    /// Ends the recording now and keeps what was said (stop phrase heard).
    func stop() {
        lock.lock(); let have = speaking; lock.unlock()
        finishWithAudio(have)
    }

    func cancel() { finish(nil) }

    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        if isFinished { return }
        let dt = Double(buffer.frameLength) / buffer.format.sampleRate
        let db = isoActive ? isoLevel : Self.rmsDB(buffer)
        elapsed += dt

        if elapsed < 0.4 {
            noise.append(db)
        } else if !noise.isEmpty {
            let floor = noise.sorted()[noise.count / 2]
            threshold = isoActive ? min(max(floor + 8, -72), -20) : min(max(floor + 14, -48), -20)
            noise.removeAll()
        }

        let cap = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: cap) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        let chunk = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))

        let vad = gate.flatMap { $0.available ? $0 : nil }
        vad?.push(chunk)
        let loud = vad.map { $0.isSpeech } ?? (elapsed >= 0.4 && db > threshold)
        lock.lock()
        if !speaking {
            loudRun = loud ? loudRun + dt : max(0, loudRun - dt / 2)
            preroll += chunk
            if preroll.count > 16_000 { preroll.removeFirst(preroll.count - 16_000) } // 1 s pre-roll
            if vad != nil ? loud : loudRun >= 0.22 {
                speaking = true
                samples = preroll
                preroll.removeAll()
            }
        } else {
            samples += chunk
            speechTime += dt
            if let vad {
                quietRun = vad.silenceSeconds
                if quietRun == 0 { pauseReported = false }
            } else if db > threshold - 4 {
                quietRun = 0
                pauseReported = false
                longPauseReported = false
            } else {
                quietRun += dt
            }
        }
        let isSpeaking = speaking
        lock.unlock()

        if !isSpeaking {
            if elapsed > wait { finish(nil); return }
        } else {
            if quietRun >= pauseCheck && !pauseReported {
                pauseReported = true
                lock.lock(); let snap = samples; lock.unlock()
                onPause?(Self.wav(snap))
            }
            if quietRun >= 1.5 && !longPauseReported && silenceToStop > 2 {
                longPauseReported = true
                onLongPause?()
            }
            let over = vad.map { $0.turnEnded } ?? (quietRun >= silenceToStop)
            if over || speechTime >= maxSpeech { finishWithAudio(true); return }
        }
        onLevel?(max(0, min(1, (db + 60) / 50)), isSpeaking)
    }

    /// The audio recorded so far (for live subtitles).
    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func finishWithAudio(_ have: Bool) {
        guard have, let dir else { finish(nil); return }
        lock.lock(); let snap = samples; lock.unlock()
        let url = dir.appendingPathComponent("answer.wav")
        do {
            try Self.wav(snap).write(to: url)
            finish(Result(file: url, duration: Double(snap.count) / Self.rate))
        } catch {
            finish(nil)
        }
    }

    private func finish(_ result: Result?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation
        continuation = nil
        lock.unlock()
        gate?.stop()
        DispatchQueue.main.async {
            if self.usingEngine {
                Isolation.detach(self.engine, &self.isoNodes)
                self.meter?.shutdown(); self.meter = nil
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
            }
            c?.resume(returning: result)
        }
    }

    /// 16-bit mono WAV.
    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    private static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return 20 * log10(max(rms, 1e-7))
    }
}


/// Which mic won each utterance (Mac or iPhone), for checking the pick later.
enum MicLog {
    static func write(_ line: String) {
        let url = Wire.supportDir.appendingPathComponent("mic-choice.log")
        let f = ISO8601DateFormatter()
        let text = "\(f.string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}
