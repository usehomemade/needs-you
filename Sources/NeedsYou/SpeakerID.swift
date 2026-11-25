import FluidAudio
import Foundation
import NeedsYouShared

/// The user's voice: CAM++ speaker embeddings (FluidAudio, 192-d, on the Mac).
/// A voiceprint (mean embedding of his enrollment clips) lets the app act only
/// on his voice, so game voices, a TV or other people are ignored.
actor SpeakerID {
    static let shared = SpeakerID()
    // 3 s windows: on his clips mixed with game audio, 1.5 s windows overlapped
    // (his 0.45-0.65, game up to 0.55); 3 s windows separate them (his clips
    // median 0.53-0.75 even with the game at the same level, game alone <= 0.46).
    static let window = 48_000   // 3 s
    static let hop = 16_000      // 1 s
    /// Cosine similarity at or above which a window counts as his voice.
    static var threshold: Float {
        let v = UserDefaults.standard.double(forKey: "voiceThreshold")
        return v > 0 ? Float(v) : 0.45
    }
    /// Below this a window is someone else (game, TV): used to drop audio and to
    /// end his turn, so it sits lower than `threshold` to never cut his words.
    static var otherBelow: Float { threshold - 0.07 }
    static var printURL: URL { Wire.supportDir.appendingPathComponent("voiceprint.json") }

    private var embedder: CampPlusEmbedder?
    private var print_: [Float]?
    private var loadedPrint = false
    private var idle: Task<Void, Never>?

    func load() async throws -> CampPlusEmbedder {
        if let embedder { return embedder }
        let e = try await CampPlusEmbedder.load()
        embedder = e
        return e
    }

    /// The saved voiceprint, or nil when he has not enrolled.
    func voiceprint() -> [Float]? {
        if !loadedPrint {
            loadedPrint = true
            if let d = try? Data(contentsOf: Self.printURL),
               let v = try? JSONDecoder().decode([Float].self, from: d), v.count == CampPlusEmbedder.embeddingDim { print_ = v }
        }
        return print_
    }

    var enrolled: Bool { voiceprint() != nil }
    /// Enrolled and switched on (Settings → Models → Speaker check).
    nonisolated static var isEnrolled: Bool {
        UserDefaults.standard.string(forKey: "speakerModel") != "off" && FileManager.default.fileExists(atPath: printURL.path)
    }

    func embed(_ samples: [Float]) async throws -> [Float] {
        let e = try await load()
        let v = try await e.embed(audio: samples)
        armIdle()
        return v
    }

    /// Saves the mean of the clips' embeddings (each clip trimmed of silence by the caller).
    func enroll(_ clips: [[Float]]) async throws -> [Float] {
        PS4.saveEnrollment(clips)
        var sum = [Float](repeating: 0, count: CampPlusEmbedder.embeddingDim)
        var n = 0
        for c in clips where c.count >= 16_000 {
            // Windows, so long and short clips weigh the same per second of voice.
            for w in Self.windows(c) {
                let v = try await embed(w)
                for i in 0..<v.count { sum[i] += v[i] }
                n += 1
            }
        }
        guard n > 0 else { throw NSError(domain: "NeedsYou", code: 8, userInfo: [NSLocalizedDescriptionKey: "Not enough speech to learn the voice"]) }
        let norm = max(sqrt(sum.reduce(0) { $0 + $1 * $1 }), 1e-9)
        let v = sum.map { $0 / norm }
        try FileManager.default.createDirectory(at: Wire.supportDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(v).write(to: Self.printURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.printURL.path)
        print_ = v; loadedPrint = true
        return v
    }

    /// Saves a voiceprint computed elsewhere (Training), keeping the previous one.
    func save(_ v: [Float]) throws {
        let fm = FileManager.default
        let prev = Wire.supportDir.appendingPathComponent("voiceprint-previous.json")
        if fm.fileExists(atPath: Self.printURL.path) { try? fm.removeItem(at: prev); try? fm.copyItem(at: Self.printURL, to: prev) }
        try JSONEncoder().encode(v).write(to: Self.printURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.printURL.path)
        print_ = v; loadedPrint = true
    }

    /// Undo the last Training run: puts back the voiceprint and threshold it replaced.
    func restorePrevious() -> Bool {
        let fm = FileManager.default
        let prev = Wire.supportDir.appendingPathComponent("voiceprint-previous.json")
        guard let d = try? Data(contentsOf: prev), let v = try? JSONDecoder().decode([Float].self, from: d) else { return false }
        try? d.write(to: Self.printURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.printURL.path)
        try? fm.removeItem(at: prev)
        let ud = UserDefaults.standard
        if let t = ud.object(forKey: "voiceThresholdPrevious") as? Double { t < 0 ? ud.removeObject(forKey: "voiceThreshold") : ud.set(t, forKey: "voiceThreshold") }
        ud.removeObject(forKey: "voiceThresholdPrevious")
        print_ = v; loadedPrint = true
        return true
    }

    nonisolated static var canRestore: Bool {
        FileManager.default.fileExists(atPath: Wire.supportDir.appendingPathComponent("voiceprint-previous.json").path)
    }

    func forget() {
        try? FileManager.default.removeItem(at: Self.printURL)
        print_ = nil; loadedPrint = true
    }

    /// Similarity of each 3 s window (1 s hop) to his voiceprint; nil when not enrolled.
    func scores(_ samples: [Float]) async throws -> [Float]? {
        guard let p = voiceprint() else { return nil }
        var out: [Float] = []
        for w in Self.windows(samples) {
            let v = try await embed(w)
            out.append(zip(v, p).reduce(0) { $0 + $1.0 * $1.1 })
        }
        return out
    }

    /// Best window similarity: does he speak anywhere in this audio?
    func best(_ samples: [Float]) async throws -> Float? {
        try await scores(samples)?.max()
    }

    /// Only the parts where he speaks: windows below the threshold are silenced
    /// (game voices, TV, other people); 3 s windows, so this only drops stretches
    /// where he does not speak at all.
    func onlyHim(_ samples: [Float]) async throws -> [Float]? {
        guard let s = try await scores(samples), !s.isEmpty else { return nil }
        var keep = [Bool](repeating: false, count: samples.count)
        let starts = Self.windowStarts(samples.count)
        for (k, v) in s.enumerated() where v >= Self.otherBelow && k < starts.count {
            let a = starts[k], b = min(samples.count, a + Self.window)
            for i in a..<b { keep[i] = true }
        }
        return zip(samples, keep).map { $1 ? $0 : 0 }
    }

    static func windowStarts(_ count: Int) -> [Int] {
        if count <= window { return [0] }
        var out: [Int] = []
        var i = 0
        while i + window <= count { out.append(i); i += hop }
        if i < count, count - i > hop / 2 { out.append(count - window) }
        return out
    }

    static func windows(_ samples: [Float]) -> [[Float]] {
        windowStarts(samples.count).map { Array(samples[$0..<min(samples.count, $0 + window)]) }
    }

    private func armIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func unload() { embedder = nil }
}
