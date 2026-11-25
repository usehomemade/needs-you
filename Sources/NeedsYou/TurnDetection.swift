import AVFoundation
import CoreML
import FluidAudio
import Foundation
import NeedsYouShared

/// Silero v5 voice activity (FluidAudio), one probability per 256 ms chunk.
actor SileroVAD {
    static let shared = SileroVAD()
    static let chunk = VadManager.chunkSize // 4096 samples, 256 ms
    private var manager: VadManager?

    func load() async throws -> VadManager {
        if let manager { return manager }
        let m = try await VadManager(config: .default)
        manager = m
        return m
    }

    /// Speech probability for each 256 ms chunk of 16 kHz mono audio, carrying state.
    func probabilities(_ samples: [Float]) async throws -> [Float] {
        let m = try await load()
        var state = await m.makeStreamState()
        var out: [Float] = []
        var i = 0
        while i < samples.count {
            let chunk = Array(samples[i..<min(i + Self.chunk, samples.count)])
            let r = try await m.processStreamingChunk(chunk, state: state)
            state = r.state
            out.append(r.probability)
            i += Self.chunk
        }
        return out
    }
}

/// Pipecat Smart Turn v3.2 (BSD-2, CoreML port by aufklarer): probability that
/// the speaker has finished, from the last 8 s of audio (prosody, not words).
actor SmartTurn {
    static let shared = SmartTurn()
    static let window = 128_000
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/smart-turn-v3.2-coreml", isDirectory: true)
    }
    private var model: MLModel?

    /// Fetches the compiled model once (16.8 MB, BSD-2 notice in LICENSE).
    static func download() async throws {
        let base = "https://huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML/resolve/main/"
        let files = ["LICENSE", "config.json", "smart_turn.mlmodelc/coremldata.bin", "smart_turn.mlmodelc/model.mil",
                     "smart_turn.mlmodelc/analytics/coremldata.bin", "smart_turn.mlmodelc/weights/weight.bin"]
        for f in files {
            let dest = directory.appendingPathComponent(f)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: URL(string: base + f)!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "NeedsYou", code: 7, userInfo: [NSLocalizedDescriptionKey: "Smart Turn download failed: \(f)"])
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
    }

    func load() throws -> MLModel {
        if let model { return model }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        let m = try MLModel(contentsOf: Self.directory.appendingPathComponent("smart_turn.mlmodelc"), configuration: cfg)
        model = m
        return m
    }

    func unload() { model = nil }

    /// `audio`: 16 kHz mono, most recent last. Uses the last 8 s, zero-padded in front.
    func probability(_ audio: ArraySlice<Float>) throws -> Float {
        let m = try load()
        let arr = try MLMultiArray(shape: [1, NSNumber(value: Self.window)], dataType: .float32)
        let tail = audio.suffix(Self.window)
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: Self.window)
        let pad = Self.window - tail.count
        for i in 0..<pad { ptr[i] = 0 }
        for (j, v) in tail.enumerated() { ptr[pad + j] = v }
        let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: arr)]))
        return out.featureValue(for: "probability")?.multiArrayValue?[0].floatValue ?? 0
    }
}

/// Offline A/B of end-of-turn methods on a recording (test hook `turn-test`).
/// Times are seconds from the start of the file.
enum TurnBench {
    static func run(_ url: URL, method: String) async -> String {
        do {
            let samples = try AudioConverter().resampleAudioFile(url)
            let dur = Double(samples.count) / 16_000
            let probs = try await SileroVAD.shared.probabilities(samples)
            let step = Double(SileroVAD.chunk) / 16_000
            // Last chunk with speech = where his speech really ends in this file.
            let lastSpeech = probs.lastIndex(where: { $0 >= 0.5 }).map { Double($0 + 1) * step }
            var ends: [String: Any] = ["duration": val(dur), "speechEnd": val(lastSpeech)]
            let t0 = Date()
            switch method {
            case "probs":
                ends["probs"] = probs.map { (Double($0) * 100).rounded() / 100 }
            case "old":
                ends["end"] = val(lastSpeech.map { $0 + 3.0 })
            case "silero":
                // Silero alone with a fixed hangover of `hold` seconds.
                ends["end"] = val(sileroEnd(probs, step: step, hold: 1.0))
            case let m where m.hasPrefix("smart"):
                let minSilence = Double(m.split(separator: "@").last.flatMap { Double($0) == nil ? nil : $0 } ?? "0.75") ?? 0.75
                var started = false, silence = 0.0, calls = 0
                var end: Double?
                for (i, p) in probs.enumerated() {
                    let t = Double(i + 1) * step
                    if p >= 0.5 { started = true; silence = 0; continue }
                    guard started, p < 0.35 else { continue }
                    silence += step
                    if silence >= minSilence - 0.01 {
                        calls += 1
                        let upTo = min(samples.count, Int(t * 16_000))
                        let pr = try await SmartTurn.shared.probability(samples[0..<upTo])
                        var done = pr > 0.5 || silence >= 2.0
                        if method.hasPrefix("smart+") && done && silence < 3.0 {
                            // A thought left hanging ("and", "uh") is not a finished turn.
                            let text = try await LocalSTT.shared.transcribe(samples: Array(samples[max(0, upTo - 80_000)..<upTo]))
                            if EndOfTurn.trailsOff(text) { done = false; ends["held"] = text }
                        }
                        if done { end = t; ends["prob"] = val(Double(pr)); break }
                    }
                }
                ends["end"] = val(end); ends["calls"] = calls
            default:
                // Parakeet EOU (FluidAudio) was tried on 23 Nov: it heard nothing in most of
                // the user's recordings, so it is not kept.
                return "unknown method \(method): old, silero, smart, smart@<pause>, smart+, probs"
            }
            ends["computeMs"] = Int(Date().timeIntervalSince(t0) * 1000)
            let data = try JSONSerialization.data(withJSONObject: ends, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    static func val(_ d: Double?) -> Any { d.map { ($0 * 100).rounded() / 100 } ?? NSNull() }

    static func sileroEnd(_ probs: [Float], step: Double, hold: Double) -> Double? {
        var started = false, silence = 0.0
        for (i, p) in probs.enumerated() {
            if p >= 0.5 { started = true; silence = 0; continue }
            guard started, p < 0.35 else { continue }
            silence += step
            if silence >= hold { return Double(i + 1) * step }
        }
        return nil
    }
}

enum EndOfTurn {
    /// The last word leaves the sentence open: a filler or a joining word (HM-1360).
    static func trailsOff(_ text: String) -> Bool { TurnText.trailsOff(text) }

    /// Re-reads the last 8 s and says whether the thought is left open ("I think I like",
    /// "when I try to"). Parakeet (~60 ms) for English, Whisper in his language otherwise.
    static func heldOpen(_ audio: [Float], language: String?) async -> (Bool, String) {
        let clip = Array(audio.suffix(128_000))
        guard clip.count >= 8_000 else { return (false, "") }
        // At most 0.8 s: this runs while the pause is timed (Whisper can be busy with
        // subtitles); no answer in time ends the turn as before.
        let box = TextRace()
        let text: String? = await withCheckedContinuation { c in
            box.set(c)
            Task.detached { box.finish(await LocalSTT.shared.quick(clip, known: language ?? "en", detect: false).text) }
            Task.detached { try? await Task.sleep(nanoseconds: 800_000_000); box.finish(nil) }
        }
        guard let text else { return (false, "(no answer in 0.8 s)") }
        return (trailsOff(text), text)
    }
}

/// The first of two answers wins (a transcript, or nil when the time ran out).
private final class TextRace: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<String?, Never>?
    func set(_ c: CheckedContinuation<String?, Never>) { lock.withLock { self.c = c } }
    func finish(_ v: String?) {
        let c = lock.withLock { () -> CheckedContinuation<String?, Never>? in let x = self.c; self.c = nil; return x }
        c?.resume(returning: v)
    }
}

/// Live voice activity and end of turn for one listening session.
/// Feed 16 kHz mono audio from any thread; Silero (256 ms chunks) runs on its
/// own task in order. After he has spoken, a pause of `judgeAfter` asks Smart Turn
/// whether he is done; a pause of `cap` seconds ends the turn regardless.
/// Measured on the user's reading clips (23 Nov): turn ends 0.8 s after his last
/// word (3.0 s before), no early cut-offs on his "uh" pauses.
final class SpeechGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float] = []
    private var history: [Float] = []        // last 8 s, for Smart Turn
    private var prob: Float = 0
    private var speechNow = false
    private var spoken = false
    private var silence = 0.0
    private var judged = false
    private var ended = false
    private var failed = false
    private let feed: AsyncStream<[Float]>.Continuation
    private var task: Task<Void, Never>?
    var cap: Double
    /// Pause before Smart Turn is asked (0.75 s measured best on clips; the default is 2 s).
    var judgeAfter: Double
    var useTurnModel: Bool
    /// Called (off the main thread) once the turn is over.
    var onTurnEnd: (() -> Void)?
    /// HM-1360: asked with the recent audio when a pause would end the turn (Smart Turn
    /// says done, or the pause reaches `cap`). True = the thought is left open
    /// ("I think I like", "when I try to"): the turn stays open for `holdExtra` more.
    var holdOpen: (([Float]) async -> Bool)? {
        get { lock.withLock { hold } }
        set { lock.withLock { hold = newValue } }
    }
    private var hold: (([Float]) async -> Bool)?
    /// Extra pause allowed while the thought is left open.
    var holdExtra: Double = 2.5
    /// Why the turn ended, for the debug log.
    private(set) var endReason = ""
    private var held = false
    private var capAsked = false

    init(cap: Double = 4.0, judgeAfter: Double = 2.0, useTurnModel: Bool = true) {
        self.cap = cap
        self.judgeAfter = judgeAfter
        self.useTurnModel = useTurnModel
        let (stream, cont) = AsyncStream.makeStream(of: [Float].self)
        feed = cont
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let vad = try await SileroVAD.shared.load()
                var state = await vad.makeStreamState()
                for await chunk in stream {
                    let r = try await vad.processStreamingChunk(chunk, state: state)
                    state = r.state
                    await self?.update(r.probability, chunk: chunk)
                }
            } catch {
                self?.lock.withLock { self?.failed = true }
                Isolation.note("vad: Silero unavailable (\(error.localizedDescription)); level gate instead")
            }
        }
    }

    deinit { feed.finish(); task?.cancel() }

    func stop() { feed.finish(); task?.cancel() }

    /// False when Silero could not load: callers fall back to their level gate.
    var available: Bool { lock.withLock { !failed } }
    var probability: Float { lock.withLock { prob } }
    /// Hysteresis: speech above 0.5, silence below 0.35.
    var isSpeech: Bool { lock.withLock { speechNow } }
    var hasSpoken: Bool { lock.withLock { spoken } }
    var silenceSeconds: Double { lock.withLock { silence } }
    var turnEnded: Bool { lock.withLock { ended } }

    func push(_ samples: [Float]) {
        lock.lock()
        pending += samples
        var chunks: [[Float]] = []
        while pending.count >= SileroVAD.chunk {
            chunks.append(Array(pending.prefix(SileroVAD.chunk)))
            pending.removeFirst(SileroVAD.chunk)
        }
        lock.unlock()
        for c in chunks { feed.yield(c) }
    }

    /// Starts a fresh turn (same Silero stream).
    func resetTurn() {
        lock.withLock { spoken = false; silence = 0; judged = false; ended = false; held = false; capAsked = false; endReason = ""; history.removeAll() }
    }

    /// He did speak, though Silero missed it (HM-1360: the words after the wake
    /// were read by the recognizer): from now on pauses count as usual.
    func markSpoken() {
        lock.withLock { if !spoken { spoken = true; silence = 0; judged = false } }
    }

    private func update(_ p: Float, chunk: [Float]) async {
        let (judge, capHit) = advance(p, chunk: chunk)
        var endNow = false
        var reason = ""
        if let judge, let pr = try? await SmartTurn.shared.probability(judge[...]), pr > 0.5 {
            // Still silent while the model ran?
            endNow = lock.withLock { !speechNow }
            reason = String(format: "Smart Turn %.2f after %.1f s pause", pr, judgeAfter)
            if endNow, let hold = holdOpen, await hold(judge) {
                endNow = false
                lock.withLock { held = true }
            }
        }
        if let capAudio = capHit {
            endNow = true
            reason = "pause reached \(lock.withLock { held } ? "the longer limit" : "the limit")"
            if !lock.withLock({ held }), let hold = holdOpen, await hold(capAudio) {
                // Still silent, and the thought is left open: wait a bit longer.
                endNow = false
                lock.withLock { held = true }
            }
        }
        if endNow {
            let first = lock.withLock { () -> Bool in
                if ended || speechNow { return false }
                ended = true; endReason = reason; return true
            }
            if first { onTurnEnd?() }
        }
    }

    private func advance(_ p: Float, chunk: [Float]) -> ([Float]?, [Float]?) {
        let step = Double(chunk.count) / 16_000
        var judge: [Float]?
        var capHit: [Float]?
        lock.lock(); defer { lock.unlock() }
        prob = p
        history += chunk
        if history.count > SmartTurn.window { history.removeFirst(history.count - SmartTurn.window) }
        if p >= 0.5 { speechNow = true } else if p < 0.35 { speechNow = false }
        if speechNow {
            spoken = true; silence = 0; judged = false; held = false; capAsked = false
        } else if spoken && !ended {
            silence += step
            let limit = cap + (held ? holdExtra : 0)
            if silence >= limit {
                // Once per limit: the cap asks whether the thought is open, the longer one ends.
                if held || !capAsked || hold == nil { capHit = history; capAsked = true }
            } else if useTurnModel && silence >= judgeAfter - 0.01 && !judged && !held { judged = true; judge = history }
        }
        return (judge, capHit)
    }
}
