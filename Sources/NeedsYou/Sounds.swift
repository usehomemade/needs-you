import AVFoundation
import Foundation

/// Short cues. Default set: Rosewood (HM-1348), soft marimba and a log drum,
/// built from CC0 recordings (VCSL, see ACKNOWLEDGEMENTS.md) and bundled as WAV
/// in Resources/Sounds/Rosewood. "Classic" is the old in-app synthesis, kept
/// so the two can be compared in Settings. Volume is separate from the voice.
enum Cue: String, CaseIterable {
    case listening   // wake word heard / your turn
    case gotIt       // listening ended
    case sending     // 2 s countdown starts
    case sent        // delivered
    case cancelled   // not sent
    case noAnswer    // gave up
    case stopped     // "Stop, Mac": voice cut, now listening
    case dndOn       // do not disturb turned on
    case dndOff      // do not disturb turned off

    var label: String {
        switch self {
        case .listening: return "Listening"
        case .gotIt: return "Got it"
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .cancelled: return "Cancelled"
        case .noAnswer: return "No answer"
        case .stopped: return "Stopped, listening"
        case .dndOn: return "Do not disturb on"
        case .dndOff: return "Do not disturb off"
        }
    }
}

enum SoundSet: String, CaseIterable, Identifiable {
    case rosewood, classic
    var id: String { rawValue }
    var label: String { self == .rosewood ? "Rosewood" : "Classic" }
    static let key = "soundSet"
    static var current: SoundSet {
        SoundSet(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .rosewood
    }
}

final class Sounds {
    static let shared = Sounds()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let rate = 44_100.0
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    private struct Loaded { var buffer: AVAudioPCMBuffer; var audible: Double }
    private var cache: [String: Loaded] = [:]
    private let lock = NSLock()

    static var volume: Float {
        let v = UserDefaults.standard.object(forKey: "soundVolume") as? Double ?? 1.0
        return Float(max(0, min(1, v)))
    }

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Loads every cue of the current set into memory, so the wake chime only
    /// has to schedule a ready buffer (HM-1344). Called at launch and when the set changes.
    func preload() {
        lock.lock(); defer { lock.unlock() }
        let set = SoundSet.current
        for cue in Cue.allCases { _ = loaded(cue, set) }
    }

    /// Plays a cue without waiting.
    func play(_ cue: Cue) {
        lock.lock(); defer { lock.unlock() }
        guard Self.volume > 0 else { return }
        do {
            if !engine.isRunning { try engine.start() }
            player.volume = Self.volume
            player.scheduleBuffer(loaded(cue, SoundSet.current).buffer, at: nil, options: .interrupts)
            if !player.isPlaying { player.play() }
        } catch {}
    }

    /// Plays a cue and waits until it has finished (the ring has died down).
    func playAndWait(_ cue: Cue) async {
        play(cue)
        try? await Task.sleep(nanoseconds: UInt64((duration(cue) + 0.05) * 1_000_000_000))
    }

    /// How long the cue is heard: up to where it falls 30 dB under its peak.
    /// The rest of the file is a quiet room tail that the mic can ignore.
    func duration(_ cue: Cue) -> Double {
        lock.lock(); defer { lock.unlock() }
        return loaded(cue, SoundSet.current).audible
    }

    /// Test hook: how long a cue takes from the call to a scheduled-ready buffer
    /// (no engine start, nothing plays).
    func bufferReadyTime(_ cue: Cue) -> Double {
        lock.lock(); defer { lock.unlock() }
        let t = Date()
        _ = loaded(cue, SoundSet.current)
        return Date().timeIntervalSince(t)
    }

    private func loaded(_ cue: Cue, _ set: SoundSet) -> Loaded {
        let key = set.rawValue + "/" + cue.rawValue
        if let l = cache[key] { return l }
        let l = (set == .rosewood ? file(cue, folder: "Rosewood") : nil) ?? synth(cue)
        cache[key] = l
        return l
    }

    // MARK: Bundled sets

    /// Contents/Resources/Sounds in the app; the repo's Resources/Sounds for `swift run`.
    private static let soundsDir: URL? = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Sounds")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }()

    private func file(_ cue: Cue, folder: String) -> Loaded? {
        guard let url = Self.soundsDir?.appendingPathComponent("\(folder)/\(cue.rawValue).wav"),
              let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              f.processingFormat.sampleRate == rate, f.processingFormat.channelCount == 1,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, buf.frameLength > 0
        else { return nil }
        let n = Int(buf.frameLength), x = buf.floatChannelData![0]
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(x[i])) }
        var last = n - 1
        while last > 0 && abs(x[last]) < peak * 0.0316 { last -= 1 }  // -30 dB
        return Loaded(buffer: buf, audible: Double(last + 1) / rate)
    }

    // MARK: Classic (synthesized)

    private struct Note { var freq: Double; var start: Double; var length: Double; var gain: Double = 1; var sweepTo: Double? = nil; var buzz = false }

    private func notes(_ cue: Cue) -> [Note] {
        let C5 = 523.25, E5 = 659.25, G5 = 783.99, C6 = 1046.5, A4 = 440.0, F4 = 349.23, D4 = 293.66, E4 = 329.63, C4 = 261.63, G4 = 392.0
        switch cue {
        case .listening: return [Note(freq: C5, start: 0, length: 0.14), Note(freq: G5, start: 0.11, length: 0.22)]
        case .gotIt:     return [Note(freq: G5, start: 0, length: 0.14), Note(freq: C5, start: 0.11, length: 0.24)]
        case .sending:   return [Note(freq: 600, start: 0, length: 0.22, gain: 0.8, sweepTo: 1200)]
        case .sent:      return [Note(freq: C5, start: 0, length: 0.1), Note(freq: E5, start: 0.08, length: 0.1), Note(freq: G5, start: 0.16, length: 0.1), Note(freq: C6, start: 0.24, length: 0.3)]
        case .cancelled: return [Note(freq: E4, start: 0, length: 0.14, buzz: true), Note(freq: C4, start: 0.15, length: 0.24, buzz: true)]
        case .stopped:   return [Note(freq: 900, start: 0, length: 0.12, gain: 0.8, sweepTo: 450), Note(freq: C5, start: 0.16, length: 0.12), Note(freq: G5, start: 0.27, length: 0.2)]
        case .noAnswer:  return [Note(freq: A4, start: 0, length: 0.22), Note(freq: F4, start: 0.22, length: 0.22), Note(freq: D4, start: 0.44, length: 0.4)]
        case .dndOn:     return [Note(freq: G4, start: 0, length: 0.14), Note(freq: C4, start: 0.13, length: 0.3)]
        case .dndOff:    return [Note(freq: C4, start: 0, length: 0.14), Note(freq: G4, start: 0.13, length: 0.3)]
        }
    }

    private func synth(_ cue: Cue) -> Loaded {
        let ns = notes(cue)
        let total = (ns.map { $0.start + $0.length }.max() ?? 0.2) + 0.25
        let count = Int(total * rate)
        var out = [Float](repeating: 0, count: count)
        for n in ns {
            let s0 = Int(n.start * rate), len = Int((n.length + 0.2) * rate)
            var phase = 0.0
            for i in 0..<len where s0 + i < count {
                let t = Double(i) / rate
                let f = n.sweepTo.map { n.freq + ($0 - n.freq) * min(1, t / n.length) } ?? n.freq
                phase += 2 * .pi * f / rate
                // Fast attack, bell-like decay; short fade at the end so nothing clicks.
                let env = min(1, t / 0.006) * exp(-t / (n.length * 0.55)) * min(1, Double(len - i) / (0.01 * rate))
                var v = sin(phase) + 0.35 * sin(2 * phase) + 0.15 * sin(3 * phase)
                if n.buzz { v += 0.25 * sin(5 * phase) + 0.2 * sin(7 * phase) }
                out[s0 + i] += Float(v * env * n.gain)
            }
        }
        let peak = out.map(abs).max() ?? 1
        let scale = peak > 0 ? 0.9 / peak : 1
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buf.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { buf.floatChannelData![0][i] = out[i] * scale }
        return Loaded(buffer: buf, audible: Double(count) / rate)
    }
}
