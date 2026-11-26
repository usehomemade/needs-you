import AppKit
import Combine
import NeedsYouShared
import SwiftUI

/// The status island at the top of the screen (HM-1350): one pure black shape that
/// grows out of the MacBook notch (or, on a screen without one, a pill just under the
/// menu bar) and morphs between states with springs, its content cross-fading.
///
/// It is the only place Needs You shows its state (HM-1363): there is no top-right
/// panel, HUD, toast or notification banner anywhere in the app, and `SurfaceGuardTests`
/// fails if one comes back. Besides it only the subtitles and the edge glow
/// (Subtitles.swift) and the app's own windows exist. It is a
/// click-through panel that never takes focus. When idle it is ordered out and has no
/// content views, so nothing ticks: the per-frame views (bars, dots, shimmer) only
/// exist while their state is on screen.
@MainActor
final class Island: ObservableObject {
    static let shared = Island()

    enum Mode: Equatable { case idle, wake, listening, thinking, sending, speaking, done, error, moon }

    enum Style: String, CaseIterable, Identifiable {
        case automatic, notch, external
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .notch: return "MacBook notch"
            case .external: return "External monitor"
            }
        }
        /// Demo only: a style that is not saved to Settings.
        static var override: Style?
        static var current: Style { override ?? Style(rawValue: UserDefaults.standard.string(forKey: "islandStyle") ?? "") ?? .automatic }
    }

    struct Geometry: Equatable {
        /// Notch style: flush with the top edge, flared corners. Otherwise a pill.
        var notch = false
        /// The screen has a real notch: idle merges into it instead of fading out.
        var hardwareNotch = false
        var notchWidth: CGFloat = 185
        /// Height of the top row (the notch, or the compact pill).
        var rowHeight: CGFloat = 32
        /// Pill only: distance from the top of the screen (menu bar + 6 pt).
        var topInset: CGFloat = 0
    }

    /// Size and corners of the shape for one state.
    struct Spec: Equatable {
        var w: CGFloat, h: CGFloat, r: CGFloat, topR: CGFloat, flare: CGFloat, opacity: Double
        var expanded: Bool
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var geo = Geometry()
    @Published private(set) var chat: String?
    @Published private(set) var chunks: [String] = []
    @Published private(set) var chunkStarts: [Double] = []
    @Published private(set) var speakStart = Date()
    @Published private(set) var errorTitle = ""
    @Published private(set) var errorDetail = ""
    @Published private(set) var hint = Island.defaultHint
    @Published private(set) var listenStart = Date()
    @Published private(set) var shakeCount = 0
    @Published private(set) var reduceMotion = false
    /// Sending: the chat it goes to, and the countdown during which "cancel" stops it.
    @Published private(set) var sendTarget = ""
    /// Shown next to the check: "Queued for orchard" (HM-1364).
    @Published private(set) var doneNote = ""
    @Published private(set) var sendStart = Date()
    @Published private(set) var sendSeconds = 2.0

    static let defaultHint = "Say \u{201C}done\u{201D} when you\u{2019}re finished"

    /// Levels for the bars, read every frame (not published: no SwiftUI updates).
    let feed = BarFeed()

    private var panel: IslandPanel?
    private var source: String?
    private var wakeAt = Date.distantPast
    private var pending: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: Wiring

    /// Follows the conductor: its listening (ask answers, voice learning) and
    /// transcribing/publishing phases, and the line to read while learning.
    func attach() {
        let c = Conductor.shared
        c.$phase.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] p in
            guard let self else { return }
            switch p {
            case .listening: self.listening(source: "ask")
            case .transcribing, .publishing: if self.mode != .idle || p == .publishing { self.thinking() }
            case .idle: if self.mode == .listening && self.source == "ask" { self.idle() }
            case .speaking: break
            }
        }.store(in: &cancellables)
        c.$voiceLine.receive(on: DispatchQueue.main).sink { [weak self] line in
            self?.hint = line ?? Island.defaultHint
        }.store(in: &cancellables)
    }

    // MARK: Inputs

    /// "Hey Claude" heard: ears grow out of the notch.
    func wake(source: String) {
        self.source = source
        wakeAt = Date()
        feed.reset(conductor: false)
        go(.wake)
    }

    /// The mic is open for him. Right after a wake the ears stay up a moment first.
    func listening(source: String) {
        if mode == .listening { return }
        if mode == .wake, self.source == source || source == "ask" {
            let left = 0.7 - Date().timeIntervalSince(wakeAt)
            if left > 0 {
                pending?.cancel()
                pending = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(left * 1e9))
                    guard let self, !Task.isCancelled, self.mode == .wake else { return }
                    self.enterListening(source)
                }
                return
            }
        }
        enterListening(source)
    }

    private func enterListening(_ s: String) {
        source = s
        feed.reset(conductor: s == "ask")
        listenStart = Date()
        go(.listening)
    }

    /// Mic level 0...1 from the Hey Claude listener (the ask recorder is read directly).
    func micLevel(_ v: Float, source: String?) {
        guard source == nil || source == self.source else { return }
        feed.mic = v
    }

    /// His turn ended, or Needs You is transcribing / publishing / waiting on the agent.
    func thinking() { go(.thinking) }

    /// Needs You starts speaking: orange, chat name, the current sentence.
    func claudeSpeaks(_ text: String, duration: Double, envelope: [Float], chat name: String? = nil) {
        chat = name ?? Self.chatName(Conductor.shared.current)
        let c = Subtitles.chunks(text, max: 54)
        let total = Double(max(1, c.reduce(0) { $0 + $1.count }))
        var starts: [Double] = [], acc = 0.0
        for x in c { starts.append(acc / total * duration); acc += Double(x.count) }
        chunks = c
        chunkStarts = starts
        speakStart = Date()
        feed.envelope = envelope
        feed.speakStart = speakStart
        feed.reset(conductor: false)
        source = nil
        go(.speaking)
    }

    /// Playback ended. What comes next (listening, done) usually follows at once;
    /// if nothing does, fold back.
    func claudeDone() {
        guard mode == .speaking else { return }
        feed.envelope = []
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.mode == .speaking else { return }
            self.go(.idle)
        }
    }

    /// Finished well: a check, then it folds back in. Never pops up from idle.
    func done() {
        guard mode != .idle, mode != .error else { return }
        doneNote = ""
        go(.done)
    }

    /// A voice message waits in a chat's inbox until its next tool call or turn end.
    func queued(for name: String) {
        guard Subtitles.enabled else { return }
        doneNote = "Queued for " + name
        go(.done, retrigger: true)
    }

    /// One line of cause, one line of fix.
    func error(_ title: String, _ detail: String) {
        errorTitle = title
        errorDetail = detail
        go(.error, retrigger: true)
    }

    func idle() { go(.idle) }

    /// A Hey Claude command is about to be typed into a chat: its name and a ring that
    /// runs out over the countdown. Then `done()` (sent), `error` (not sent) or
    /// `sendCancelled()`. With "Subtitles on Screen" off nothing new appears.
    func sending(to target: String, seconds: Double) {
        guard Subtitles.enabled else { return }
        sendTarget = target
        sendStart = Date()
        sendSeconds = seconds
        go(.sending, retrigger: true)
    }

    /// Cancelled during the countdown: fold back in.
    func sendCancelled() {
        if mode == .sending { go(.idle) }
    }

    /// Do not disturb is on and he pressed the turn shortcut: a moon, briefly.
    /// Never covers his own live turn or Needs You speaking.
    func moon() {
        guard [.idle, .done, .error, .thinking, .moon].contains(mode) else { return }
        go(.moon, retrigger: true)
    }

    /// Maps what a conversation or a Hey Claude command ended with.
    func finished(_ status: String, error: String?, errorTitle: String? = nil) {
        switch status {
        case "answered", "interrupted": thinking() // Claude works on the answer
        case "spoken", "done", "sent": done()
        case "queued": break // "Queued for …" is already showing
        case "error":
            let e = error ?? "Something went wrong."
            let mic = e.localizedCaseInsensitiveContains("microphone") || e.localizedCaseInsensitiveContains("mic ")
            self.error(errorTitle ?? (mic ? "Can\u{2019}t hear you" : "Something went wrong"), Self.oneLine(e))
        default:
            if mode != .error { idle() }
        }
    }

    // MARK: State machine

    private static let base: [Mode: (w: CGFloat, h: CGFloat, r: CGFloat)] = [
        .idle: (185, 32, 10), .wake: (300, 32, 12), .listening: (420, 96, 26), .thinking: (310, 32, 12),
        .sending: (340, 32, 12),
        .speaking: (440, 96, 26), .done: (260, 32, 12), .error: (380, 80, 24), .moon: (300, 32, 12),
    ]

    func spec(_ m: Mode) -> Spec {
        let b = (m == .done && !doneNote.isEmpty) ? Self.base[.sending]! : Self.base[m]!
        let expanded = b.h > 40
        if geo.notch {
            let dw = max(0, geo.notchWidth - 185)
            return Spec(w: m == .idle ? geo.notchWidth : b.w + dw,
                        h: expanded ? b.h - 32 + geo.rowHeight : geo.rowHeight,
                        r: b.r, topR: 0, flare: expanded ? 12 : 6,
                        opacity: m == .idle && !geo.hardwareNotch ? 0 : 1, expanded: expanded)
        }
        return Spec(w: m == .idle ? 120 : b.w, h: expanded ? b.h - 14 : 32, r: b.r,
                    topR: expanded ? b.r : 16, flare: 0, opacity: m == .idle ? 0 : 1, expanded: expanded)
    }

    private func area(_ m: Mode) -> CGFloat { let b = Self.base[m]!; return b.w * b.h }

    private func go(_ next: Mode, retrigger: Bool = false) {
        // Same state again: keep its timer. Cancelling it here (before this guard) left
        // a state with no way out, e.g. "thinking" set twice never folded back (HM-1410).
        guard next != mode || retrigger else { if next != .idle { show() }; return }
        pending?.cancel(); pending = nil
        if next != .idle { hideTask?.cancel(); hideTask = nil; show() }
        let grow = area(next) >= area(mode)
        let anim: Animation = reduceMotion ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)
            : grow ? .interpolatingSpring(stiffness: 380, damping: 26) : .interpolatingSpring(stiffness: 500, damping: 45)
        withAnimation(anim) { mode = next }
        switch next {
        case .idle:
            source = nil
            feed.envelope = []
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000) // the shrink settles, the fade ends
                guard let self, !Task.isCancelled, self.mode == .idle else { return }
                self.panel?.orderOut(nil)
            }
        case .done: after(doneNote.isEmpty ? 1.1 : 2.2) { $0.go(.idle) }
        case .moon: after(1.6) { $0.go(.idle) }
        case .error:
            if !reduceMotion { shakeCount += 1 }
            after(4) { $0.go(.idle) }
        case .sending: after(sendSeconds + 4) { $0.go(.idle) } // safety net: delivery normally ends it
        case .thinking: after(15) { $0.go(.idle) }          // the agent may work for minutes: don't sit there
        case .wake: after(4) { $0.go(.idle) }               // no command followed
        case .listening: after(150) { $0.go(.idle) }        // safety net
        case .speaking: after(120) { $0.go(.idle) }         // safety net
        }
    }

    private func after(_ s: Double, _ f: @escaping @MainActor (Island) -> Void) {
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
            guard let self, !Task.isCancelled else { return }
            f(self)
        }
    }

    // MARK: Panel

    /// Puts the panel on screen, placed from the screen every time (HM-1410): the
    /// mouse's screen when it appears, its own screen while it stays up.
    private func show() {
        let p = panel ?? makePanel()
        let appearing = !p.isVisible
        if appearing { reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        guard let screen = (appearing ? mouseScreen : p.screen ?? mouseScreen) ?? NSScreen.main else { return }
        place(p, on: screen)
        if appearing { p.orderFrontRegardless() }
    }

    private func place(_ p: IslandPanel, on screen: NSScreen) {
        let (g, centerX) = Self.geometry(for: screen, style: Style.current)
        if g != geo {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { geo = g }
        }
        let f = IslandLayout.panelFrame(screen: screen.frame, centerX: centerX,
                                        size: CGSize(width: 640, height: g.topInset + 150), scale: screen.backingScaleFactor)
        if p.frame != f {
            p.setFrame(f, display: true)
            p.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Screens added, removed, rearranged or rescaled: place it again.
    @objc private func screensChanged() {
        guard let p = panel, p.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = p.screen ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        place(p, on: screen)
    }

    static func geometry(for screen: NSScreen, style: Style) -> (Geometry, CGFloat) {
        let f = screen.frame
        let hw = screen.safeAreaInsets.top > 0
        let notchStyle = style == .notch || (style == .automatic && hw)
        let menuBar = f.maxY - screen.visibleFrame.maxY
        var g = Geometry()
        var centerX = f.midX
        if hw, let n = IslandLayout.notch(screen: f, leftArea: screen.auxiliaryTopLeftArea,
                                          rightArea: screen.auxiliaryTopRightArea, scale: screen.backingScaleFactor) {
            g.notchWidth = n.width
            centerX = n.centerX
        }
        g.notch = notchStyle
        g.hardwareNotch = hw && notchStyle
        let bar = hw ? screen.safeAreaInsets.top : (menuBar > 10 ? menuBar : 24)
        g.rowHeight = notchStyle ? min(38, bar) : 32
        g.topInset = notchStyle ? 0 : bar + 6
        if !hw { centerX = f.midX }
        return (g, centerX)
    }

    private func makePanel() -> IslandPanel {
        let p = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 150),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // No AppKit show/hide animation (HM-1410). Its scale-and-fade drew a snapshot of
        // the panel at 98 % size: the pill sat a few pixels off, and when the panel came
        // back during a hide it stayed frozen on the old picture ("Claude Code in …",
        // an empty ring) while the real states (speaking, listening) never showed.
        p.animationBehavior = .none
        p.setAccessibilityRole(.group)
        p.setAccessibilityLabel("Needs You status")
        let host = NSHostingView(rootView: IslandView(model: self))
        host.sizingOptions = []
        p.contentView = host
        host.layoutSubtreeIfNeeded()
        panel = p
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        return p
    }

    // MARK: Text

    static func chatName(_ c: Conversation?) -> String? {
        guard let c, c.kind == nil else { return nil }
        if let cwd = c.cwd, !cwd.isEmpty, cwd != NSHomeDirectory() { return URL(fileURLWithPath: cwd).lastPathComponent }
        return c.project
    }

    static func oneLine(_ s: String) -> String {
        let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return first.count > 70 ? String(first.prefix(69)) + "\u{2026}" : first
    }

    // MARK: Demo

    /// `NeedsYou --island-demo`: every state with fake levels, no audio, about 25 s.
    func demo() async {
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        let fake = Task { @MainActor [weak self] in
            let t0 = Date()
            while !Task.isCancelled {
                self?.micLevel(Self.fakeVoice(Date().timeIntervalSince(t0) * 1000, seed: 0.3), source: "demo")
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        defer { fake.cancel() }
        await wait(1.4)
        wake(source: "demo"); await wait(1.0)
        listening(source: "demo"); await wait(4.2)
        thinking(); await wait(1.8)
        sending(to: "orchard", seconds: 2); await wait(2.2)
        done(); await wait(1.4)
        thinking(); await wait(0.8)
        let env = (0..<90).map { Float(Self.fakeVoice(Double($0) * 50, seed: 0.9) * 0.95) }
        claudeSpeaks("Staging is green. Shall I promote it to main?", duration: 4.2, envelope: env, chat: "orchard")
        await wait(4.2)
        claudeDone(); done(); await wait(1.1 + 1.6)
        error("Can\u{2019}t hear you", "No microphone. Check input in Settings."); await wait(2.4)
        idle(); await wait(0.8)
    }

    /// The design's fake voice envelope: syllables inside words inside phrases.
    static func fakeVoice(_ t: Double, seed: Double) -> Float {
        let phrase = sin(t * 0.0011 + 1.2) > -0.8 ? 1.0 : 0.08
        let syl = pow(max(0, sin(t * 0.016 + seed * 3)), 2)
        let word = 0.55 + 0.45 * sin(t * 0.0047 + seed)
        return Float(min(1, phrase * (0.18 + 0.82 * syl * word) + Double.random(in: 0..<0.06)))
    }
}

/// Borderless, never key, allowed to sit over the menu bar.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Bar levels, sampled every frame by the bars themselves.
@MainActor
final class BarFeed {
    var mic: Float = 0
    var envelope: [Float] = []
    var speakStart = Date()
    private var conductor = false
    private(set) var history = [Float](repeating: 0, count: 26)
    private var smooth: Float = 0
    private var lastPush = Date.distantPast

    func reset(conductor: Bool) {
        self.conductor = conductor
        history = [Float](repeating: 0, count: 26)
        smooth = 0; mic = 0
        lastPush = .distantPast
    }

    /// The level right now: the ask recorder, the Hey Claude listener, or the voice.
    func target(speaking: Bool, at date: Date) -> Float {
        if speaking {
            guard !envelope.isEmpty else { return 0 }
            let k = Int(date.timeIntervalSince(speakStart) / Subtitles.envelopeStep)
            return k >= 0 && k < envelope.count ? envelope[k] * 0.95 : 0
        }
        if conductor { return max(0, (Conductor.shared.level - 0.2) / 0.8) }
        return mic
    }

    /// Pushes one value per 1/60 s (so a 120 Hz screen does not run it twice as fast).
    func advance(speaking: Bool, at date: Date) {
        let dt = date.timeIntervalSince(lastPush)
        guard dt >= 1.0 / 62 else { return }
        let steps = lastPush == .distantPast ? 1 : min(26, Int(dt * 60))
        lastPush = date
        let t = target(speaking: speaking, at: date)
        for _ in 0..<max(1, steps) {
            smooth += (t - smooth) * (t > smooth ? 0.6 : 0.25)
            history.removeFirst(); history.append(smooth)
        }
    }
}

// MARK: - Views

private enum Ink {
    static func hex(_ v: UInt32) -> Color { Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255) }
    static let user1 = hex(0xf5f5f7), user2 = hex(0x9ecbff), user3 = hex(0xe8f2ff), user4 = hex(0x7fb4ff)
    static let claude1 = hex(0xd97757), claude2 = hex(0xf0a37f), claude4 = hex(0xffc9a8)
    static let err = hex(0xff8a7a), muted = hex(0x8e8e93), dim = hex(0x6e6e73)
}

/// The island: a shape with animatable corners whose frame springs between sizes.
struct IslandShape: Shape {
    var bottomR: CGFloat
    var topR: CGFloat
    var flare: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(bottomR, AnimatablePair(topR, flare)) }
        set { bottomR = newValue.first; topR = newValue.second.first; flare = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = max(0, min(flare, rect.width / 4))
        let x0 = rect.minX + f, x1 = rect.maxX - f, y0 = rect.minY, y1 = rect.maxY
        let w = max(0, x1 - x0), h = max(0, y1 - y0)
        let br = max(0, min(bottomR, w / 2, h / 2)), tr = max(0, min(topR, w / 2, h / 2))
        if f > 0.01 {
            // Flush with the top edge; concave flares where it meets it.
            p.move(to: CGPoint(x: rect.minX, y: y0))
            p.addLine(to: CGPoint(x: rect.maxX, y: y0))
            p.addQuadCurve(to: CGPoint(x: x1, y: y0 + f), control: CGPoint(x: x1, y: y0))
        } else {
            p.move(to: CGPoint(x: x0 + tr, y: y0))
            p.addLine(to: CGPoint(x: x1 - tr, y: y0))
            p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + tr), radius: tr)
        }
        p.addLine(to: CGPoint(x: x1, y: y1 - br))
        p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - br, y: y1), radius: br)
        p.addLine(to: CGPoint(x: x0 + br, y: y1))
        p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - br), radius: br)
        if f > 0.01 {
            p.addLine(to: CGPoint(x: x0, y: y0 + f))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: y0), control: CGPoint(x: x0, y: y0))
        } else {
            p.addLine(to: CGPoint(x: x0, y: y0 + tr))
            p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + tr, y: y0), radius: tr)
        }
        p.closeSubpath()
        return p
    }
}

private struct BlurFade: ViewModifier {
    var on: Bool
    var blur: Bool
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).blur(radius: on || !blur ? 0 : 4)
    }
}

struct IslandView: View {
    @ObservedObject var model: Island

    private var contentTransition: AnyTransition {
        let reduce = model.reduceMotion
        return .asymmetric(
            insertion: .modifier(active: BlurFade(on: false, blur: !reduce), identity: BlurFade(on: true, blur: !reduce))
                .animation(reduce ? .easeOut(duration: 0.15) : .easeOut(duration: 0.18).delay(0.09)),
            removal: .opacity.animation(.easeIn(duration: 0.12)))
    }

    var body: some View {
        let s = model.spec(model.mode)
        ZStack(alignment: .top) {
            IslandShape(bottomR: s.r, topR: s.topR, flare: s.flare)
                .fill(Color.black)
                .frame(width: s.w + 2 * s.flare, height: s.h)
            // A faint orange light along the bottom edge while Claude talks.
            LinearGradient(colors: [Ink.claude1.opacity(0), Ink.claude1.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                .frame(height: 10)
                .blur(radius: 4)
                .frame(width: s.w, height: s.h, alignment: .bottom)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: s.topR, bottomLeadingRadius: s.r,
                                                  bottomTrailingRadius: s.r, topTrailingRadius: s.topR, style: .circular))
                .opacity(model.mode == .speaking ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: model.mode == .speaking)
            ZStack(alignment: .topLeading) {
                layer(s)
                    .id(model.mode)
                    .transition(contentTransition)
            }
            .frame(width: s.w, height: s.h, alignment: .topLeading)
            .clipped()
        }
        .keyframeAnimator(initialValue: CGFloat(0), trigger: model.shakeCount) { view, x in
            view.offset(x: x)
        } keyframes: { _ in
            LinearKeyframe(0, duration: 0.22)
            CubicKeyframe(-4, duration: 0.084)
            CubicKeyframe(4, duration: 0.084)
            CubicKeyframe(-3, duration: 0.084)
            CubicKeyframe(2, duration: 0.084)
            CubicKeyframe(0, duration: 0.084)
        }
        .opacity(s.opacity)
        .animation(.easeOut(duration: model.reduceMotion ? 0.15 : 0.2), value: s.opacity)
        .padding(.top, model.geo.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    private var rowH: CGFloat { model.geo.notch ? model.geo.rowHeight : 32 }

    @ViewBuilder private func layer(_ s: Island.Spec) -> some View {
        switch model.mode {
        case .idle:
            Color.clear.frame(width: 1, height: 1)
        case .wake:
            ears { RippleOrb(reduce: model.reduceMotion) } right: {
                LevelBars(feed: model.feed, count: 5, height: 14, barWidth: 2.5, gap: 2, warm: false, wake: true, reduce: model.reduceMotion)
            }
        case .listening:
            expanded(s) {
                ears { Orb() } right: { ElapsedTimer(start: model.listenStart) }
            } body: {
                label("Listening", model.hint)
                LevelBars(feed: model.feed, count: 26, height: 28, barWidth: 3, gap: 2, warm: false, wake: false, reduce: model.reduceMotion)
            }
        case .thinking:
            ears { ThinkingDots(reduce: model.reduceMotion) } right: { Shimmer(reduce: model.reduceMotion) }
        case .speaking:
            expanded(s) {
                ears { Orb(warm: true) } right: {
                    Text(model.chat ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.claude2).lineLimit(1)
                }
            } body: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude").font(.system(size: 15, weight: .semibold)).kerning(-0.15).foregroundStyle(Ink.user1)
                    SpokenLine(chunks: model.chunks, starts: model.chunkStarts, start: model.speakStart)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LevelBars(feed: model.feed, count: 26, height: 28, barWidth: 3, gap: 2, warm: true, wake: false, reduce: model.reduceMotion)
            }
        case .sending:
            ears { Orb() } right: {
                Text(model.sendTarget).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.user1)
                    .lineLimit(1).truncationMode(.tail)
                CountdownRing(start: model.sendStart, seconds: model.sendSeconds, reduce: model.reduceMotion)
            }
        case .done:
            ears { Orb() } right: {
                if !model.doneNote.isEmpty {
                    Text(model.doneNote).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.user1)
                        .lineLimit(1).truncationMode(.tail)
                }
                DrawnCheck(reduce: model.reduceMotion)
            }
        case .moon:
            ears {
                Image(systemName: "moon.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.muted)
            } right: {
                Text("Do not disturb").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.muted).lineLimit(1)
            }
        case .error:
            ZStack(alignment: .topLeading) {
                ears { Orb(error: true) } right: { EmptyView() }
                label(model.errorTitle, model.errorDetail, titleColor: Ink.err)
                    .padding(.horizontal, 20)
                    .frame(width: s.w, height: s.h - (model.geo.notch ? rowH + 4 : 32) - 16)
                    .offset(y: model.geo.notch ? rowH + 4 : 32)
            }
        }
    }

    private func ears<L: View, R: View>(@ViewBuilder _ left: () -> L, @ViewBuilder right: () -> R) -> some View {
        HStack(spacing: 6) {
            left()
            Spacer(minLength: 0)
            right()
        }
        .padding(.horizontal, 14)
        .frame(height: rowH)
    }

    private func expanded<E: View, B: View>(_ s: Island.Spec, @ViewBuilder ears: () -> E, @ViewBuilder body: () -> B) -> some View {
        let top = model.geo.notch ? rowH + 8 : 32
        return ZStack(alignment: .topLeading) {
            ears()
            HStack(spacing: 14) { body() }
                .padding(.horizontal, 20)
                .frame(width: s.w, height: max(0, s.h - top - 16))
                .offset(y: top)
        }
    }

    private func label(_ title: String, _ sub: String, titleColor: Color = Ink.user1) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 15, weight: .semibold)).kerning(-0.15).foregroundStyle(titleColor)
            Text(sub).font(.system(size: 12)).foregroundStyle(Ink.muted).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Orb: View {
    var warm = false
    var error = false
    var body: some View {
        let size: CGFloat = error ? 10 : 14
        Circle()
            .fill(error ? AnyShapeStyle(Ink.err) : AnyShapeStyle(RadialGradient(
                stops: warm ? [.init(color: Ink.claude4, location: 0), .init(color: Ink.claude2, location: 0.5), .init(color: Ink.claude1, location: 1)]
                            : [.init(color: Ink.user3, location: 0), .init(color: Ink.user2, location: 0.55), .init(color: Ink.user4, location: 1)],
                center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.95)))
            .frame(width: size, height: size)
            .shadow(color: (error ? Ink.err : warm ? Ink.claude1 : Ink.user2).opacity(error ? 0.5 : warm ? 0.6 : 0.55), radius: 5)
            .frame(width: 14, height: 14)
    }
}

/// The wake orb: a ring ripples out twice, then stops.
private struct RippleOrb: View {
    var reduce: Bool
    @State private var go = false
    var body: some View {
        Orb()
            .background {
                if !reduce {
                    Circle().strokeBorder(Ink.user2, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                        .scaleEffect(go ? 2.6 : 1)
                        .opacity(go ? 0 : 0.9)
                }
            }
            .onAppear {
                guard !reduce else { return }
                withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.9).repeatCount(2, autoreverses: false)) { go = true }
            }
    }
}

private struct ElapsedTimer: View {
    var start: Date
    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { tl in
            let s = max(0, Int(tl.date.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Ink.user1)
        }
    }
}

/// Rounded bars: newest level in the middle, older ones spreading outward.
private struct LevelBars: View {
    let feed: BarFeed
    let count: Int
    let height: CGFloat
    let barWidth: CGFloat
    let gap: CGFloat
    let warm: Bool
    let wake: Bool
    let reduce: Bool

    /// Height of bar `i` of `n` (0...1). Wake: the live level with a little wobble.
    /// Otherwise the design's spread: newest value in the middle, older outward.
    static func scale(_ i: Int, _ n: Int, _ h: [Float], _ t: Double, _ wake: Bool) -> Double {
        if wake {
            let v = Double(h.last ?? 0)
            let wobble = 0.6 + 0.4 * sin(t * 9 + Double(i) * 1.3)
            return 0.2 + 0.8 * min(1, v * wobble)
        }
        let half = Double(n - 1) / 2
        let d = abs(Double(i) - half) / half
        let last = Double(h.count - 1)
        let k = Int((last - d * last).rounded())
        let v = Double(h[k])
        return max(0.1, v * (1 - d * 0.55))
    }

    var body: some View {
        let width = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        TimelineView(.animation(minimumInterval: reduce ? 0.16 : 1.0 / 60)) { tl in
            Canvas { ctx, size in
                let date = tl.date
                feed.advance(speaking: warm, at: date)
                let h = feed.history
                let n = count
                let top = warm ? Ink.claude4 : Ink.user1, bottom = warm ? Ink.claude1 : Ink.user2
                let t = date.timeIntervalSinceReferenceDate
                for i in 0..<n {
                    let s = CGFloat(Self.scale(i, n, h, t, wake))
                    let bh = max(barWidth, size.height * s)
                    let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: (size.height - bh) / 2, width: barWidth, height: bh)
                    let path = Path(roundedRect: rect, cornerRadius: min(2, barWidth / 2))
                    ctx.fill(path, with: .linearGradient(Gradient(colors: [top, bottom]),
                                                         startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                         endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                }
            }
        }
        .frame(width: width, height: height)
    }
}

private struct ThinkingDots: View {
    var reduce: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduce)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let k = reduce ? -1 : Self.bump(t - Double(i) * 0.15)
                    Circle().fill(Ink.user2).frame(width: 5, height: 5)
                        .opacity(reduce ? 0.7 : 0.3 + 0.7 * k)
                        .offset(y: reduce ? 0 : -2 * k)
                }
            }
        }
    }
    /// 0 -> 1 at 40 % -> 0 over 1.2 s, eased.
    static func bump(_ t: Double) -> Double {
        let p = (t.truncatingRemainder(dividingBy: 1.2) + 1.2).truncatingRemainder(dividingBy: 1.2) / 1.2
        let x = p < 0.4 ? p / 0.4 : 1 - (p - 0.4) / 0.6
        return x * x * (3 - 2 * x)
    }
}

private struct Shimmer: View {
    var reduce: Bool
    var body: some View {
        let text = Text("Thinking").font(.system(size: 12, weight: .semibold))
        if reduce {
            text.foregroundStyle(Ink.user1)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { tl in
                let p = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                text.foregroundStyle(.clear)
                    .overlay {
                        GeometryReader { g in
                            LinearGradient(stops: [.init(color: Ink.dim, location: 0), .init(color: Ink.user1, location: 0.45),
                                                   .init(color: Ink.dim, location: 0.7), .init(color: Ink.dim, location: 1)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: g.size.width * 2)
                                .offset(x: g.size.width * (-1 + 2 * p))
                        }
                        .mask(text)
                    }
            }
        }
    }
}

/// The send countdown: a thin ring that empties; "cancel" works until it is gone.
private struct CountdownRing: View {
    var start: Date
    var seconds: Double
    var reduce: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: reduce ? 0.25 : 1.0 / 60)) { tl in
            let left = max(0, 1 - tl.date.timeIntervalSince(start) / max(0.1, seconds))
            ZStack {
                Circle().stroke(Ink.dim.opacity(0.6), lineWidth: 2)
                Circle().trim(from: 0, to: left)
                    .stroke(Ink.user2, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
        }
        .frame(width: 18, height: 18)
    }
}

private struct DrawnCheck: View {
    var reduce: Bool
    @State private var drawn = false
    var body: some View {
        CheckPath()
            .trim(from: 0, to: drawn || reduce ? 1 : 0)
            .stroke(Ink.user2, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            .frame(width: 18, height: 18)
            .onAppear {
                guard !reduce else { return }
                withAnimation(.timingCurve(0.3, 0.7, 0.4, 1, duration: 0.35).delay(0.12)) { drawn = true }
            }
    }
}

private struct CheckPath: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 18
        var p = Path()
        p.move(to: CGPoint(x: 3.5 * k, y: 9.5 * k))
        p.addLine(to: CGPoint(x: 7.1 * k, y: 12.9 * k))
        p.addLine(to: CGPoint(x: 14.5 * k, y: 5 * k))
        return p
    }
}

/// The sentence being spoken, advancing with the audio.
private struct SpokenLine: View {
    var chunks: [String]
    var starts: [Double]
    var start: Date
    var body: some View {
        TimelineView(.periodic(from: start, by: 0.1)) { tl in
            let t = tl.date.timeIntervalSince(start)
            let i = max(0, starts.lastIndex { $0 <= t } ?? 0)
            Text(i < chunks.count ? chunks[i] : "")
                .font(.system(size: 12)).foregroundStyle(Ink.muted)
                .lineLimit(1).truncationMode(.tail)
        }
    }
}
