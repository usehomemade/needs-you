import AVFoundation
import CoreML
import FluidAudio
import Foundation
import NeedsYouShared

/// Native voices for the languages besides English (HM-1368): Supertonic-3, a
/// 31-language CoreML model in FluidAudio, about 160 MB downloaded once on first
/// use and shared by every language, plus a small style file per speaker.
/// Measured 25 Nov on the M5 Pro: 0.07 s for a short line, 0.12 s for two
/// sentences, load 0.07 s. Kokoro stays the English voice.
@MainActor
final class NativeVoices: ObservableObject {
    static let shared = NativeVoices()

    @Published private(set) var downloading: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?
    /// Bumped whenever files on disk change, so views re-read the state.
    @Published private(set) var revision = 0

    /// Where the model lives: FluidAudio's shared cache (next to Kokoro), or
    /// `NEEDS_YOU_VOICES_DIR` for tests.
    nonisolated static var modelsRoot: URL {
        if let d = ProcessInfo.processInfo.environment["NEEDS_YOU_VOICES_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true)
    }
    nonisolated static var repoDir: URL { modelsRoot.appendingPathComponent("supertonic-3", isDirectory: true) }
    /// The ANE-resident int4 build FluidAudio picks by default.
    nonisolated static let variant = "ane-int4"
    /// Download size of the model (FluidInference/supertonic-3-coreml, ane-int4), measured 25 Nov.
    nonisolated static let downloadMB = 162

    nonisolated static var modelOnDisk: Bool {
        ModelNames.Supertonic3.requiredFiles(veVariant: variant).allSatisfy {
            FileManager.default.fileExists(atPath: repoDir.appendingPathComponent($0).path)
        }
    }
    nonisolated static func voiceOnDisk(_ v: String) -> Bool {
        FileManager.default.fileExists(atPath: repoDir.appendingPathComponent("voice_styles/\(v).json").path)
    }

    nonisolated static var enabled: [String] { VoiceRouting.parse(UserDefaults.standard.string(forKey: VoiceRouting.languagesKey)) }
    nonisolated static var removed: [String] { VoiceRouting.parse(UserDefaults.standard.string(forKey: VoiceRouting.removedKey)) }
    nonisolated static func voice(for code: String) -> String {
        let v = UserDefaults.standard.string(forKey: VoiceRouting.voiceKey(code)) ?? VoiceRouting.defaultVoice
        return VoiceRouting.voices.contains(v) ? v : VoiceRouting.defaultVoice
    }
    /// The native voice can speak `code` now (downloaded, not deleted).
    nonisolated static func ready(_ code: String) -> Bool {
        enabled.contains(code) && modelOnDisk && voiceOnDisk(voice(for: code))
    }

    /// Bytes on disk for the model and its voices.
    var diskBytes: Int64 {
        _ = revision
        guard let e = FileManager.default.enumerator(at: Self.repoDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var n: Int64 = 0
        for case let u as URL in e { n += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return n
    }

    /// First use: a sentence in `code` came up and its voice is not here. Starts
    /// the download in the background (macOS speaks this time), unless he deleted
    /// that language in Settings.
    nonisolated static func firstUse(_ code: String) {
        guard !removed.contains(code), !Prefs.readOnly else { return }
        Task { @MainActor in
            guard shared.downloading == nil, !ready(code) else { return }
            Isolation.note("tts: no native \(code) voice yet; downloading it (macOS voice meanwhile)")
            await shared.download(code)
        }
    }

    /// Downloads the model (once) and the speaker for `code`, then turns the language on.
    func download(_ code: String) async {
        guard downloading == nil, !Prefs.readOnly else { return }
        downloading = code
        progress = 0
        lastError = nil
        defer { downloading = nil; revision += 1 }
        do {
            try FileManager.default.createDirectory(at: Self.modelsRoot, withIntermediateDirectories: true)
            if !Self.modelOnDisk {
                try await Supertonic3ResourceDownloader.ensureModels(directory: Self.modelsRoot, veVariant: Self.variant) { p in
                    Task { @MainActor in NativeVoices.shared.progress = p.fractionCompleted * 0.98 }
                }
            }
            try await Self.ensureVoice(Self.voice(for: code))
            progress = 1
            setList(VoiceRouting.languagesKey, adding: code)
            setList(VoiceRouting.removedKey, removing: code)
            Isolation.note("tts: native \(code) voice ready (\(Self.voice(for: code)))")
        } catch {
            lastError = error.localizedDescription
            Isolation.note("tts: native voice download failed (\(error.localizedDescription))")
        }
    }

    /// Deletes `code`: macOS speaks it from now on, and it is not downloaded again
    /// on its own. With no language left, the model itself is removed.
    func delete(_ code: String) async {
        guard !Prefs.readOnly else { return }
        setList(VoiceRouting.languagesKey, removing: code)
        setList(VoiceRouting.removedKey, adding: code)
        if Self.enabled.isEmpty {
            await NativeTTS.shared.unload()
            try? FileManager.default.removeItem(at: Self.repoDir)
        }
        revision += 1
    }

    /// Picking another speaker fetches its style file (about 300 KB).
    func choose(_ voice: String, for code: String) async {
        guard !Prefs.readOnly else { return }
        UserDefaults.standard.set(voice, forKey: VoiceRouting.voiceKey(code))
        guard Self.modelOnDisk, !Self.voiceOnDisk(voice) else { revision += 1; return }
        do { try await Self.ensureVoice(voice) } catch { lastError = error.localizedDescription }
        revision += 1
    }

    nonisolated static func ensureVoice(_ v: String) async throws {
        guard let voice = Supertonic3Voice(name: v) else { return }
        try await Supertonic3ResourceDownloader.downloadVoiceStyle(voice, directory: modelsRoot)
    }

    private func setList(_ key: String, adding: String? = nil, removing: String? = nil) {
        guard !Prefs.readOnly else { return }
        var codes = VoiceRouting.parse(UserDefaults.standard.string(forKey: key))
        if let a = adding, !codes.contains(a) { codes.append(a) }
        if let r = removing { codes.removeAll { $0 == r } }
        UserDefaults.standard.set(VoiceRouting.store(codes), forKey: key)
    }
}

/// Supertonic-3 on the Neural Engine. Loaded on first use, dropped after 10 idle minutes.
actor NativeTTS {
    static let shared = NativeTTS()

    private var mgr: Supertonic3Manager?
    private var styles: [String: Supertonic3VoiceStyle] = [:]
    private var idle: Task<Void, Never>?

    /// 44.1 kHz mono. Never downloads: call only when `NativeVoices.ready`.
    func speech(_ text: String, language: String, voice: String) async throws -> WAV.Audio {
        guard NativeVoices.modelOnDisk, NativeVoices.voiceOnDisk(voice) else {
            throw NSError(domain: "NeedsYou", code: 20, userInfo: [NSLocalizedDescriptionKey: "native voice not downloaded"])
        }
        let m: Supertonic3Manager
        if let mgr { m = mgr } else {
            let t0 = Date()
            m = Supertonic3Manager(directory: NativeVoices.modelsRoot)
            try await m.initialize()
            mgr = m
            Isolation.note(String(format: "tts: loaded supertonic-3 in %.0f ms", Date().timeIntervalSince(t0) * 1000))
        }
        let style: Supertonic3VoiceStyle
        if let s = styles[voice] { style = s } else {
            style = try Supertonic3VoiceStyle.load(from: NativeVoices.repoDir.appendingPathComponent("voice_styles/\(voice).json"))
            styles[voice] = style
        }
        let out = try await m.synthesize(text: VoiceRouting.spoken(text, language: language), language: language, style: style)
        armIdle()
        return WAV.Audio(samples: out.samples, sampleRate: Supertonic3Constants.sampleRate)
    }

    private func armIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    func unload() async {
        await mgr?.cleanup()
        mgr = nil
        styles = [:]
    }
}

/// Speech for a whole reply: each sentence in its language's voice (HM-1368).
enum VoiceMix {
    struct Result {
        var audio: Data
        /// "en=kokoro(af_heart)", or per part with its length when the voice
        /// changes: "tr=supertonic3(F2) 2.41s", "de=macos(Anna) 3.10s".
        var engines: [String]
    }

    /// `englishVoice` overrides the Kokoro voice; `nativeOff` speaks other
    /// languages with macOS voices (test hook: `tts-test --title fallback`).
    static func speech(_ text: String, englishVoice: String? = nil, nativeOff: Bool = false) async throws -> Result {
        var segments = VoiceRouting.segments(text)
        if segments.isEmpty { segments = [VoiceRouting.Segment("en", text)] }
        if segments.count == 1, segments[0].language == "en" {
            // English only: Kokoro exactly as before.
            return try await english(text, voice: englishVoice)
        }
        var parts: [WAV.Audio] = []
        var engines: [String] = []
        for seg in segments {
            if seg.language == "en" {
                let r = try await english(seg.text, voice: englishVoice)
                guard let a = WAV.decode(r.audio) else { continue }
                parts.append(a); engines += r.engines
                continue
            }
            if !nativeOff, NativeVoices.ready(seg.language) {
                let v = NativeVoices.voice(for: seg.language)
                do {
                    parts.append(try await NativeTTS.shared.speech(seg.text, language: seg.language, voice: v))
                    engines.append("\(seg.language)=supertonic3(\(v))")
                    continue
                } catch {
                    Isolation.note("tts: native \(seg.language) voice failed (\(error.localizedDescription)); macOS voice")
                }
            } else if !nativeOff {
                NativeVoices.firstUse(seg.language)
            }
            let (data, name) = try await SystemVoice.speech(seg.text, language: seg.language)
            guard let a = WAV.decode(data) else { continue }
            parts.append(a); engines.append("\(seg.language)=macos(\(name))")
        }
        // "tr=supertonic3(F2) 2.41s": how long each part runs in the joined audio.
        if parts.count == engines.count {
            engines = zip(engines, parts).map { String(format: "%@ %.2fs", $0, $1.duration) }
        }
        if parts.count == 1 { return Result(audio: WAV.encode(parts[0]), engines: engines) }
        // Join at the highest rate (upsampling only), with a short breath between voices.
        let rate = parts.map(\.sampleRate).max() ?? 24_000
        return Result(audio: WAV.encode(WAV.join(parts, rate: rate, gap: 0.15)), engines: engines)
    }

    private static func english(_ text: String, voice: String?) async throws -> Result {
        let v = voice ?? LocalTTS.voice
        do {
            return Result(audio: try await LocalTTS.shared.speech(text, voice: v), engines: ["en=kokoro(\(v))"])
        } catch {
            Isolation.note("tts: local voice failed (\(error.localizedDescription)); macOS voice")
            let (data, name) = try await SystemVoice.speech(text, language: "en")
            return Result(audio: data, engines: ["en=macos(\(name))"])
        }
    }
}
