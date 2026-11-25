import Darwin
import Foundation
import NeedsYouShared

/// Uses the training recordings: re-learns his voice from many samples, tunes the
/// own-voice threshold, cuts a personal eval set, and scores every speech model on it.
@MainActor
final class TrainingLab: ObservableObject {
    static let shared = TrainingLab()

    @Published private(set) var sessions: [TrainingSession] = TrainingStore.list()
    @Published private(set) var busy: String?
    @Published private(set) var processReport: String?
    @Published private(set) var results: [EvalResult] = TrainingLab.loadResults()

    struct EvalClip: Codable {
        var file: String
        var kind: TrainingPrompt.Kind
        var text: String
        var hasWake: Bool
        var background: String
        var source: String   // mac, iphone, merge-iva, merge-nlms
    }

    struct EvalResult: Codable, Identifiable {
        var id: String { model + "/" + (source ?? "mac") }
        var model: String
        var name: String
        var wakeCaught: Int
        var wakeTotal: Int
        var falseWakes: Int
        var otherTotal: Int
        var wer: Double          // 0...1+, command and name lines
        var medianMs: Double
        var cpuPercent: Double   // of one core, while transcribing
        var footprintMB: Double
        var error: String?
        var date: Date
        var source: String?      // mac, iphone, merge-iva, merge-nlms
    }

    nonisolated static var evalDir: URL { TrainingStore.root.appendingPathComponent("eval", isDirectory: true) }
    nonisolated static var resultsURL: URL { evalDir.appendingPathComponent("results.json") }

    func reload() { sessions = TrainingStore.list(); canRestore = SpeakerID.canRestore }
    @Published private(set) var canRestore = SpeakerID.canRestore

    /// Puts back the voice and threshold from before the last "Learn From Recordings".
    func restore() async -> String {
        let ok = await SpeakerID.shared.restorePrevious()
        canRestore = SpeakerID.canRestore
        processReport = ok ? "Restored your previous voice and threshold." : "Nothing to restore."
        return processReport!
    }

    func delete(_ s: TrainingSession) { TrainingStore.delete(s); reload() }

    // MARK: Process

    /// Re-enroll from all sessions, tune the threshold, write the eval set.
    @discardableResult
    func process() async -> String {
        busy = "Learning your voice from the recordings…"
        defer { busy = nil }
        do {
            let report = try await Self.runProcess(sessions)
            processReport = report
            return report
        } catch {
            processReport = "Failed: \(error.localizedDescription)"
            return processReport!
        }
    }

    nonisolated static func runProcess(_ sessions: [TrainingSession]) async throws -> String {
        guard !sessions.isEmpty else { throw NSError(domain: "NeedsYou", code: 20, userInfo: [NSLocalizedDescriptionKey: "No training sessions yet"]) }
        let fm = FileManager.default
        try? fm.removeItem(at: evalDir)
        try fm.createDirectory(at: evalDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var his: [[Float]] = []          // speech windows from his lines
        var hisClips: [[Float]] = []     // whole lines, for the threshold
        var background: [[Float]] = []   // windows from the silent stretches
        var clips: [EvalClip] = []
        for s in sessions {
            let mac = TrainingStore.load(s.macURL)
            var phone: [Float]? = s.hasPhone ? TrainingStore.load(s.phoneURL) : nil
            if let p = phone, let a = TwoMic.align(mac, p) , a.confidence >= TwoMic.minConfidence {
                phone = TwoMic.apply(a, to: p, length: mac.count)
            } else if let p = phone, let off = s.phoneOffset {
                phone = TwoMic.shift(p, by: -Int(off * 16_000), length: mac.count)
            }
            for (i, m) in s.marks.enumerated() {
                let a = max(0, Int(m.start * 16_000)), b = min(mac.count, Int(m.end * 16_000))
                guard b - a > 8_000 else { continue }
                let clip = Array(mac[a..<b])
                let speech = try await speechWindows(clip)
                if m.prompt.kind == .silent { background += speech.isEmpty ? SpeakerID.windows(clip) : speech; }
                else { his += speech; hisClips.append(clip) }
                var takes: [(String, [Float])] = [("mac", clip)]
                if let phone, b <= phone.count {
                    let other = Array(phone[a..<b])
                    takes.append(("iphone", other))
                    // The two merge methods as the live path runs them (HM-1331): the take
                    // that sounds more like him first; nil when the takes do not line up.
                    let sm = (try? await SpeakerID.shared.best(clip)) ?? nil, sp = (try? await SpeakerID.shared.best(other)) ?? nil
                    let (best, second) = (sm ?? -1) >= (sp ?? -1) ? (clip, other) : (other, clip)
                    for method in ["iva", "nlms"] {
                        if let o = await MicMerge.merge(best: best, other: second, method: method) { takes.append(("merge-" + method, o.audio)) }
                    }
                }
                for (src, audio) in takes {
                    let name = "\(s.id)-\(i)-\(src).wav"
                    try Recorder.wav(audio).write(to: evalDir.appendingPathComponent(name))
                    clips.append(EvalClip(file: name, kind: m.prompt.kind, text: m.prompt.text, hasWake: m.prompt.hasWake,
                                          background: s.background, source: src))
                }
            }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try enc.encode(clips).write(to: evalDir.appendingPathComponent("labels.json"))

        // His voiceprint: mean of his speech windows, then again over the 70 % closest
        // (drops windows where the background drowned him out).
        guard his.count >= 5 else { throw NSError(domain: "NeedsYou", code: 21, userInfo: [NSLocalizedDescriptionKey: "Too little of your voice in the recordings (\(his.count) windows)"]) }
        var embs: [[Float]] = []
        for w in his { embs.append(try await SpeakerID.shared.embed(w)) }
        var c = normalize(mean(embs))
        let sims = embs.map { dot($0, c) }
        let cut = sims.sorted()[sims.count * 30 / 100]
        c = normalize(mean(zip(embs, sims).filter { $0.1 >= cut }.map(\.0)))
        try await SpeakerID.shared.save(c)
        // PS4 (Settings → Models) conditions on raw audio: the 10 s of windows closest to the voiceprint.
        PS4.saveEnrollment(zip(his, sims).sorted { $0.1 > $1.1 }.map(\.0))

        // Threshold: highest catch of his lines with at most 2 % of background windows passing.
        var pos: [Float] = []
        for clip in hisClips { if let b = try await SpeakerID.shared.best(clip) { pos.append(b) } }
        var neg: [Float] = []
        for w in background { neg.append(dot(try await SpeakerID.shared.embed(w), c)) }
        var report = "Learned your voice from \(his.count) windows (about \(max(1, his.count / 60)) min of speech) in \(sessions.count) session(s). "
        if !neg.isEmpty, !pos.isEmpty {
            var best: (t: Float, tpr: Float) = (0.45, -1)
            for k in 25...75 {
                let t = Float(k) / 100
                let fpr = Float(neg.filter { $0 >= t }.count) / Float(neg.count)
                let tpr = Float(pos.filter { $0 >= t }.count) / Float(pos.count)
                if fpr <= 0.02, tpr > best.tpr || (tpr == best.tpr && t > best.t) { best = (t, tpr) }
            }
            if best.tpr >= 0 {
                let ud = UserDefaults.standard
                ud.set(ud.object(forKey: "voiceThreshold") as? Double ?? -1, forKey: "voiceThresholdPrevious")
                ud.set(Double(best.t), forKey: "voiceThreshold")
                report += String(format: "Own-voice threshold %.2f: %.0f%% of your lines pass, background windows max %.2f. ", best.t, best.tpr * 100, neg.max() ?? 0)
            }
        } else {
            report += "Threshold unchanged (no quiet stretches with background to compare). "
        }
        report += "Eval set: \(clips.count) clips."
        return report
    }

    nonisolated private static func speechWindows(_ clip: [Float]) async throws -> [[Float]] {
        let probs = try await SileroVAD.shared.probabilities(clip)
        let per = SileroVAD.chunk
        return SpeakerID.windowStarts(clip.count).compactMap { s in
            let a = s / per, b = min(probs.count, (s + SpeakerID.window) / per)
            guard b > a else { return nil }
            let p = probs[a..<b].reduce(0, +) / Float(b - a)
            return p >= 0.5 ? Array(clip[s..<min(clip.count, s + SpeakerID.window)]) : nil
        }
    }

    // MARK: Evaluate

    /// Scores each model on the eval set: wake catch, false wakes, WER, latency, CPU, RAM.
    func evaluate(models: [String]) async {
        for m in models {
            busy = "Evaluating \(SpeechModels.info(m)?.name ?? m)…"
            let rs = await Self.runEval(model: m)
            results.removeAll { $0.model == m }
            results += rs
            Self.saveResults(results)
        }
        busy = nil
    }

    /// One result per mic (Mac, iPhone): each model transcribes every clip once.
    nonisolated static func runEval(model: String) async -> [EvalResult] {
        // "wturbo+p@en/tr" (HM-1351): as if those languages were on, without changing the setting.
        let (base, langs) = STTLanguage.split(model)
        return await STTLanguage.$spokenOverride.withValue(langs) { await runEval(model: model, base: base) }
    }

    nonisolated private static func runEval(model: String, base: String) async -> [EvalResult] {
        let name = (SpeechModels.info(base)?.name ?? base) + (model == base ? "" : " (" + model.split(separator: "@").last.map(String.init)! + ")")
        func blank(_ src: String) -> EvalResult {
            EvalResult(model: model, name: name, wakeCaught: 0, wakeTotal: 0, falseWakes: 0, otherTotal: 0,
                       wer: 0, medianMs: 0, cpuPercent: 0, footprintMB: 0, error: nil, date: Date(), source: src)
        }
        guard let data = try? Data(contentsOf: evalDir.appendingPathComponent("labels.json")),
              let clips = try? JSONDecoder().decode([EvalClip].self, from: data), !clips.isEmpty else {
            var r = blank("mac"); r.error = "No eval set: run Learn From Recordings first"; return [r]
        }
        do { try await LocalSTT.shared.warm(base) } catch { var r = blank("mac"); r.error = error.localizedDescription; return [r] }
        let sources = ["mac", "iphone", "merge-iva", "merge-nlms"].filter { s in clips.contains { $0.source == s } }
        var res = Dictionary(uniqueKeysWithValues: sources.map { ($0, blank($0)) })
        var ms: [String: [Double]] = [:], errs: [String: Int] = [:], words: [String: Int] = [:]
        var details: [[String: String]] = []
        let foot0 = footprintMB()
        let cpu0 = cpuSeconds(), wall0 = Date()
        for c in clips {
            let audio = TrainingStore.load(evalDir.appendingPathComponent(c.file))
            let t0 = Date()
            let h = try? await LocalSTT.shared.hear(samples: audio, model: base, language: .spoken)
            let text = h?.text ?? ""
            let took = Date().timeIntervalSince(t0) * 1000
            ms[c.source, default: []].append(took)
            // The phrase he read in this clip (recorded with the phrase set back then).
            let wm = Self.matcher(for: c)
            let woke = wm.contains(text, voiceLearned: SpeakerID.isEnrolled)
            if c.hasWake { res[c.source]?.wakeTotal += 1; if woke { res[c.source]?.wakeCaught += 1 } }
            else { res[c.source]?.otherTotal += 1; if woke { res[c.source]?.falseWakes += 1 } }
            var row = ["file": c.file, "source": c.source, "kind": c.kind.rawValue, "heard": text, "woke": woke ? "yes" : "no",
                       "ms": String(format: "%.0f", took), "lang": h?.language ?? "-"]
            if c.kind == .command || c.kind == .name {
                let (e, n) = wer(ref: stripWake(c.text, wm), hyp: stripWake(text, wm))
                errs[c.source, default: 0] += e; words[c.source, default: 0] += n
                row["expected"] = c.text; row["wer"] = String(format: "%.2f", n > 0 ? Double(e) / Double(n) : 0)
            }
            details.append(row)
        }
        let wall = Date().timeIntervalSince(wall0)
        let cpu = wall > 0 ? (cpuSeconds() - cpu0) / wall * 100 : 0
        let foot = max(foot0, footprintMB())
        for s in sources {
            res[s]?.cpuPercent = cpu
            res[s]?.footprintMB = foot
            let w = words[s] ?? 0
            res[s]?.wer = w > 0 ? Double(errs[s] ?? 0) / Double(w) : 0
            let m = (ms[s] ?? [0]).sorted()
            res[s]?.medianMs = m[m.count / 2]
        }
        // Per-clip results, to see what each model heard.
        if let d = try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: evalDir.appendingPathComponent("details-\(model.replacingOccurrences(of: "/", with: "-")).json"))
        }
        return sources.compactMap { res[$0] }
    }

    nonisolated static func stripWake(_ s: String, _ m: WakeMatcher) -> String {
        m.after(s, voiceLearned: SpeakerID.isEnrolled) ?? s
    }

    /// Clips with a wake phrase: a matcher for the phrase in the line he read
    /// ("Hey Claude, this one: ..." -> "Hey Claude"); other clips: the current phrase.
    nonisolated static func matcher(for c: EvalClip) -> WakeMatcher {
        guard c.hasWake, let cut = c.text.firstIndex(where: { ",.:!?".contains($0) }) else { return Wake.matcher }
        return WakeMatcher(phrase: String(c.text[..<cut]))
    }

    nonisolated static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "ç", with: "c")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty && !["um", "uh", "ähm"].contains($0) }
    }

    /// Word errors (substitutions + insertions + deletions) and reference length.
    nonisolated static func wer(ref: String, hyp: String) -> (Int, Int) {
        let r = words(ref), h = words(hyp)
        var d = Array(0...h.count)
        for (i, a) in r.enumerated() {
            var prev = d; d[0] = i + 1
            for (j, b) in h.enumerated() { d[j + 1] = min(prev[j + 1] + 1, d[j] + 1, prev[j] + (a == b ? 0 : 1)) }
            prev = d
        }
        return (d[h.count], r.count)
    }

    nonisolated static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    nonisolated static func loadResults() -> [EvalResult] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: resultsURL)).flatMap { try? dec.decode([EvalResult].self, from: $0) } ?? []
    }

    nonisolated static func saveResults(_ r: [EvalResult]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(r).write(to: resultsURL)
    }
}

func mean(_ v: [[Float]]) -> [Float] {
    guard let n = v.first?.count else { return [] }
    var s = [Float](repeating: 0, count: n)
    for x in v { for i in 0..<n { s[i] += x[i] } }
    return s.map { $0 / Float(v.count) }
}
func normalize(_ v: [Float]) -> [Float] { let n = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-9); return v.map { $0 / n } }
func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
