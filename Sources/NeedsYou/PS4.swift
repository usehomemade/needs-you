import CoreML
import FluidAudio
import Foundation
import NeedsYouShared

/// PS4 target speaker extraction (Ning et al., Apache-2.0): pulls his voice out of a
/// mix before transcription. Settings → Models → "Voice extraction (PS4)", default off.
///
/// Our own model definition (tools/ps4), converted to Core ML by tools/ps4/export_coreml.py.
/// The models live in ~/Library/Application Support/Needs You/models/ps4 and are never
/// committed. Runs on the GPU: about 30-50 ms per second of audio on an M5 Pro, 0.5-0.8 GB while loaded.
actor PS4 {
    static let shared = PS4()

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "ps4Enabled") }
    static var dir: URL { Wire.supportDir.appendingPathComponent("models/ps4", isDirectory: true) }
    /// Up to 10 s of his voice, written whenever his voice is learned.
    static var enrollURL: URL { Wire.supportDir.appendingPathComponent("ps4-enroll.wav") }
    static var embeddingURL: URL { Wire.supportDir.appendingPathComponent("ps4-embedding.json") }
    /// Input lengths the model was exported with (seconds); audio is padded up to one.
    static let lengths = [1, 2, 4, 6, 8, 12, 16, 24, 32]
    static let enrollSamples = 160_000
    static let maxPiece = 8

    nonisolated static var installed: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("PS4Embed.mlpackage").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("PS4Extract-fp16.mlpackage").path)
    }
    nonisolated static var hasEnrollment: Bool { FileManager.default.fileExists(atPath: enrollURL.path) }

    private var extractor: MLModel?
    private var embedding: MLMultiArray?
    private var idle: Task<Void, Never>?

    /// Saves up to 10 s of his speech for PS4 (called when his voice is learned).
    nonisolated static func saveEnrollment(_ clips: [[Float]]) {
        var all: [Float] = []
        for c in clips where all.count < enrollSamples { all += c.prefix(enrollSamples - all.count) }
        guard all.count >= 48_000 else { return }
        try? FileManager.default.createDirectory(at: Wire.supportDir, withIntermediateDirectories: true)
        try? Recorder.wav(all).write(to: enrollURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: enrollURL.path)
        try? FileManager.default.removeItem(at: embeddingURL)
        Task { await shared.dropEmbedding() }
    }

    func dropEmbedding() { embedding = nil }

    private func compiled(_ name: String) throws -> URL {
        let pkg = Self.dir.appendingPathComponent("\(name).mlpackage")
        let out = Self.dir.appendingPathComponent("\(name).mlmodelc")
        let fm = FileManager.default
        let pkgDate = (try? fm.attributesOfItem(atPath: pkg.path)[.modificationDate] as? Date) ?? .distantPast
        let outDate = (try? fm.attributesOfItem(atPath: out.path)[.modificationDate] as? Date) ?? .distantPast
        if fm.fileExists(atPath: out.path), outDate >= pkgDate { return out }
        let tmp = try MLModel.compileModel(at: pkg)
        try? fm.removeItem(at: out)
        try fm.moveItem(at: tmp, to: out)
        return out
    }

    private func loadExtractor() throws -> MLModel {
        if let extractor { return extractor }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU // the BiLSTMs run 8x slower on the Neural Engine path
        let m = try MLModel(contentsOf: try compiled("PS4Extract-fp16"), configuration: cfg)
        extractor = m
        return m
    }

    private func speakerEmbedding() throws -> MLMultiArray? {
        if let embedding { return embedding }
        let arr = try MLMultiArray(shape: [1, 192], dataType: .float32)
        if let d = try? Data(contentsOf: Self.embeddingURL), let v = try? JSONDecoder().decode([Float].self, from: d), v.count == 192 {
            for i in 0..<192 { arr[i] = NSNumber(value: v[i]) }
            embedding = arr
            return arr
        }
        guard Self.hasEnrollment else { return nil }
        var wav = try AudioConverter().resampleAudioFile(Self.enrollURL)
        wav = Self.highPass(wav)
        guard wav.count >= 16_000 else { return nil }
        let peak = max(wav.map(abs).max() ?? 1, 1e-6)
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.enrollSamples)], dataType: .float32)
        for i in 0..<Self.enrollSamples { input[i] = NSNumber(value: wav[i % wav.count] / peak) } // tiled to 10 s
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        let m = try MLModel(contentsOf: try compiled("PS4Embed"), configuration: cfg)
        let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["enroll": input]))
        guard let e = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        var v = [Float](repeating: 0, count: 192)
        for i in 0..<192 { v[i] = e[i].floatValue; arr[i] = e[i] }
        try? JSONEncoder().encode(v).write(to: Self.embeddingURL, options: .atomic)
        embedding = arr
        return arr
    }

    /// DC removal plus a first-order 80 Hz high-pass: the Mac mic clips carry a large
    /// DC offset, and with it PS4 cut his voice by 20-30 dB in the offline check.
    static func highPass(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        let mean = x.reduce(0, +) / Float(x.count)
        let a: Float = 1 / (1 + 2 * .pi * 80 / 16_000)
        var y = [Float](repeating: 0, count: x.count)
        var prevX: Float = x[0] - mean, prevY: Float = 0
        for i in 0..<x.count {
            let xi = x[i] - mean
            let yi = a * (prevY + xi - prevX)
            y[i] = yi; prevX = xi; prevY = yi
        }
        return y
    }

    /// His voice extracted from `samples` (16 kHz), or nil when PS4 is off, not set up,
    /// or the result looks wrong (then the caller keeps the original audio).
    func extract(_ samples: [Float], force: Bool = false) async -> [Float]? {
        guard Self.enabled || force, Self.installed, samples.count >= 8_000 else { return nil }
        do {
            guard let emb = try speakerEmbedding() else {
                Isolation.note("ps4: no enrollment yet (learn your voice first)")
                return nil
            }
            let m = try loadExtractor()
            let t0 = Date()
            let x = Self.highPass(samples)
            // 8 s pieces: GPU memory grows with length (32 s pieces took the app to ~2 GB).
            let maxLen = Self.maxPiece * 16_000
            var out: [Float] = []
            out.reserveCapacity(x.count)
            var start = 0
            while start < x.count {
                let piece = Array(x[start..<min(x.count, start + maxLen)])
                let len = (Self.lengths.first { $0 * 16_000 >= piece.count } ?? Self.maxPiece) * 16_000
                let input = try MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .float32)
                let p = input.dataPointer.bindMemory(to: Float.self, capacity: len)
                for i in 0..<len { p[i] = i < piece.count ? piece[i] : 0 }
                let r = try await m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mix": input, "embedding": emb]))
                guard let y = r.featureValue(for: "target")?.multiArrayValue else { return nil }
                for i in 0..<piece.count { out.append(y[i].floatValue) }
                start += maxLen
            }
            let rms = { (a: [Float]) -> Float in sqrt(a.reduce(0) { $0 + $1 * $1 } / Float(max(a.count, 1))) }
            let ratio = 20 * log10(max(rms(out), 1e-9) / max(rms(x), 1e-9))
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            armIdle()
            // Near-silent output means PS4 judged the whole clip "not him". The speaker
            // check already handles that case, so keep the original audio.
            if ratio < -30 {
                Isolation.note(String(format: "ps4: %.1f s in %d ms, out %.0f dB vs in: kept original", Double(samples.count) / 16_000, ms, ratio))
                return nil
            }
            Isolation.note(String(format: "ps4: %.1f s in %d ms, out %.0f dB vs in", Double(samples.count) / 16_000, ms, ratio))
            return out
        } catch {
            Isolation.note("ps4: failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func armIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func unload() { extractor = nil }
}
