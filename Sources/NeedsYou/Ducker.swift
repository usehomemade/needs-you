import AVFoundation
import Foundation
import NeedsYouShared

/// Lowers other audio (music, videos) while he talks to Needs You (HM-1413): after
/// "Hey Mac" or the turn shortcut, through his command, and while he answers a
/// question or "which chat?". Never during the always-on wake word listening.
///
/// It is the same ducking his music already gets while Needs You speaks: Apple's
/// voice processing lowers other apps' audio while a voice-processing unit runs
/// (same level and fade as `VoicePlayer`). Here the bundled helper runs that unit
/// (`needs-you duck-hold`) with a silent output, throwing its mic audio away. It is a
/// separate process because voice processing inside the app takes the mic from the
/// plain engines that record him (they get no buffers at all meanwhile); in another
/// process they keep hearing him unchanged (`voice-test --title duck:probe`). His
/// system volume is never touched. If Needs You quits or crashes, the helper exits
/// and macOS brings the audio back.
///
/// Who holds the floor is `DuckState` (holders, linger, voice hand-over).
final class Ducker {
    static let shared = Ducker()

    static let defaultsKey = "duckWhileListening"
    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    private let q = DispatchQueue(label: "needs-you.duck")
    private var state = DuckState()
    private var helper: Process?
    private var stdin: FileHandle?
    private var timer: DispatchWorkItem?
    /// Test hook: true while the ducking helper runs.
    var active: Bool { q.sync { helper?.isRunning == true } }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// He holds the floor for `who` (holding the same name again counts once).
    func hold(_ who: String) {
        q.async {
            guard Self.enabled else { return }
            self.state.hold(who, now: Self.now)
            self.apply()
        }
    }

    func release(_ who: String) {
        q.async {
            self.state.release(who, now: Self.now)
            self.apply()
        }
    }

    func set(_ who: String, _ on: Bool) { on ? hold(who) : release(who) }

    /// Settings switch turned off: audio comes back now.
    func releaseAll() {
        q.async { self.state.releaseAll(); self.apply() }
    }

    /// Needs You's voice player is about to run its own voice processing (which ducks
    /// on its own) or has stopped. Synchronous, so the helper is told to stop before it starts.
    func voice(_ playing: Bool) {
        q.sync {
            guard state.voicePlaying != playing else { return }
            state.voice(playing)
            apply()
        }
    }

    private func apply() {
        let now = Self.now
        state.expire(now: now)
        let want = state.engineOn(now: now)
        if want, helper == nil { start() }
        if !want, helper != nil { stop() }
        timer?.cancel(); timer = nil
        if let next = state.nextChange(now: now) {
            let t = DispatchWorkItem { [weak self] in self?.apply() }
            timer = t
            q.asyncAfter(deadline: .now() + max(0.05, next - now), execute: t)
        }
    }

    private func start() {
        let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/needs-you")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            Isolation.note("duck: helper missing at \(exe.path)")
            return
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["duck-hold"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        let who = state.holders.keys.sorted().joined(separator: ", ")
        output.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let line = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Isolation.note(line == "ducking" ? "duck: other audio lowered (\(who))" : "duck: \(line)")
        }
        p.terminationHandler = { [weak self] proc in
            output.fileHandleForReading.readabilityHandler = nil
            self?.q.async {
                guard let self, self.helper === proc else { return }
                self.helper = nil; self.stdin = nil // it failed or was killed: do not restart in a loop
                Isolation.note("duck: helper ended (\(proc.terminationStatus))")
            }
        }
        do {
            try p.run()
            helper = p
            stdin = input.fileHandleForWriting
        } catch {
            Isolation.note("duck: could not start the helper (\(error.localizedDescription))")
        }
    }

    private func stop() {
        guard let p = helper else { return }
        helper = nil
        try? stdin?.close() // the helper exits when stdin closes
        stdin = nil
        q.asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
        Isolation.note("duck: other audio back")
    }

    /// Test hook: a plain mic engine (like the ones that record him) runs while the
    /// ducker turns on and off. Reports its level, format and whether it kept running.
    static func probe() async -> String {
        let e = AVAudioEngine()
        let input = e.inputNode
        let f = input.outputFormat(forBus: 0)
        guard f.sampleRate > 0 else { return "no mic" }
        let lock = NSLock()
        var sum: Double = 0, n = 0, buffers = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: f) { buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            var s: Double = 0
            for i in 0..<Int(buf.frameLength) { s += Double(ch[i] * ch[i]) }
            lock.withLock { sum += s; n += Int(buf.frameLength); buffers += 1 }
        }
        var changes = 0
        let obs = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(obs); input.removeTap(onBus: 0); e.stop() }
        do { e.prepare(); try e.start() } catch { return "plain engine failed: \(error.localizedDescription)" }
        func window(_ label: String) async -> String {
            lock.withLock { sum = 0; n = 0; buffers = 0 }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let (s, c, b) = lock.withLock { (sum, n, buffers) }
            let db = c > 0 ? 10 * log10(s / Double(c) + 1e-14) : -140
            return String(format: "%@: %.1f dB, %d buffers, running %@", label, db, b, e.isRunning ? "yes" : "no")
        }
        var out = [String(format: "mic %.0f Hz x%d", f.sampleRate, f.channelCount)]
        out.append(await window("before"))
        shared.hold("probe")
        try? await Task.sleep(nanoseconds: 500_000_000)
        let on = shared.active
        out.append(await window("ducked (engine \(on ? "on" : "off"))"))
        shared.release("probe")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        out.append(await window("after (engine \(shared.active ? "on" : "off"))"))
        let f2 = input.outputFormat(forBus: 0)
        out.append(String(format: "format after %.0f Hz x%d, config changes %d", f2.sampleRate, f2.channelCount, changes))
        return out.joined(separator: " | ")
    }
}
