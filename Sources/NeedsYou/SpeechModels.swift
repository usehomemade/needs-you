import FluidAudio
import Foundation

/// The speech models he can switch between (Settings → Models). Choosing one
/// downloads it on first use; nothing is downloaded until then.
struct SpeechModel: Identifiable, Hashable {
    var id: String
    var name: String
    var size: String
    var ram: String
    var speed: String
    var note: String = ""
}

enum SpeechModels {
    static let stt: [SpeechModel] = [
        SpeechModel(id: "wturbo+p", name: "Whisper large-v3-turbo", size: "1.6 GB", ram: "~0.3 GB (Neural Engine)", speed: "~0.5 s per clip",
                    note: "Current default. Best on his game-mix clips (wake 18/19)."),
        SpeechModel(id: "wlarge+p", name: "Whisper large-v3 (full)", size: "3.1 GB", ram: "~0.5 GB (Neural Engine)", speed: "~1.5 s per clip",
                    note: "Largest Whisper: slower, maybe a bit more accurate."),
        SpeechModel(id: "wdistil+p", name: "Whisper distil-large-v3", size: "1.5 GB", ram: "~0.3 GB (Neural Engine)", speed: "~0.4 s per clip",
                    note: "Distilled English Whisper."),
        SpeechModel(id: "canary", name: "NVIDIA Canary 1B v2", size: "~1 GB (int4)", ram: "~1 GB", speed: "~0.3 s per clip",
                    note: "Strong on noisy English benchmarks."),
        SpeechModel(id: "v3", name: "Parakeet TDT 0.6B v3", size: "0.6 GB", ram: "~0.8 GB", speed: "~50 ms per clip"),
        SpeechModel(id: "v2", name: "Parakeet TDT 0.6B v2", size: "0.6 GB", ram: "~0.8 GB", speed: "~50 ms per clip",
                    note: "Fastest; weak over game audio (wake 10/19)."),
        SpeechModel(id: "cohere", name: "Cohere Transcribe 2B", size: "2.2 GB", ram: "~2.5 GB", speed: "~1-3 s per clip",
                    note: "Large; slow."),
    ]

    static let speaker: [SpeechModel] = [
        SpeechModel(id: "campp", name: "CAM++ (FluidAudio)", size: "28 MB", ram: "~50 MB", speed: "~15 ms per 3 s",
                    note: "Own-voice filter: wake, end of turn and transcript only in his voice."),
        SpeechModel(id: "off", name: "Off", size: "-", ram: "-", speed: "-", note: "Any voice can wake it."),
    ]

    static func info(_ id: String) -> SpeechModel? { (stt + speaker).first { $0.id == id } }

    /// True once the model's files are on this Mac.
    static func downloaded(_ id: String) -> Bool {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if id.hasPrefix("w") {
            let base = id.hasSuffix("+p") ? String(id.dropLast(2)) : id
            return fm.fileExists(atPath: WhisperSTT.downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(WhisperSTT.folder(base))").path)
        }
        let fluid = support.appendingPathComponent("FluidAudio/Models")
        switch id {
        case "v2": return fm.fileExists(atPath: fluid.appendingPathComponent("parakeet-tdt-0.6b-v2").path)
        case "v3": return ((try? fm.contentsOfDirectory(atPath: fluid.path)) ?? []).contains { $0.hasPrefix("parakeet-tdt-0.6b-v3") }
        case "canary": return fm.fileExists(atPath: fluid.appendingPathComponent("canary-1b-v2-coreml").path)
        case "cohere": return fm.fileExists(atPath: fluid.appendingPathComponent("cohere-transcribe").path)
        case "campp": return fm.fileExists(atPath: fluid.appendingPathComponent("campplus").path)
        default: return true
        }
    }
}

/// NVIDIA Canary 1B v2 through FluidAudio (int4 encoder).
actor CanarySTT {
    static let shared = CanarySTT()
    private var manager: CanaryManager?

    func transcribe(_ samples: [Float]) async throws -> String {
        if manager == nil { manager = try await CanaryManager.load(precision: .int4, source: .english, target: .english) }
        return try await manager!.transcribe(audio: samples)
    }
}
