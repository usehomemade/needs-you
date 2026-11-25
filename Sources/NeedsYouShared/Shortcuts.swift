import Foundation

/// A global key shortcut: a Carbon virtual key code and Carbon modifier bits
/// (cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096), the format
/// RegisterEventHotKey takes.
public struct KeyCombo: Codable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let cmd: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096
    public static let escapeKey: UInt32 = 53, spaceKey: UInt32 = 49

    /// Escape, no modifiers: registered only while Needs You speaks (HM-1353).
    public static let escape = KeyCombo(keyCode: escapeKey, modifiers: 0)

    /// "Your turn" (HM-1354): ⌥⇧Space. ⌥Space is the ChatGPT launcher on this Mac,
    /// ⌃Space and ⌃⌥Space switch input sources, ⌘Space is Spotlight, ⌘⇧Space 1Password.
    public static let defaultTurn = KeyCombo(keyCode: spaceKey, modifiers: option | shift)

    /// A shortcut needs at least one of ⌘ ⌃ ⌥ (⇧ alone would eat normal typing),
    /// except the function keys, which are free on their own.
    public var isValid: Bool {
        if Self.functionKeys[keyCode] != nil { return true }
        return modifiers & (Self.cmd | Self.control | Self.option) != 0
    }

    /// "⌥⇧Space", in the order macOS menus use: ⌃ ⌥ ⇧ ⌘.
    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? Self.functionKeys[keyCode] ?? "Key \(keyCode)")
    }

    /// "49:2560", as kept in UserDefaults.
    public var stored: String { "\(keyCode):\(modifiers)" }

    public init?(stored: String) {
        let p = stored.split(separator: ":").compactMap { UInt32($0) }
        guard p.count == 2 else { return nil }
        self.init(keyCode: p[0], modifiers: p[1])
    }

    static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static let keyNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K",
        37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U",
        9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 42: "\\", 43: ",", 47: ".", 44: "/", 50: "`",
    ]
}

/// What the "your turn" shortcut does, from what Needs You is doing (HM-1354).
public enum TurnKey {
    public struct State: Equatable {
        public var doNotDisturb = false
        /// Needs You's voice is playing.
        public var speaking = false
        /// A Hey Claude command is being recorded (after the wake phrase or the shortcut).
        public var commandOpen = false
        /// The mic is open for his answer to an ask or say.
        public var answerOpen = false
        /// His command is being transcribed, routed or sent, or an answer transcribed.
        public var working = false
        public init(doNotDisturb: Bool = false, speaking: Bool = false, commandOpen: Bool = false, answerOpen: Bool = false, working: Bool = false) {
            self.doNotDisturb = doNotDisturb; self.speaking = speaking; self.commandOpen = commandOpen
            self.answerOpen = answerOpen; self.working = working
        }
    }

    public enum Action: Equatable {
        /// Do not disturb: nothing happens but the moon on the island.
        case moon
        /// Cut Needs You off and give him the floor.
        case stopSpeech
        /// End the command he is saying, like "done".
        case endCommand
        /// End his answer to an ask, like "done".
        case endAnswer
        /// Open a Hey Claude command, as if he had said the wake phrase.
        case openCommand
        /// Busy with what he just said: ignore the press.
        case ignore
    }

    public static func action(_ s: State) -> Action {
        if s.doNotDisturb { return .moon }
        if s.speaking { return .stopSpeech }
        if s.commandOpen { return .endCommand }
        if s.answerOpen { return .endAnswer }
        if s.working { return .ignore }
        return .openCommand
    }
}

/// How a spoken turn ended early (HM-1353).
public enum SpeechStop: String, Equatable {
    /// "Stop, Claude" or the turn shortcut: he takes the floor and gets listened to.
    case voice
    /// Escape: quiet now, nothing more. An open conversation ends.
    case escape
    /// The menu's Stop.
    case menu

    /// After this stop, does Needs You listen for what he says next?
    public var listensAfter: Bool { self != .escape }
}
