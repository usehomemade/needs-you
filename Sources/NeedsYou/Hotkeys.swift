import AppKit
import Carbon.HIToolbox
import NeedsYouShared
import SwiftUI

/// Global shortcuts through Carbon's RegisterEventHotKey: no Accessibility or Input
/// Monitoring permission, and the key goes only to Needs You while it is registered.
///
/// - Escape (HM-1353) is registered only while Needs You's voice plays or a voice
///   command counts down before it is sent, so Escape works as usual in every other
///   app the rest of the time.
/// - The turn shortcut (HM-1354, default ⌥⇧Space) is registered all the time; it is
///   the same as saying the wake phrase.
@MainActor
final class Hotkeys: ObservableObject {
    static let shared = Hotkeys()

    private enum ID: UInt32 { case escape = 1, turn = 2, n1 = 11, n2 = 12, n3 = 13, n4 = 14 }
    private static let signature: OSType = 0x4E59_4B59 // "NYKY"

    private var refs: [ID: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    /// Why the turn shortcut is not active ("taken by another app"), for Settings.
    @Published private(set) var turnProblem: String?
    @Published private(set) var turn: KeyCombo? = Hotkeys.storedTurn
    /// True while Escape is registered (test hook and logs).
    private(set) var escapeOn = false
    private var escapeSpeaking = false, escapeSending = false

    static let defaultsKey = "turnShortcut"

    /// nil when cleared; the default until he changes it.
    static var storedTurn: KeyCombo? {
        guard let s = UserDefaults.standard.string(forKey: defaultsKey) else { return .defaultTurn }
        return KeyCombo(stored: s)
    }

    func setUp() {
        installHandler()
        applyTurn()
    }

    /// Changes or clears (nil) the turn shortcut, and saves it.
    func setTurn(_ combo: KeyCombo?) {
        UserDefaults.standard.set(combo?.stored ?? "", forKey: Self.defaultsKey)
        turn = combo
        applyTurn()
    }

    func resetTurn() { setTurn(.defaultTurn) }

    /// While the recorder listens, the current shortcut must reach it, not fire.
    func pauseTurn(_ paused: Bool) {
        if paused { unregister(.turn) } else if refs[.turn] == nil { applyTurn() }
    }

    private func applyTurn() {
        unregister(.turn)
        turnProblem = nil
        guard let combo = turn else { return }
        if let err = register(.turn, combo) {
            turnProblem = err == eventHotKeyExistsErr ? "\(combo.display) is taken by another app. Pick another." : "Could not use \(combo.display) (error \(err))."
            Isolation.note("keys: turn shortcut \(combo.display) not registered (\(err))")
        } else {
            Isolation.note("keys: turn shortcut \(combo.display)")
        }
    }

    /// Escape stops the voice: only while it plays.
    func escapeWhileSpeaking(_ on: Bool) { escapeSpeaking = on; applyEscape() }

    /// Escape cancels a voice command during its countdown.
    func escapeWhileSending(_ on: Bool) { escapeSending = on; applyEscape() }

    private func applyEscape() {
        let on = escapeSpeaking || escapeSending
        guard on != escapeOn else { return }
        if on {
            if let err = register(.escape, .escape) { Isolation.note("keys: Escape not registered (\(err))"); return }
            escapeOn = true
        } else {
            unregister(.escape)
            escapeOn = false
        }
    }

    /// Keys 1 to `count` pick a chat while Needs You asks "which chat?" (HM-1364).
    /// Registered only then, so the digits work as usual the rest of the time.
    func numberKeys(_ count: Int) {
        let codes: [UInt32] = [18, 19, 20, 21] // kVK_ANSI_1 ... 4
        for (i, id) in [ID.n1, .n2, .n3, .n4].enumerated() {
            unregister(id)
            if i < count, let err = register(id, KeyCombo(keyCode: codes[i], modifiers: 0)) {
                Isolation.note("keys: \(i + 1) not registered (\(err))")
            }
        }
    }

    // MARK: Carbon

    private func register(_ id: ID, _ combo: KeyCombo) -> OSStatus? {
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return status == noErr ? OSStatus(eventInternalErr) : status }
        refs[id] = ref
        return nil
    }

    private func unregister(_ id: ID) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let s = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard s == noErr, hk.signature == Hotkeys.signature else { return OSStatus(eventNotHandledErr) }
            let id = hk.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch ID(rawValue: id) {
                    case .escape:
                        if !VoiceCommands.shared.cancelPendingSend() { Conductor.shared.escapePressed() }
                    case .turn: TurnShortcut.pressed()
                    case .n1, .n2, .n3, .n4: Conductor.shared.numberPressed(Int(id) - 10)
                    case nil: break
                    }
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// The turn shortcut's handler (HM-1354): same as saying the wake phrase.
@MainActor
enum TurnShortcut {
    static func state() -> TurnKey.State {
        let c = Conductor.shared, v = VoiceCommands.shared
        return TurnKey.State(doNotDisturb: DoNotDisturb.shared.on,
                             speaking: c.voicePlaying,
                             commandOpen: v.capturing,
                             answerOpen: c.phase == .listening,
                             working: v.userHasFloor || c.phase == .transcribing || c.phase == .publishing)
    }

    /// Called by the hotkey, and by the silent test hook.
    @discardableResult
    static func pressed() -> TurnKey.Action {
        let action = TurnKey.action(state())
        Isolation.note("keys: turn shortcut -> \(action)")
        switch action {
        case .moon: Island.shared.moon()
        case .stopSpeech: Conductor.shared.stopSpeaking(.voice, thenOpenTurn: true)
        case .endCommand: VoiceCommands.shared.endTurn()
        case .endAnswer: Conductor.shared.endAnswer()
        case .openCommand: Task { await VoiceCommands.shared.openTurn() }
        case .ignore: break
        }
        return action
    }
}

/// Settings → Voice: click, then press the new shortcut. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @ObservedObject private var keys = Hotkeys.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(action: toggle) {
                    Text(recording ? "Type the shortcut…" : (keys.turn?.display ?? "None"))
                        .frame(minWidth: 120)
                }
                if keys.turn != nil, !recording {
                    Button("Clear") { keys.setTurn(nil) }
                }
                if keys.turn != .defaultTurn, !recording {
                    Button("Use \(KeyCombo.defaultTurn.display)") { keys.resetTurn() }
                }
            }
            if let hint { Text(hint).font(.caption).foregroundStyle(.orange) }
            if let p = keys.turnProblem { Text(p).font(.caption).foregroundStyle(.red) }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        hint = nil
        recording = true
        keys.pauseTurn(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = UInt32(event.keyCode)
            let mods = Self.carbon(event.modifierFlags)
            if code == KeyCombo.escapeKey, mods == 0 { stop(); return nil }
            if (code == 51 || code == 117), mods == 0 { keys.setTurn(nil); stop(); return nil }
            let combo = KeyCombo(keyCode: code, modifiers: mods)
            guard combo.isValid else { hint = "Use ⌘, ⌃ or ⌥ with a key (or an F-key)."; return nil }
            keys.setTurn(combo)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { keys.pauseTurn(false) }
        recording = false
    }

    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= KeyCombo.cmd }
        if f.contains(.shift) { m |= KeyCombo.shift }
        if f.contains(.option) { m |= KeyCombo.option }
        if f.contains(.control) { m |= KeyCombo.control }
        return m
    }
}
