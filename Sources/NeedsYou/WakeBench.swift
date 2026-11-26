import AVFoundation
import FluidAudio
import Foundation

/// Test hook: how fast does "Hey Mac" wake the listener on recorded clips?
/// `needs-you voice-test <wav>... --title wake-latency[:fast|:slow]`
/// Plays each file in real time through a fresh WakeListener (the live mic keeps
/// running; nothing is sent, no sound plays) and reports, per clip, when the wake
/// fired after the end of the speech (quiet clips: last frame within 30 dB of the
/// loudest) and after the end of the clip.
enum WakeBench {
    struct Row {
        var file: String
        var woke: Double?        // seconds from playback start
        var firstText: Double?   // first analyzer/parakeet text with the wake word
        var speechEnd: Double
        var clipEnd: Double
        var via = ""
        var ended: Double?       // command handed over (untilCommand)
        var endReason = ""
        var firstSubtitle: Double? // seconds after the wake (untilCommand)
        var subtitle = ""
        var language = ""
    }

    /// `untilCommand`: keep going after the wake until the command is handed over,
    /// and report when and why it ended (HM-1345: "only other voices" during a pause).
    static func run(files: [String], fast: Bool?, untilCommand: Bool = false) async -> String {
        var rows: [Row] = []
        for f in files where !f.isEmpty {
            if let r = await one(f, fast: fast, untilCommand: untilCommand) { rows.append(r) }
        }
        func med(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "-" }
            let s = v.sorted()
            return String(format: "%.2f", s[s.count / 2])
        }
        let caught = rows.filter { $0.woke != nil }
        let fromSpeech = caught.map { $0.woke! - $0.speechEnd }
        let fromClip = caught.map { $0.woke! - $0.clipEnd }
        let lines = rows.map { r in
            String(format: "%@ end %.2f clip %.2f wake %@ (%+.2f after speech) text %@ %@",
                   (r.file as NSString).lastPathComponent, r.speechEnd, r.clipEnd,
                   r.woke.map { String(format: "%.2f", $0) } ?? "none", (r.woke ?? .nan) - r.speechEnd,
                   r.firstText.map { String(format: "%.2f", $0) } ?? "-", r.via)
            + (untilCommand ? " command ended \(r.ended.map { String(format: "%.2f", $0) } ?? "never") \(r.endReason)"
                + " first subtitle \(r.firstSubtitle.map { String(format: "%.2f", $0) } ?? "none") [\(r.language)] \(r.subtitle)" : "")
        }
        let maxS = fromSpeech.max().map { String(format: "%.2f", $0) } ?? "-"
        return "woke \(caught.count)/\(rows.count), after speech end: median \(med(fromSpeech)) s, max \(maxS) s; after clip end: median \(med(fromClip)) s || " + lines.joined(separator: " | ")
    }

    private static func one(_ path: String, fast: Bool?, untilCommand: Bool) async -> Row? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let samples = (try? AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))) ?? []
        let clipEnd = Double(samples.count) / 16_000
        var row = Row(file: path, speechEnd: speechEnd(samples), clipEnd: clipEnd)

        let l = WakeListener()
        l.source = "bench"
        l.endSilence = Prefs.endSilence
        if let fast { l.fastResults = fast }
        do { try await l.prepare() } catch { return nil }
        let lock = NSLock()
        var start: Date?
        var woke: Date?
        var text: Date?
        var via = "analyzer"
        var eof = false
        var ended: Date?
        var reason = "turn end"
        var firstSub: Date?
        var subText = ""
        var lang = ""
        l.onCommandPartial = { t, _ in lock.withLock { if firstSub == nil { firstSub = Date(); subText = t } } }
        l.trace = { m in
            lock.withLock {
                if m.hasPrefix("command ended") { reason = m }
                if m.hasPrefix("command language") { lang = m }
                if m == "file playback start" { start = Date() }
                if text == nil, m.hasPrefix("heard") || m.hasPrefix("parakeet"),
                   let colon = m.range(of: ": "), Wake.containsWakeWord(String(m[colon.upperBound...])) {
                    text = Date()
                    if m.hasPrefix("parakeet") { via = "parakeet" }
                }
                if m == "wake via parakeet", woke == nil { via = "parakeet" }
            }
        }
        l.onWake = { lock.withLock { if woke == nil { woke = Date() } } }
        l.onCommand = { _ in lock.withLock { if ended == nil { ended = Date() } } }
        l.onEndOfFile = { lock.withLock { eof = true } }
        do { try l.startFile(file) } catch { return nil }
        let deadline = Date().addingTimeInterval(clipEnd + (untilCommand ? 12 : 6))
        while Date() < deadline {
            let done = lock.withLock { eof || ended != nil || (!untilCommand && woke.map { Date().timeIntervalSince($0) > 0.3 } ?? false) }
            if done { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        l.stop()
        lock.withLock {
            if let s = start {
                row.woke = woke.map { $0.timeIntervalSince(s) }
                row.firstText = text.map { $0.timeIntervalSince(s) }
                row.ended = ended.map { $0.timeIntervalSince(s) }
            }
            row.via = woke == nil ? "" : via
            row.endReason = ended == nil ? "" : reason
            if let w = woke { row.firstSubtitle = firstSub.map { $0.timeIntervalSince(w) } }
            row.subtitle = subText; row.language = lang
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return row
    }

    /// End of the speech: the last 20 ms frame within 30 dB of the loudest one.
    static func speechEnd(_ s: [Float]) -> Double {
        let n = 320
        var db: [Float] = []
        var i = 0
        while i + n <= s.count {
            var e: Float = 0
            for j in i..<i + n { e += s[j] * s[j] }
            db.append(10 * log10(e / Float(n) + 1e-12)); i += n
        }
        guard let top = db.max() else { return 0 }
        let last = db.lastIndex { $0 > top - 30 } ?? 0
        return Double(last + 1) * Double(n) / 16_000
    }
}
