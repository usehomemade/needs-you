import AppKit
import QuartzCore
import SwiftUI

/// Big subtitles at the bottom of the screen and a Siri-like glow along the screen
/// edges while the user or Needs You is talking (HM-1346).
///
/// The overlay is a click-through panel that never takes focus. When nobody talks it
/// is ordered out and its animations are removed, so it costs nothing while idle.
/// The glow is Core Animation only (a rotating conic gradient under a static soft
/// mask): the render server animates it, the app does no per-frame work.
@MainActor
final class Subtitles: ObservableObject {
    static let shared = Subtitles()

    enum Speaker { case user, claude }

    @Published private(set) var speaker: Speaker = .user
    @Published private(set) var text = ""
    /// The newest word of a live partial, still settling: drawn dimmer.
    @Published private(set) var pending = ""
    @Published private(set) var showText = false
    /// Bumped when the text is re-read in another language: the line cross-fades.
    @Published private(set) var swaps = 0
    @Published private(set) var fontSize: CGFloat = 50
    @Published private(set) var maxWidth: CGFloat = 1400
    @Published private(set) var bottomInset: CGFloat = 120

    static var enabled: Bool { UserDefaults.standard.object(forKey: "subtitlesOnScreen") as? Bool ?? true }

    private var panel: NSPanel?
    private var glow: GlowView?
    /// Who has the glow right now (nil: fading out or hidden).
    private var active: Speaker?
    /// Which mic's listener woke for this command ("mac", "iphone", "ask"); partials
    /// and levels from the other one are ignored so the text does not flicker.
    private var userSource: String?
    private var hideTask: Task<Void, Never>?
    private var claudeTask: Task<Void, Never>?
    private var lastLevelAt = Date.distantPast
    private var maxChars = 150

    // MARK: The user

    /// The mic opened for him (after "Hey Mac", or an ask waits for his answer).
    func userBegan(source: String) {
        Island.shared.listening(source: source)
        guard Self.enabled else { return }
        userSource = source
        claudeTask?.cancel(); claudeTask = nil
        begin(.user)
        if speaker != .user || !showText { text = ""; pending = "" }
        speaker = .user
    }

    /// Live text of what he has said so far.
    /// `swap`: the language changed (HM-1362), so the new text cross-fades in place of the old.
    func userPartial(_ raw: String, source: String, swap: Bool = false) {
        guard Self.enabled, active == .user, source == userSource else { return }
        let t = Self.clean(raw)
        guard !t.isEmpty else { return }
        if swap && showText { swaps += 1 }
        speaker = .user
        let shown = Self.tail(t, max: maxChars)
        if let space = shown.lastIndex(of: " ") {
            text = String(shown[..<space]); pending = String(shown[shown.index(after: space)...])
        } else {
            text = ""; pending = shown
        }
        showText = true
    }

    /// He stopped talking (the turn ended); the text stays until the final transcript.
    func userStopped() {
        Island.shared.thinking()
        guard active == .user else { return }
        userSource = nil
        level(0, .user, source: nil)
        scheduleEnd(glowAfter: 0.6, textAfter: 4)
    }

    /// What was transcribed for the whole turn.
    func userFinal(_ raw: String) {
        guard Self.enabled, active == nil || active == .user, panel?.isVisible == true else { return }
        let t = Self.clean(raw)
        if !t.isEmpty {
            speaker = .user
            pending = ""
            text = Self.tail(t, max: maxChars)
            showText = true
        }
        if active == .user { userSource = nil; scheduleEnd(glowAfter: 1, textAfter: 2.5) }
        else { scheduleEnd(glowAfter: 0, textAfter: 2.5) }
    }

    // MARK: Claude

    /// Needs You starts playing `text`. Subtitles advance chunk by chunk in step with
    /// the audio's length; the glow follows the audio's loudness.
    func claudeSpeaks(_ text: String, audio: Data?) {
        let (duration, envelope) = audio.map(Self.analyse) ?? (Double(text.count) / 15, [])
        claudeSpeaks(text, duration: duration, envelope: envelope)
    }

    func claudeSpeaks(_ spoken: String, duration: Double, envelope: [Float]) {
        Island.shared.claudeSpeaks(spoken, duration: duration, envelope: envelope)
        guard Self.enabled else { return }
        claudeTask?.cancel()
        userSource = nil
        begin(.claude)
        speaker = .claude
        let chunks = Self.chunks(spoken, max: maxChars * 2 / 3)
        let total = Double(max(1, chunks.reduce(0) { $0 + $1.count }))
        // When each chunk starts: proportional to its share of the characters.
        var starts: [Double] = []
        var acc = 0.0
        for c in chunks { starts.append(acc / total * duration); acc += Double(c.count) }
        let began = Date()
        claudeTask = Task { [weak self] in
            var shown = -1
            while !Task.isCancelled {
                guard let self else { return }
                let t = Date().timeIntervalSince(began)
                let i = max(0, (starts.lastIndex { $0 <= t }) ?? 0)
                if i != shown, i < chunks.count {
                    shown = i
                    self.pending = ""
                    self.text = chunks[i]
                    self.showText = true
                }
                if !envelope.isEmpty {
                    let k = min(envelope.count - 1, Int(t / Self.envelopeStep))
                    self.level(envelope[k], .claude, source: nil)
                }
                if t > duration + 0.2 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Playback ended (finished, or "Stop, Mac").
    func claudeDone() {
        Island.shared.claudeDone()
        claudeTask?.cancel(); claudeTask = nil
        guard active == .claude else { return }
        level(0, .claude, source: nil)
        scheduleEnd(glowAfter: 1, textAfter: 1.6)
    }

    // MARK: Level

    /// 0...1 loudness of whoever is talking; drives the glow's brightness (at most 20 Hz).
    func level(_ v: Float, _ who: Speaker, source: String?) {
        if who == .user { Island.shared.micLevel(v, source: source) }
        guard active == who, source == nil || source == userSource else { return }
        let now = Date()
        guard v == 0 || now.timeIntervalSince(lastLevelAt) >= 0.05 else { return }
        lastLevelAt = now
        glow?.setLevel(CGFloat(max(0, min(1, v))))
    }

    /// Settings switch turned off: hide at once.
    func disable() {
        claudeTask?.cancel(); claudeTask = nil
        hideTask?.cancel(); hideTask = nil
        active = nil; userSource = nil
        showText = false; text = ""; pending = ""
        glow?.stop()
        panel?.orderOut(nil)
    }

    // MARK: Showing and hiding

    private func begin(_ who: Speaker) {
        hideTask?.cancel(); hideTask = nil
        let p = panel ?? makePanel()
        if !p.isVisible {
            place(p)
            p.orderFrontRegardless()
        }
        active = who
        glow?.start(who)
    }

    private func scheduleEnd(glowAfter: Double, textAfter: Double) {
        hideTask?.cancel()
        let ending = active
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(glowAfter * 1e9))
            guard let self, !Task.isCancelled, self.active == ending else { return }
            self.active = nil
            self.glow?.fadeOut()
            try? await Task.sleep(nanoseconds: UInt64(max(0, textAfter - glowAfter) * 1e9))
            guard !Task.isCancelled, self.active == nil else { return }
            self.showText = false
            try? await Task.sleep(nanoseconds: 700_000_000) // fades finish
            guard !Task.isCancelled, self.active == nil else { return }
            self.text = ""; self.pending = ""
            self.glow?.stop()
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none // no AppKit snapshot animation on show/hide (HM-1410)
        let root = NSView(frame: p.contentRect(forFrameRect: p.frame))
        root.wantsLayer = true
        let g = GlowView(frame: root.bounds)
        g.autoresizingMask = [.width, .height]
        root.addSubview(g)
        let host = NSHostingView(rootView: SubtitleView(model: self))
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        p.contentView = root
        panel = p
        glow = g
        return p
    }

    /// The screen with the mouse on it; text size follows the screen width.
    private func place(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let f = screen.frame
        if p.frame != f { p.setFrame(f, display: false) }
        // About 46 pt on a 27" (2560 pt wide) screen.
        fontSize = min(56, max(36, f.width * 0.018))
        maxWidth = f.width * 0.78
        // Above the Dock when it sits at the bottom.
        let dock = max(0, screen.visibleFrame.minY - f.minY)
        bottomInset = dock + f.height * 0.07
        maxChars = Int(maxWidth / (fontSize * 0.55)) * 2 - 8 // two lines
        glow?.layout(for: f.size, cornerRadius: 12)
    }

    // MARK: Text

    static func clean(_ s: String) -> String {
        var t = Wake.afterWakeWord(s) ?? s
        t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.:;-")))
        guard let first = t.first else { return "" }
        return first.uppercased() + t.dropFirst()
    }

    /// The newest words, at most `max` characters, cut at a word boundary.
    static func tail(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let cut = s.suffix(max)
        let start = cut.firstIndex(of: " ").map { cut.index(after: $0) } ?? cut.startIndex
        return "\u{2026}" + cut[start...]
    }

    /// Sentences, with long ones split at word boundaries into pieces of at most `max`.
    static func chunks(_ s: String, max: Int) -> [String] {
        var sentences: [String] = []
        s.enumerateSubstrings(in: s.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let t = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { sentences.append(t) }
        }
        if sentences.isEmpty { sentences = [s] }
        var out: [String] = []
        for sentence in sentences {
            guard sentence.count > max else {
                // Two short sentences fit on screen together.
                if let last = out.last, last.count + sentence.count + 1 <= max / 2 { out[out.count - 1] = last + " " + sentence }
                else { out.append(sentence) }
                continue
            }
            var line = ""
            for w in sentence.split(separator: " ") {
                if !line.isEmpty, line.count + w.count + 1 > max { out.append(line); line = "" }
                line += line.isEmpty ? String(w) : " " + w
            }
            if !line.isEmpty { out.append(line) }
        }
        return out
    }

    // MARK: Audio

    static let envelopeStep = 0.05

    /// Length in seconds and a 20 Hz loudness envelope (0...1) of WAV speech
    /// (16-bit or float PCM, any header layout).
    static func analyse(_ wav: Data) -> (Double, [Float]) {
        let b = [UInt8](wav)
        guard b.count > 44, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 else { return (0, []) }
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        var rate = 0, bits = 16, channels = 1, dataAt = 0, dataLen = 0
        var o = 12
        while o + 8 <= b.count {
            let id = String(bytes: b[o..<o + 4], encoding: .ascii) ?? "", len = u32(o + 4)
            if id == "fmt " { channels = max(1, u16(o + 10)); rate = u32(o + 12); bits = u16(o + 22) }
            if id == "data" { dataAt = o + 8; dataLen = min(len, b.count - dataAt); break }
            o += 8 + len + (len & 1)
        }
        let width = bits / 8 * channels
        guard rate > 0, dataAt > 0, width > 0, bits == 16 || bits == 32 else { return (0, []) }
        let frames = dataLen / width
        let step = Int(Double(rate) * envelopeStep)
        var env: [Float] = []
        var i = 0
        while i < frames {
            let end = min(frames, i + step)
            var e: Float = 0
            for f in i..<end {
                let at = dataAt + f * width
                let v: Float = bits == 16 ? Float(Int16(bitPattern: UInt16(u16(at)))) / 32768
                                          : Float(bitPattern: UInt32(u32(at)))
                e += v * v
            }
            let db = 10 * log10(e / Float(end - i) + 1e-10)
            env.append(max(0, min(1, (db + 50) / 40)))
            i = end
        }
        return (Double(frames) / Double(rate), env)
    }

    // MARK: Demo

    /// `needs-you voice-test --title overlay-demo`: both sides with sample text, no audio.
    func demo() async {
        let saidText = "Hey Mac, orchard: check why the staging deploy failed and fix the migration if it is the cause"
        let words = saidText.split(separator: " ")
        userBegan(source: "demo")
        for n in stride(from: 3, through: words.count, by: 2) {
            userPartial(words.prefix(n).joined(separator: " "), source: "demo")
            level(Float.random(in: 0.35...0.95), .user, source: "demo")
            try? await Task.sleep(nanoseconds: 220_000_000)
        }
        userPartial(saidText, source: "demo")
        userStopped()
        try? await Task.sleep(nanoseconds: 300_000_000)
        userFinal(saidText)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        let reply = "The deploy failed on the migration step. I found the bad column default and pushed a fix to next."
        let env: [Float] = (0..<80).map { (i: Int) -> Float in
            let x = Double(i)
            let wave: Double = sin(x * 0.7) * sin(x * 0.13)
            return Float(0.45 + 0.4 * wave)
        }
        claudeSpeaks(reply, duration: 4, envelope: env)
        try? await Task.sleep(nanoseconds: 4_100_000_000)
        claudeDone()
    }
}

/// The subtitle line: big, centred near the bottom, two lines at most. His words are
/// white, Needs You's warm peach; a word still being recognised is dimmer. No labels.
struct SubtitleView: View {
    @ObservedObject var model: Subtitles

    static let claudeText = Color(red: 1.0, green: 0.824, blue: 0.741) // #ffd2bd

    private var line: Text {
        let base = Text(model.text)
        guard !model.pending.isEmpty else { return base }
        let dim = Text((model.text.isEmpty ? "" : " ") + model.pending).foregroundColor(.white.opacity(0.55))
        return base + dim
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.showText && !(model.text.isEmpty && model.pending.isEmpty) {
                line
                    .font(.system(size: model.fontSize, weight: .semibold))
                    .kerning(-0.01 * model.fontSize)
                    .foregroundStyle(model.speaker == .user ? Color.white : Self.claudeText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .lineSpacing(model.fontSize * 0.12)
                    .padding(.horizontal, model.fontSize * 0.7)
                    .padding(.vertical, model.fontSize * 0.35)
                    .background(
                        ZStack {
                            BlurBehind()
                            Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255).opacity(0.62)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: model.fontSize * 0.45, style: .continuous))
                    )
                    .frame(maxWidth: model.maxWidth)
                    .id("\(model.speaker)-\(model.swaps)")
                    .transition(.opacity)
            }
        }
        .padding(.bottom, model.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.3), value: model.showText)
        .animation(.easeOut(duration: 0.3), value: model.speaker)
        .animation(.easeInOut(duration: 0.25), value: model.swaps)
    }
}

/// A blurred dark material behind the subtitle, so it reads over a game, a video or a white page.
struct BlurBehind: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

