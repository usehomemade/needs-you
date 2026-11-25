import CoreML
import Foundation
import NeedsYouShared
import WhisperKit

/// Which language a transcription is in (HM-1351).
enum STTLanguage: Sendable, Equatable {
    /// English, always: the wake check, "Stop, Claude", voice enrollment lines.
    case english
    /// His words: the languages he turned on (Settings → Voice → Languages I Speak).
    /// One: forced to it (English only = as before). Several: Whisper picks the
    /// most likely of them for this utterance, then transcribes in it.
    case spoken
    /// This language (an utterance whose language is already known).
    case forced(String)

    /// Test hooks only (stt-test / train-eval "<model>@en,tr"): his languages for this task,
    /// without touching his setting.
    @TaskLocal static var spokenOverride: [String]?
    /// Test hooks only ("<model>@en,tr!"): "Only these languages" for this task.
    @TaskLocal static var strictOverride: Bool?
    static var strict: Bool { strictOverride ?? SpokenLanguages.strict }

    /// "wturbo+p@en/tr" -> ("wturbo+p", ["en", "tr"]); no "@" -> (id, nil). "/" because
    /// train-eval already splits its model list on commas ("@en,tr" works in stt-test).
    static func split(_ id: String) -> (model: String, languages: [String]?) {
        guard let at = id.firstIndex(of: "@") else { return (id, nil) }
        let codes = id[id.index(after: at)...].replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "!", with: "")
        return (String(id[..<at]), SpokenLanguages.parse(codes))
    }
    /// "wturbo+p@en/tr!" -> strict (only these languages); no "!" -> nil (his setting).
    static func strictFlag(_ id: String) -> Bool? { id.contains("@") ? id.hasSuffix("!") : nil }

    var codes: [String] {
        switch self {
        case .english: return ["en"]
        case .spoken: return Self.spokenOverride ?? SpokenLanguages.enabled
        case .forced(let code): return [code]
        }
    }
}

/// A transcript and the language it was heard in.
struct Heard: Sendable {
    var text: String
    var language: String
}

/// Whisper large-v3-turbo through WhisperKit (Core ML, Neural Engine), for audio
/// where Parakeet struggles: his voice over a game or TV.
actor WhisperSTT {
    static let shared = WhisperSTT()
    /// Short names used by settings and test hooks -> WhisperKit model folders.
    static func folder(_ name: String) -> String {
        switch name {
        case "wturbo632": return "openai_whisper-large-v3-v20240930_turbo_632MB"
        case "wlarge": return "openai_whisper-large-v3-v20240930"
        case "wdistil": return "distil-whisper_distil-large-v3"
        case "wsmall": return "openai_whisper-small.en"
        default: return "openai_whisper-large-v3-v20240930_turbo"
        }
    }
    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WhisperKit")
    }
    /// Names and words it should expect (Whisper's prompt).
    static var prompt: String { "\(Wake.phrase), this one: " + Names.vocabulary.joined(separator: ", ") + "." }

    private var kit: WhisperKit?
    private var loadedName: String?

    func load(_ name: String) async throws -> WhisperKit {
        if let kit, loadedName == name { return kit }
        kit = nil
        let config = WhisperKitConfig(model: Self.folder(name), downloadBase: Self.downloadBase,
                                      verbose: false, logLevel: .error, prewarm: true, load: true, download: true)
        let k = try await WhisperKit(config)
        kit = k; loadedName = name
        return k
    }

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func lock() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    private func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// One decode at a time (the wake check and the command share the model).
    func transcribe(_ samples: [Float], model name: String, language: STTLanguage = .english) async throws -> String {
        try await hear(samples, model: name, language: language).text
    }

    func hear(_ samples: [Float], model name: String, language: STTLanguage) async throws -> Heard {
        await lock()
        defer { unlock() }
        let usePrompt = name.hasSuffix("+p")
        let base = usePrompt ? String(name.dropLast(2)) : name
        let k = try await load(base)
        let codes = language.codes
        var opts = options(k, usePrompt: usePrompt, language: codes[0])
        // Forced (English for the wake check, a language already found), or his one
        // language with "Only these languages" on: no detection (the old path).
        if case .spoken = language, !(STTLanguage.strict && codes.count == 1) {} else {
            return Heard(text: try await whole(k, samples, opts), language: codes[0])
        }
        // Detection: one encoder pass gives both the language (the first decoder step:
        // every language, his favoured, LanguagePick) and the transcript (decoded from
        // the same encoder output). WhisperKit's own detection inside transcribe() picked
        // English for clear Turkish speech (24 Nov), so it is not used.
        guard samples.count <= 480_000, let enc = try await encode(k, samples) else {
            // Longer than one 30 s window: detect on the first 30 s, then the usual path.
            let lang = try await pick(k, encoded: try await encode(k, Array(samples.prefix(480_000))), among: codes, speech: 30).code
            opts.language = lang
            return Heard(text: try await whole(k, samples, opts), language: lang)
        }
        // A whole utterance: its language is the best guess even when not clear-cut.
        let lang = try await pick(k, encoded: enc, among: codes, speech: Double(samples.count) / 16_000).code
        opts.language = lang
        return Heard(text: try await decode(k, enc, opts), language: lang)
    }

    /// HM-1362: which language is this (a few seconds of his words, for subtitles)?
    /// `speech`: seconds of his voice in the clip. Nil when Whisper could not run.
    func detect(_ samples: [Float], model name: String, speech: Double) async throws -> LanguagePick.Decision? {
        await lock()
        defer { unlock() }
        let k = try await load(name.hasSuffix("+p") ? String(name.dropLast(2)) : name)
        guard let enc = try await encode(k, Array(samples.suffix(480_000))) else { return nil }
        return try await pick(k, encoded: enc, among: STTLanguage.spoken.codes, speech: speech)
    }

    private func options(_ k: WhisperKit, usePrompt: Bool, language: String) -> DecodingOptions {
        var opts = DecodingOptions(verbose: false, task: .transcribe, language: language, temperature: 0,
                                   temperatureFallbackCount: 1, usePrefillPrompt: true, detectLanguage: false,
                                   skipSpecialTokens: true, withoutTimestamps: true)
        if usePrompt, let tok = k.tokenizer {
            opts.promptTokens = tok.encode(text: " " + Self.prompt).filter { $0 < tok.specialTokens.specialTokenBegin }
        }
        return opts
    }

    /// WhisperKit's full path (chunking, fallback, segments).
    private func whole(_ k: WhisperKit, _ samples: [Float], _ options: DecodingOptions) async throws -> String {
        var opts = options
        // Whisper hears 30 s at a time: longer audio is chunked by voice activity.
        if samples.count > 480_000 { opts.chunkingStrategy = .vad }
        let r = try await k.transcribe(audioArray: samples, decodeOptions: opts)
        return r.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Language detection among his languages

    /// The encoder output for one 30 s window (padded).
    private func encode(_ k: WhisperKit, _ samples: [Float]) async throws -> MLMultiArray? {
        guard let audio = AudioProcessor.padOrTrimAudio(fromArray: samples, startAt: 0, toLength: k.featureExtractor.windowSamples ?? 480_000),
              let mel = try await k.featureExtractor.logMelSpectrogram(fromAudio: audio) else { return nil }
        return try await k.audioEncoder.encodeFeatures(mel) as? MLMultiArray
    }

    /// Probability of each language in `codes` (softmax over just those language tokens,
    /// one decoder step after SOT).
    private func probabilities(_ k: WhisperKit, encoded enc: MLMultiArray, among codes: [String]) async throws -> [String: Float] {
        guard let tok = k.tokenizer,
              let inputs = try k.textDecoder.prepareDecoderInputs(withPrompt: [tok.specialTokens.startOfTranscriptToken]) as? DecodingInputs
        else { return [:] }
        inputs.inputIds[0] = NSNumber(value: tok.specialTokens.startOfTranscriptToken)
        inputs.cacheLength[0] = 0
        let out = try await k.textDecoder.predictLogits(TextDecoderMLMultiArrayInputType(
            inputIds: inputs.inputIds, cacheLength: inputs.cacheLength, keyCache: inputs.keyCache, valueCache: inputs.valueCache,
            kvCacheUpdateMask: inputs.kvCacheUpdateMask, encoderOutputEmbeds: enc, decoderKeyPaddingMask: inputs.decoderKeyPaddingMask
        )) as? TextDecoderMLMultiArrayOutputType
        guard let logits = out?.logits else { return [:] }
        var raw: [String: Float] = [:]
        for c in codes {
            if let id = tok.convertTokenToId("<|\(c)|>") { raw[c] = logits[[0, 0, NSNumber(value: id)]].floatValue }
        }
        let m = raw.values.max() ?? 0
        let z = raw.values.reduce(0) { $0 + exp($1 - m) }
        return raw.mapValues { exp($0 - m) / z }
    }

    /// The language of this window: every Whisper language scored, his own favoured
    /// (only his with "Only these languages"). English when nothing could be scored.
    private func pick(_ k: WhisperKit, encoded enc: MLMultiArray?, among codes: [String], speech: Double) async throws -> LanguagePick.Decision {
        guard let enc else { return LanguagePick.Decision(code: codes[0], confident: false, top: 0, margin: 0) }
        let strict = STTLanguage.strict
        let p = try await probabilities(k, encoded: enc, among: strict ? codes : Array(Constants.languages.values))
        return LanguagePick.decide(p, picked: codes, strict: strict, speech: speech)
    }

    /// Decodes one window from an encoder output (as WhisperKit does for a single
    /// window without timestamps), with one fallback at a higher temperature.
    private func decode(_ k: WhisperKit, _ enc: MLMultiArray, _ options: DecodingOptions) async throws -> String {
        guard let tok = k.tokenizer else { return "" }
        var result: DecodingResult?
        for i in 0...options.temperatureFallbackCount {
            var opts = options
            opts.temperature = options.temperature + Float(i) * options.temperatureIncrementOnFallback
            let inputs = try await k.textDecoder.prefillDecoderInputs(
                try k.textDecoder.prepareDecoderInputs(withPrompt: [tok.specialTokens.startOfTranscriptToken]), withOptions: opts)
            let sampler = GreedyTokenSampler(temperature: FloatType(opts.temperature), eotToken: tok.specialTokens.endToken, decodingOptions: opts)
            result = try await k.textDecoder.decodeText(from: enc, using: inputs, sampler: sampler, options: opts, callback: nil)
            if result?.fallback?.needsFallback != true { break }
        }
        let words = (result?.tokens ?? []).filter { $0 < tok.specialTokens.specialTokenBegin }
        return tok.decode(tokens: words).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Test hook (stt-test --title langid:<model>[@codes]): probabilities of `codes`
    /// (all of Whisper's languages when nil) for the first 30 s.
    func languageProbabilities(_ samples: [Float], model name: String, among codes: [String]? = nil) async throws -> [String: Float] {
        await lock()
        defer { unlock() }
        let k = try await load(name.hasSuffix("+p") ? String(name.dropLast(2)) : name)
        guard let enc = try await encode(k, Array(samples.prefix(480_000))) else { return [:] }
        return try await probabilities(k, encoded: enc, among: codes ?? Array(Constants.languages.values))
    }

    // Stays loaded: the wake check needs it within a second of any speech, and a
    // reload takes several seconds (about 1.6 GB, well inside the budget).
}

