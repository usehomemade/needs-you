import Foundation

/// Mic setting "Merge (experimental)": combine the Mac and iPhone takes of one
/// utterance when they line up well enough; otherwise keep the best single mic.
enum MicMerge {
    static var enabled: Bool { UserDefaults.standard.string(forKey: "micMode") == "merge" }
    /// snr (per-band SNR weighting), iva (AuxIVA, keep the output most like him), nlms (far mic as noise reference)
    static var method: String { UserDefaults.standard.string(forKey: "mergeMethod") ?? "iva" }

    struct Outcome { var audio: [Float]; var label: String; var score: Float? }

    /// `a` is the take with the better own-voice score. Returns nil when the takes
    /// do not line up (low confidence): the caller keeps the best mic.
    static func merge(best a: [Float], other b: [Float], method: String = method) async -> Outcome? {
        guard let al = TwoMic.align(a, b, maxLag: 3 * 16_000), al.confidence >= TwoMic.minConfidence else { return nil }
        let bb = TwoMic.apply(al, to: b, length: a.count)
        switch method {
        case "iva":
            let outs = TwoMic.auxIVA(a, bb)
            var best: Outcome?
            for (i, o) in outs.enumerated() {
                let s = try? await SpeakerID.shared.best(o)
                if best == nil || (s ?? nil ?? -1) > (best!.score ?? -1) { best = Outcome(audio: o, label: "AuxIVA out \(i)", score: s ?? nil) }
            }
            return best
        case "nlms":
            let o = TwoMic.noiseReference(near: a, far: bb)
            return Outcome(audio: o, label: "noise reference", score: (try? await SpeakerID.shared.best(o)) ?? nil)
        default:
            let o = TwoMic.snrWeighted(a, bb)
            return Outcome(audio: o, label: "SNR-weighted", score: (try? await SpeakerID.shared.best(o)) ?? nil)
        }
    }

    /// Test hook: all methods on two recordings; writes each output, returns scores.
    static func experiment(_ a: [Float], _ b: [Float], prefix: String) async -> String {
        guard let al = TwoMic.align(a, b) else { return "could not align" }
        let n = a.count
        let bb = TwoMic.apply(al, to: b, length: n)
        var outs: [(String, [Float])] = [("mac", a), ("iphone-aligned", bb), ("snr", TwoMic.snrWeighted(a, bb))]
        let iva = TwoMic.auxIVA(a, bb)
        outs.append(("iva0", iva[0])); outs.append(("iva1", iva[1]))
        let sa = (try? await SpeakerID.shared.best(a)) ?? nil, sb = (try? await SpeakerID.shared.best(bb)) ?? nil
        let (near, far) = (sa ?? 0) >= (sb ?? 0) ? (a, bb) : (bb, a)
        outs.append(("nlms", TwoMic.noiseReference(near: near, far: far)))
        var parts = [String(format: "lag %.1f samples, drift %.0f ppm, confidence %.2f", al.lag, al.drift * 1e6, al.confidence)]
        for (name, o) in outs {
            try? Recorder.wav(o).write(to: URL(fileURLWithPath: "\(prefix)-\(name).wav"))
            let s = (try? await SpeakerID.shared.best(o)) ?? nil
            parts.append(String(format: "%@ voice %.2f snr %.1f", name, s ?? -1, WakeListener.snr(o)))
        }
        return parts.joined(separator: " | ")
    }
}
