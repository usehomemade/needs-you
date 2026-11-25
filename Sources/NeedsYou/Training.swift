import AVFoundation
import CoreAudio
import Foundation
import NeedsYouShared

// MARK: - Prompts

/// One line he reads (or a stretch of silence) during a training session.
struct TrainingPrompt: Codable, Hashable {
    enum Kind: String, Codable { case wake, command, name, free, silent }
    var kind: Kind
    var text: String
    /// Seconds the prompt stays up before it moves on by itself (free talk, silence).
    var auto: Double?

    /// The words he is expected to say (silent and free talk have none).
    var expected: String? { kind == .silent || kind == .free ? nil : text }
    var hasWake: Bool { kind == .wake || kind == .command }
}

enum TrainingPrompts {
    /// One round, about 3 minutes; it repeats for longer sessions.
    /// The lines with his wake phrase in place of "Hey Claude".
    /// Lines with the user's name are left out when no name is set.
    static var round: [TrainingPrompt] {
        let name = UserName.value
        return roundTemplate.compactMap { p in
            var p = p
            if p.text.contains("{name}") {
                guard let name else { return nil }
                p.text = p.text.replacingOccurrences(of: "{name}", with: name)
            }
            p.text = p.text.replacingOccurrences(of: "Hey Claude", with: Wake.phrase)
            return p
        }
    }
    static let roundTemplate: [TrainingPrompt] = [
        .init(kind: .wake, text: "Hey Claude."),
        .init(kind: .command, text: "Hey Claude, this one: run the tests."),
        .init(kind: .silent, text: "Don't speak.", auto: 10),
        .init(kind: .name, text: "{name} here. Please check the build."),
        .init(kind: .command, text: "Hey Claude, website: what's the status of the deploy?"),
        .init(kind: .wake, text: "Hey Claude."),
        .init(kind: .command, text: "Hey Claude, this one: merge it into next and promote it."),
        .init(kind: .free, text: "What are you doing right now?", auto: 20),
        .init(kind: .command, text: "Hey Claude, this one: stop the dev server, then restart it."),
        .init(kind: .name, text: "Ask {name} before you change anything on the server."),
        .init(kind: .silent, text: "Don't speak.", auto: 10),
        .init(kind: .command, text: "Hey Claude, needs you: read me the last answer again."),
        .init(kind: .wake, text: "Hey Claude, done."),
        .init(kind: .command, text: "Hey Claude, this one: open the pull request and tell me if it's green."),
        .init(kind: .free, text: "What did you eat today?", auto: 20),
        .init(kind: .command, text: "Hey Claude, website: show me the errors from the last hour."),
        .init(kind: .name, text: "This is {name}. Send the invoice tomorrow."),
        .init(kind: .wake, text: "Hey Claude."),
        .init(kind: .command, text: "Hey Claude, this one: that's all for now, thanks."),
    ]

    static func at(_ i: Int) -> TrainingPrompt { round[i % round.count] }
}

// MARK: - Sessions

struct TrainingSession: Codable, Identifiable, Hashable {
    struct Mark: Codable, Hashable {
        var prompt: TrainingPrompt
        var start: Double   // seconds into the Mac track
        var end: Double
    }
    var id: String          // folder name
    var date: Date
    var background: String  // Quiet, Music, Game, Video, Other people
    var duration: Double
    var hasPhone: Bool
    /// iPhone track start minus Mac track start, from the host clock (seconds).
    var phoneOffset: Double?
    var marks: [Mark]

    var folder: URL { TrainingStore.root.appendingPathComponent(id, isDirectory: true) }
    var macURL: URL { folder.appendingPathComponent("mac.wav") }
    var phoneURL: URL { folder.appendingPathComponent("iphone.wav") }
}

enum TrainingStore {
    static var root: URL { Wire.supportDir.appendingPathComponent("training", isDirectory: true) }

    static func list() -> [TrainingSession] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("session.json")) else { return nil }
            return try? dec.decode(TrainingSession.self, from: data)
        }.sorted { $0.date > $1.date }
    }

    static func save(_ s: TrainingSession, mac: [Float], phone: [Float]?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: s.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Recorder.wav(mac).write(to: s.macURL)
        if let phone { try Recorder.wav(phone).write(to: s.phoneURL) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: s.folder.appendingPathComponent("session.json"))
    }

    static func delete(_ s: TrainingSession) { try? FileManager.default.removeItem(at: s.folder) }

    static func load(_ url: URL) -> [Float] {
        (try? Data(contentsOf: url)).map { Recorder.samples(fromWav: $0) } ?? []
    }
}

// MARK: - Recording

/// Records the Mac mic and (when the switch is on and it is nearby) the iPhone
/// mic for up to 30 minutes, with pause/resume, levels and guided prompts.
@MainActor
final class TrainingRecorder: ObservableObject {
    static let shared = TrainingRecorder()
    static let maxSeconds = 30.0 * 60

    enum State { case idle, recording, paused, saving }
    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed = 0.0
    @Published private(set) var levels: [Float] = [0, 0]  // 0...1, mac and iphone
    @Published private(set) var promptIndex = 0
    @Published private(set) var phoneName: String?
    @Published var background = "Game"
    @Published private(set) var lastError: String?

    var prompt: TrainingPrompt { TrainingPrompts.at(promptIndex) }

    private let tap = DualTap()
    private var marks: [TrainingSession.Mark] = []
    @Published private(set) var promptStart = 0.0
    private var timer: Timer?

    func start() {
        guard state == .idle else { return }
        lastError = nil
        let mac = Prefs.micUID.isEmpty ? nil : Prefs.micUID
        let phone = VoiceCommands.shared.phoneMic ? AudioDevices.continuityMic() : nil
        Conductor.shared.borrowMics(true)
        // The wake listeners let go of the mics first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            do {
                try tap.start(mac: mac, phone: phone?.id)
                phoneName = tap.hasPhone ? phone?.name : nil
                marks = []; promptIndex = 0; promptStart = 0; elapsed = 0
                state = .recording
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch {
                lastError = error.localizedDescription
                tap.stop()
                Conductor.shared.borrowMics(false)
            }
        }
    }

    private func tick() {
        guard state == .recording || state == .paused else { return }
        elapsed = tap.seconds
        levels = tap.levels
        if state == .recording, let auto = prompt.auto, elapsed - promptStart >= auto { next() }
        if elapsed >= Self.maxSeconds { stop() }
    }

    /// He finished the line on screen: mark it and show the next one.
    func next() {
        guard state == .recording else { return }
        let now = tap.seconds
        marks.append(.init(prompt: prompt, start: promptStart, end: now))
        promptIndex += 1
        promptStart = now
    }

    func pause() {
        guard state == .recording else { return }
        // The line on screen is cut at the pause; it shows again after resume.
        tap.paused = true
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        promptStart = tap.seconds
        tap.paused = false
        state = .recording
    }

    func stop() {
        guard state == .recording || state == .paused else { return }
        if state == .recording, tap.seconds - promptStart > 1.5 { marks.append(.init(prompt: prompt, start: promptStart, end: tap.seconds)) }
        timer?.invalidate(); timer = nil
        state = .saving
        let (mac, phone, offset) = tap.finish()
        Conductor.shared.borrowMics(false)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let s = TrainingSession(id: f.string(from: Date()), date: Date(), background: background,
                                duration: Double(mac.count) / 16_000, hasPhone: phone != nil,
                                phoneOffset: offset, marks: marks)
        do { if mac.count > 16_000 { try TrainingStore.save(s, mac: mac, phone: phone) } } catch { lastError = error.localizedDescription }
        state = .idle
        TrainingLab.shared.reload()
    }
}

/// Two mic taps (Mac + optional iPhone) at 16 kHz mono, appending only while not paused.
final class DualTap: @unchecked Sendable {
    private var engines: [AVAudioEngine] = []
    private var tracks: [[Float]] = [[], []]
    private var host: [UInt64?] = [nil, nil]
    private var level: [Float] = [0, 0]
    private let lock = NSLock()
    private var _paused = false
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    var paused: Bool {
        get { lock.withLock { _paused } }
        set {
            lock.withLock {
                // Keep the two tracks the same length across a pause.
                if newValue && engines.count == 2 {
                    let n = max(tracks[0].count, tracks[1].count)
                    for k in 0..<2 where tracks[k].count < n { tracks[k] += [Float](repeating: 0, count: n - tracks[k].count) }
                }
                _paused = newValue
            }
        }
    }
    var hasPhone: Bool { engines.count == 2 }
    var seconds: Double { lock.withLock { Double(tracks[0].count) / 16_000 } }
    var levels: [Float] { lock.withLock { level } }

    func start(mac: String?, phone: String?) throws {
        tracks = [[], []]; host = [nil, nil]; _paused = false
        try open(mac, index: 0)
        if let phone {
            do { try open(phone, index: 1) } catch { Isolation.note("training: iPhone mic failed (\(error.localizedDescription))") }
        }
    }

    private func open(_ uid: String?, index k: Int) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid, let device = AudioDevices.inputs().first(where: { $0.id == uid }), let unit = input.audioUnit {
            var id = device.deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: Self.format) else {
            throw NSError(domain: "NeedsYou", code: 11, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, time in
            guard let self else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / buf.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: cap) else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            let chunk = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
            let db = 20 * log10(max(rms, 1e-6))
            self.lock.withLock {
                self.level[k] = max(0, min(1, (db + 60) / 60))
                if self.host[k] == nil, time.isHostTimeValid { self.host[k] = time.hostTime }
                if !self._paused { self.tracks[k] += chunk }
            }
        }
        engine.prepare()
        try engine.start()
        engines.append(engine)
    }

    func stop() {
        for e in engines { e.inputNode.removeTap(onBus: 0); e.stop() }
        engines = []
    }

    /// The two tracks and the iPhone's start offset (seconds after the Mac's).
    func finish() -> ([Float], [Float]?, Double?) {
        let two = engines.count == 2
        stop()
        return lock.withLock {
            var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
            func secs(_ h: UInt64?) -> Double? { h.map { Double($0) * Double(tb.numer) / Double(tb.denom) / 1e9 } }
            let offset: Double? = two ? (secs(host[1]) ?? 0) - (secs(host[0]) ?? 0) : nil
            return (tracks[0], two ? tracks[1] : nil, offset)
        }
    }
}
