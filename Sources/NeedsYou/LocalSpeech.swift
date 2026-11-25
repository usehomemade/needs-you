import AVFoundation
import FluidAudio
import Foundation
import Speech
import NeedsYouShared

/// Speech in and out, all on this Mac: no audio or text leaves it.
enum SpeechIO {
    /// Speech audio for `text` (WAV): each sentence in its own language's voice
    /// (Kokoro for English, Supertonic-3 for the others, HM-1368). Falls back to
    /// macOS's own voices when a model is missing or fails.
    /// The text is cleaned for speaking first (paths, URLs, code, markdown: HM-1370);
    /// subtitles and history keep the original.
    static func speech(_ text: String) async throws -> Data {
        let r = try await VoiceMix.speech(SpeechText.spoken(text))
        if r.engines != ["en=kokoro(\(LocalTTS.voice))"] { Isolation.note("tts: voices \(r.engines.joined(separator: " "))") }
        return r.audio
    }

    /// His words, in the languages he turned on (never translated).
    static func transcribe(fileURL: URL) async throws -> String {
        try await LocalSTT.shared.transcribe(url: fileURL, language: .spoken)
    }

    /// `audio` is a 16 kHz mono 16-bit WAV from `Recorder.wav`. His words, in the
    /// languages he turned on.
    static func transcribe(audio: Data, model: String? = nil) async throws -> String {
        try await LocalSTT.shared.transcribe(samples: Recorder.samples(fromWav: audio), model: model, language: .spoken)
    }

    /// Measurement aid (off by default): keeps his recordings in a private folder
    /// so engines can be compared on his real voice. Never uploaded.
    static func keepSample(_ data: Data?, kind: String) {
        guard UserDefaults.standard.bool(forKey: "keepSamples"), let data else { return }
        let dir = Wire.supportDir.appendingPathComponent("samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = DateFormatter(); f.dateFormat = "HHmmss"
        try? data.write(to: dir.appendingPathComponent("\(f.string(from: Date()))-\(kind).wav"))
    }

    /// Loads both models in the background (before the first ask needs them).
    static func warmUp() {
        Task.detached(priority: .utility) {
            try? await LocalSTT.shared.warm()
            try? await LocalSTT.shared.warm(LocalSTT.fast)
            _ = try? await LocalTTS.shared.manager()
        }
    }
}

/// Names the local models spell their own way.
enum Names {
    private static let builtIn: [(String, String)] = [
        (#"(?i)\b(herder|hurder|herd r|herdur|herdr)\b"#, "herdr"),
    ]

    /// Extra fixes from the user's prefs (no UI): `transcriptFixes`, a list of
    /// [regular expression, replacement] pairs, e.g. [["(?i)\\bsun dial\\b", "Sundial"]].
    static let customKey = "transcriptFixes"
    static var custom: [(String, String)] {
        (UserDefaults.standard.array(forKey: customKey) as? [[String]] ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    static var fixes: [(String, String)] { UserName.fixes + builtIn + custom }

    /// Words the recognisers should expect (contextual strings, Whisper prompt).
    static var vocabulary: [String] {
        var seen = Set<String>()
        return (UserName.hints + ["herdr"] + custom.map(\.1).filter { !$0.contains("$") }).filter { seen.insert($0).inserted }
    }

    static func fix(_ text: String) -> String {
        var t = text
        for (pattern, name) in fixes {
            t = t.replacingOccurrences(of: pattern, with: name, options: .regularExpression)
        }
        return t
    }
}

/// Speech to text on the Neural Engine (NVIDIA Parakeet TDT 0.6B via FluidAudio).
/// Loaded on first use and dropped after 10 idle minutes, so an idle app stays small.
actor LocalSTT {
    static let shared = LocalSTT()

    /// The model for his words and the wake check. Whisper large-v3-turbo with a
    /// prompt ("wturbo+p"): on his clips mixed with game audio it caught "Hey Claude"
    /// 16/19 vs Parakeet's 8/19, and its words held up better (WER vs its own clean
    /// transcript 45 % vs 66 %). About 0.5 s per clip on the Neural Engine.
    static var modelName: String { UserDefaults.standard.string(forKey: "localSTTModel") ?? "wturbo+p" }
    /// Parakeet v2 (~50 ms): for frequent checks that only look for "done".
    static let fast = "v2"
    /// The model for the wake-word second opinion (Settings → Models).
    static var wakeModel: String { UserDefaults.standard.string(forKey: "wakeModel") ?? modelName }

    static func version(_ name: String) -> AsrModelVersion {
        switch name {
        case "v3": return .v3
        case "ultra": return .ultra
        case "bark3": return .bark3
        case "bark3Clean": return .bark3Clean
        case "phonon2": return .phonon2
        default: return .v2
        }
    }

    private var loaded: [String: AsrManager] = [:]
    private var idle: Task<Void, Never>?

    /// Loads the model so the first transcript does not wait for it.
    func warm(_ name: String? = nil) async throws {
        let n = name ?? Self.modelName
        if n.hasPrefix("w") { _ = try await WhisperSTT.shared.transcribe([Float](repeating: 0, count: 16_000), model: n); return }
        if n == "canary" { _ = try await CanarySTT.shared.transcribe([Float](repeating: 0, count: 16_000)); return }
        if n == "cohere" { try await loadCohere() } else { _ = try await manager(name) }
    }

    func manager(_ name: String? = nil) async throws -> AsrManager {
        var key = name ?? Self.modelName
        if key == "cohere" { key = "v2" }
        if let m = loaded[key] { return m }
        let models = try await AsrModels.downloadAndLoad(version: Self.version(key))
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        loaded[key] = m
        Isolation.note("stt: loaded parakeet \(key)")
        return m
    }

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// `language`: `.spoken` for his words (the languages he turned on), `.english`
    /// (default) for the wake check, "Stop, Claude" and enrollment lines. Only the
    /// Whisper models know other languages; the others always hear English.
    func transcribe(samples: [Float], model: String? = nil, language: STTLanguage = .english) async throws -> String {
        try await hear(samples: samples, model: model, language: language).text
    }

    func hear(samples: [Float], model: String? = nil, language: STTLanguage = .english) async throws -> Heard {
        guard samples.count > 1_600 else { return Heard(text: "", language: language.codes[0]) } // under 0.1 s
        if let w = model ?? Self.modelName as String?, w.hasPrefix("w") {
            var samples = samples
            if model != Self.fast, PS4.enabled, let only = await PS4.shared.extract(samples) { samples = only }
            let h = try await WhisperSTT.shared.hear(samples, model: w, language: language)
            if case .spoken = language { Self.lastLanguage = h.language }
            return Heard(text: Names.fix(h.text), language: h.language)
        }
        return Heard(text: try await englishOnly(samples: samples, model: model), language: "en")
    }

    /// Quick checks (end words, live subtitles) for one utterance (HM-1351, HM-1362).
    /// Parakeet v2 (~50 ms) knows only English, so it is used while the utterance is
    /// English. `detect`: find the language now (Whisper, every language with his
    /// favoured, `LanguagePick`); it is returned only when clear, else nil and no text,
    /// so nothing is shown in a guessed language. Once known, English goes back to
    /// Parakeet and any other language is read by Whisper in it.
    /// `known`: the language found earlier in this utterance.
    func quick(_ clip: [Float], known: String?, detect: Bool, speech: Double? = nil) async -> (text: String, language: String?) {
        var known = known
        if SpokenLanguages.onlyEnglish { known = "en" }
        if known == nil {
            guard detect else {
                // Unknown and not asked to find out: Parakeet, for the English end words only.
                return ((try? await transcribe(samples: clip, model: Self.fast)) ?? "", nil)
            }
            guard let d = await language(clip, speech: speech ?? Double(clip.count) / 16_000), d.confident else { return ("", nil) }
            known = d.code
        }
        let lang = known ?? "en"
        if lang == "en" {
            return ((try? await transcribe(samples: clip, model: Self.fast)) ?? "", "en")
        }
        let model = Self.modelName.hasPrefix("w") ? Self.modelName : "wturbo+p"
        guard let h = try? await hear(samples: clip, model: model, language: .forced(lang)) else { return ("", lang) }
        return (h.text, lang)
    }

    /// The language of a few seconds of his words (HM-1362); `speech`: seconds of his voice.
    /// The language he spoke last in this session (HM-1362): subtitles start in it.
    nonisolated(unsafe) static var lastLanguage: String?

    func language(_ clip: [Float], speech: Double) async -> LanguagePick.Decision? {
        let model = Self.modelName.hasPrefix("w") ? Self.modelName : "wturbo+p"
        return try? await WhisperSTT.shared.detect(clip, model: model, speech: speech)
    }

    private func englishOnly(samples: [Float], model: String?) async throws -> String {
        // Settings → Models → Voice extraction (PS4), default off: his voice is pulled out
        // of the mix first. Skipped for the quick "done" checks (model == fast).
        var samples = samples
        if model != Self.fast, PS4.enabled, let only = await PS4.shared.extract(samples) { samples = only }
        if (model ?? Self.modelName) == "canary" {
            return Names.fix(try await CanarySTT.shared.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if (model ?? Self.modelName) == "cohere" {
            let text = try await cohereTranscribe(samples)
            armIdle()
            return Names.fix(text)
        }
        // One transcription at a time: the wake check, the stop detector and the
        // command pass share one model, and overlapping calls came back empty.
        await acquire()
        defer { release() }
        let m = try await manager(model)
        var state = TdtDecoderState.make(decoderLayers: await m.decoderLayerCount)
        // Parakeet wants at least a second of audio; pad short clips with silence.
        let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
        let r = try await m.transcribe(padded, decoderState: &state)
        let text = r.text
        armIdle()
        return Names.fix(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func transcribe(url: URL, model: String? = nil, language: STTLanguage = .english) async throws -> String {
        try await hear(url: url, model: model, language: language).text
    }

    func hear(url: URL, model: String? = nil, language: STTLanguage = .english) async throws -> Heard {
        let samples = try AudioConverter().resampleAudioFile(url)
        return try await hear(samples: samples, model: model, language: language)
    }

    // Cohere Transcribe 2B (int8 encoder on the Neural Engine): slower, more robust.
    private var cohere: (pipeline: CoherePipeline, models: CoherePipeline.LoadedModels)?

    func loadCohere() async throws {
        guard cohere == nil else { return }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FluidAudio/Models")
        let dir = base.appendingPathComponent("cohere-transcribe/q8")
        let models: CoherePipeline.LoadedModels
        do {
            models = try await CoherePipeline.loadModels(encoderDir: dir, decoderDir: dir, vocabDir: dir)
        } catch {
            try await ModelHub.download(.cohereTranscribeCoreml, to: base)
            models = try await CoherePipeline.loadModels(encoderDir: dir, decoderDir: dir, vocabDir: dir)
        }
        cohere = (CoherePipeline(), models)
        Isolation.note("stt: loaded cohere transcribe")
    }

    private func cohereTranscribe(_ samples: [Float]) async throws -> String {
        try await loadCohere()
        guard let c = cohere else { return "" }
        let r = try await c.pipeline.transcribe(audio: samples, models: c.models, language: .english)
        return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        for m in loaded.values { await m.cleanup() }
        loaded = [:]
        cohere = nil
        Isolation.note("stt: unloaded after idle")
    }
}

/// Voice on this Mac (Kokoro 82M via FluidAudio), with the user's name said
/// the way they set it (`UserName.phonemes`).
actor LocalTTS {
    static let shared = LocalTTS()

    static var voice: String { UserDefaults.standard.string(forKey: "localVoice") ?? "af_heart" }
    static let voices = ["af_heart", "af_bella", "af_nicole", "af_sarah", "bf_emma", "am_michael", "am_adam", "bm_george"]

    /// Misaki phonemes (Kokoro's vocabulary). ʧ = /tʃ/.
    static var lexicon: [String: String] {
        var l = ["herdr": "hˈɜɹdəɹ"]
        if let name = UserName.value, let ph = UserName.phonemes {
            let plain = name.folding(options: .diacriticInsensitive, locale: nil)
            for n in Set([name, plain, name.lowercased(), plain.lowercased()]) {
                l[n] = ph
                l[n + "'s"] = ph + "ɪz"
            }
        }
        return l
    }

    private var mgr: KokoroAneManager?
    private var idle: Task<Void, Never>?

    func manager() async throws -> KokoroAneManager {
        if let mgr { return mgr }
        let m = KokoroAneManager(defaultVoice: Self.voice, version: .v3)
        try await m.initialize(preloadVoices: [Self.voice])
        await m.setEnglishCustomLexicon(Self.lexicon)
        _ = try? await m.synthesize(text: "Okay.", voice: Self.voice) // first synthesis compiles: do it now
        mgr = m
        Isolation.note("tts: loaded kokoro (\(Self.voice))")
        return m
    }

    /// 24 kHz mono WAV.
    func speech(_ text: String, voice: String? = nil) async throws -> Data {
        let m = try await manager()
        let data = try await m.synthesize(text: Self.prepare(text), voice: voice ?? Self.voice)
        armIdle()
        return data
    }

    func phonemes(_ text: String) async throws -> String {
        try await manager().englishPhonemes(for: Self.prepare(text))
    }

    /// Hook for text fixes before synthesis.
    static func prepare(_ text: String) -> String {
        text
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
        Isolation.note("tts: unloaded after idle")
    }
}

/// Apple's on-device recognizer over a whole file (for comparison runs).
@available(macOS 26, *)
enum AppleSTT {
    static func transcribe(url: URL) async throws -> String {
        let t = try await AnalyzerSession.makeTranscriber()
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [t])
        let collect = Task { () -> String in
            var out = ""
            for try await r in t.results where r.isFinal { out += String(r.text.characters) }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return Names.fix(try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension Recorder {
    /// Samples back out of a `Recorder.wav` (16-bit mono PCM, 44-byte header).
    static func samples(fromWav data: Data) -> [Float] {
        guard data.count > 44 else { return [] }
        return data.subdata(in: 44..<data.count).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
    }
}

/// Fast "Stop, Claude": re-reads the last 2 s of the (echo-cancelled) mic with
/// Parakeet every 250 ms while someone is talking. About 30 ms per pass on the
/// Neural Engine, so the stop lands a few hundred ms after the phrase.
final class FastStopDetector {
    private let lock = NSLock()
    private var ring: [Float] = []
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private var loop: Task<Void, Never>?
    private let matches: (String) -> Bool
    private let onStop: (String) -> Void
    private static let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let window = 32_000 // 2 s

    init(matches: @escaping (String) -> Bool, onStop: @escaping (String) -> Void) {
        self.matches = matches
        self.onStop = onStop
    }

    /// From the tap (any format, first channel used).
    func append(_ buf: AVAudioPCMBuffer) {
        guard buf.frameLength > 0 else { return }
        var input = buf
        if buf.format.channelCount > 1 {
            guard let mono = AVAudioFormat(standardFormatWithSampleRate: buf.format.sampleRate, channels: 1),
                  let one = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength),
                  let src = buf.floatChannelData?[0], let dst = one.floatChannelData?[0] else { return }
            one.frameLength = buf.frameLength
            memcpy(dst, src, Int(buf.frameLength) * 4)
            input = one
        }
        if source != input.format { converter = AVAudioConverter(from: input.format, to: Self.out); source = input.format }
        guard let conv = converter,
              let o = AVAudioPCMBuffer(pcmFormat: Self.out, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 64)
        else { return }
        var fed = false
        conv.convert(to: o, error: nil) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true; s.pointee = .haveData; return input
        }
        let chunk = UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength))
        lock.lock()
        ring.append(contentsOf: chunk)
        if ring.count > window { ring.removeFirst(ring.count - window) }
        lock.unlock()
    }

    func start() {
        loop = Task.detached(priority: .userInitiated) { [weak self] in
            var lastText = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                let snap = self.lock.withLock { self.ring }
                // Only when the last half second has speech-level energy.
                let tail = snap.suffix(8_000)
                guard tail.count == 8_000 else { continue }
                let rms = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
                guard 20 * log10(max(rms, 1e-7)) > -50 else { continue }
                guard let text = try? await LocalSTT.shared.transcribe(samples: Array(snap)), text != lastText else { continue }
                lastText = text
                if WakeListener.debug { Isolation.note("voice: fast detector heard: \(text)") }
                if self.matches(text) { self.onStop(text); return }
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }
}

/// Offline timing of both stop detectors on a file played in real time.
enum StopBench {
    static func run(_ url: URL) async -> String {
        guard let file = try? AVAudioFile(forReading: url) else { return "cannot read file" }
        if #available(macOS 26, *), WakeListener.analyzerFormatCache == nil { try? await WakeListener().prepare() }
        try? await LocalSTT.shared.warm()
        let t0 = Date()
        let lock = NSLock()
        var apple: Double?, fastAt: Double?
        func ms() -> Double { Date().timeIntervalSince(t0) * 1000 }
        let match: (String) -> Bool = { VoicePlayer.isStop($0) || $0.range(of: VoicePlayer.bareStopPattern, options: .regularExpression) != nil }
        var session: AnyObject?
        if #available(macOS 26, *), let f = WakeListener.analyzerFormatCache {
            session = AnalyzerSession(format: f, fast: true, log: { _ in }) { heard in
                if match(heard) { lock.withLock { if apple == nil { apple = ms() } } }
            }
        }
        let fast = FastStopDetector(matches: match) { _ in lock.withLock { if fastAt == nil { fastAt = ms() } } }
        fast.start()
        let chunk: AVAudioFrameCount = 4096
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                  (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 else { break }
            if #available(macOS 26, *) { (session as? AnalyzerSession)?.append(buf) }
            fast.append(buf)
            try? await Task.sleep(nanoseconds: UInt64(Double(buf.frameLength) / file.processingFormat.sampleRate * 1e9))
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        fast.stop()
        if #available(macOS 26, *) { (session as? AnalyzerSession)?.cancel() }
        return lock.withLock { "apple=\(apple.map { String(format: "%.0f", $0) } ?? "none") parakeet=\(fastAt.map { String(format: "%.0f", $0) } ?? "none")" }
    }
}

/// macOS's built-in voices, only if the local models cannot speak: Yelda for
/// Turkish, Anna for German, and so on (`VoiceRouting.systemVoices`).
enum SystemVoice {
    static func speech(_ text: String) async throws -> Data {
        try await speech(text, language: "en").audio
    }

    /// WAV and the name of the voice that spoke.
    static func speech(_ text: String, language: String) async throws -> (audio: Data, voice: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("needs-you-say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let voice = language == "en" ? nil : voiceName(language)
        let spoken = language == "en" ? (UserName.sayAs.flatMap { s in UserName.value.map { text.replacingOccurrences(of: $0, with: s) } } ?? text) : VoiceRouting.spoken(text, language: language, systemVoice: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", url.path, "--data-format=LEI16@22050", spoken]
        try p.run()
        p.waitUntilExit()
        return (try Data(contentsOf: url), voice ?? "default")
    }

    /// "Yelda" for tr: the preferred name when installed, else any voice for that language.
    static func voiceName(_ language: String) -> String? {
        let installed = installedVoices
        for name in VoiceRouting.systemVoices[language] ?? [] where installed.contains(where: { $0.name == name }) { return name }
        return installed.first { $0.locale.hasPrefix(language + "_") }?.name
    }

    private static let lock = NSLock()
    private static var cached: [(name: String, locale: String)]?
    /// From `say -v ?`: "Yelda (Turkish (Türkiye))   tr_TR    # Merhaba…" -> ("Yelda", "tr_TR").
    static var installedVoices: [(name: String, locale: String)] {
        if let c = lock.withLock({ cached }) { return c }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "?"]
        p.standardOutput = pipe
        try? p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let list = parseVoices(out)
        lock.withLock { cached = list }
        return list
    }

    static func parseVoices(_ out: String) -> [(name: String, locale: String)] {
        out.split(separator: "\n").compactMap { line in
            guard let m = line.range(of: #"\s+([a-z]{2,3}_[A-Z0-9]{2,3})\s+#"#, options: .regularExpression) else { return nil }
            var name = String(line[..<m.lowerBound]).trimmingCharacters(in: .whitespaces)
            // "Anna (German (Germany))" is "Anna" to `say -v`.
            if let paren = name.range(of: " (") { name = String(name[..<paren.lowerBound]) }
            let locale = line[m].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#")))
            return (name, locale)
        }
    }
}
