import Foundation

/// The local speech models (Parakeet, Kokoro, speaker ID, Silero, Smart Turn)
/// are not in the app bundle. scripts/install.sh fetches them with
/// `--download-models`; a downloaded release build fetches them in the
/// background on its first launch instead, so the first ask does not wait.
enum ModelPrefetch {
    static let doneKey = "modelsPrefetched"

    static func downloadAll() async throws {
        try await LocalSTT.shared.warm()
        try await LocalSTT.shared.warm(LocalSTT.fast)
        _ = try await SpeakerID.shared.load()
        _ = try await LocalTTS.shared.speech("Ready.")
        _ = try await SileroVAD.shared.load()
        try await SmartTurn.download()
        _ = try await SmartTurn.shared.load()
    }

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        Task.detached(priority: .utility) {
            do {
                try await downloadAll()
                UserDefaults.standard.set(true, forKey: doneKey)
                Isolation.note("models: first-run download done")
            } catch {
                // Tried again on the next launch; each model also loads on demand.
                Isolation.note("models: first-run download failed: \(error.localizedDescription)")
            }
        }
    }
}
