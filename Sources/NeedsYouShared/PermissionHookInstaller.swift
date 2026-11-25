import Foundation

/// Adds and removes the voice permission hook (HM-1369) in `~/.claude/settings.json`.
///
/// JSON has no comments, so "the block" is one hook entry under
/// `hooks.PermissionRequest` whose command ends in `# needs-you:permission-voice`.
/// Only that entry is ever changed; the rest of the file keeps its keys in
/// order and its formatting (Claude Code writes `JSON.stringify(x, null, 2)`).
/// Before every change the file is copied to `settings.json.needs-you-backup`.
/// `NEEDS_YOU_CLAUDE_DIR` points it at a test folder.
public struct PermissionHookInstaller {
    public static let marker = "# needs-you:permission-voice"
    public static let event = "PermissionRequest"
    public static let matcher = "Bash|mcp__.*"
    /// Claude Code stops waiting for the hook after this; the hook gives up earlier.
    public static let timeout = 60

    public let dir: URL
    public init(dir: URL) { self.dir = dir }

    public var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    public var backupURL: URL { dir.appendingPathComponent("settings.json.needs-you-backup") }

    public static func command(cli: String) -> String {
        "'\(cli.replacingOccurrences(of: "'", with: "'\\''"))' permission-hook \(marker)"
    }

    /// The entry that gets added, as it will appear in settings.json.
    public static func entry(cli: String) -> JSONValue {
        .object([
            ("matcher", .string(matcher)),
            ("hooks", .array([.object([
                ("type", .string("command")),
                ("command", .string(command(cli: cli))),
                ("timeout", .number(String(timeout))),
            ])])),
        ])
    }

    /// What Settings shows before he agrees.
    public static func preview(cli: String) -> String {
        let wrapped = JSONValue.object([("hooks", .object([(event, .array([entry(cli: cli)]))]))])
        return wrapped.serialized()
    }

    public enum Failure: LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            switch self { case .unreadable(let why): return "settings.json could not be read, so nothing was changed: \(why)" }
        }
    }

    // MARK: State

    /// The installed command, if the entry is there.
    public func installedCommand() -> String? {
        guard let root = try? load(), let hooks = root["hooks"], let list = hooks[Self.event], case .array(let groups) = list else { return nil }
        for g in groups {
            guard case .array(let hs)? = g["hooks"] else { continue }
            for h in hs { if case .string(let c)? = h["command"], c.contains(Self.marker) { return c } }
        }
        return nil
    }

    public var isInstalled: Bool { installedCommand() != nil }

    // MARK: Changes

    /// Adds the entry (or updates it when the app moved). Returns false when nothing changed.
    @discardableResult
    public func install(cli: String) throws -> Bool {
        if installedCommand() == Self.command(cli: cli) { return false }
        var root = try load() ?? .object([])
        root = Self.removingEntry(root)
        var hooks = root["hooks"] ?? .object([])
        var list = hooks[Self.event] ?? .array([])
        if case .array(var a) = list { a.append(Self.entry(cli: cli)); list = .array(a) } else { list = .array([Self.entry(cli: cli)]) }
        hooks[Self.event] = list
        root["hooks"] = hooks
        try save(root)
        return true
    }

    /// Takes the entry out; empty `PermissionRequest` / `hooks` it leaves behind go too.
    @discardableResult
    public func remove() throws -> Bool {
        guard isInstalled, let root = try load() else { return false }
        try save(Self.removingEntry(root))
        return true
    }

    static func removingEntry(_ root: JSONValue) -> JSONValue {
        guard var hooks = root["hooks"], case .array(let groups)? = hooks[event] else { return root }
        var kept: [JSONValue] = []
        for var g in groups {
            if case .array(let hs)? = g["hooks"] {
                let rest = hs.filter { h in
                    if case .string(let c)? = h["command"] { return !c.contains(marker) }
                    return true
                }
                if rest.isEmpty && rest.count != hs.count { continue }
                g["hooks"] = .array(rest)
            }
            kept.append(g)
        }
        var root = root
        if kept.isEmpty { hooks[event] = nil } else { hooks[event] = .array(kept) }
        if case .object(let o) = hooks, o.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        return root
    }

    private func load() throws -> JSONValue? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let text: String
        do { text = try String(contentsOf: settingsURL, encoding: .utf8) } catch { throw Failure.unreadable(error.localizedDescription) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        do { return try JSONValue.parse(text) } catch { throw Failure.unreadable(error.localizedDescription) }
    }

    private func save(_ root: JSONValue) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = settingsURL.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.copyItem(at: target, to: backupURL)
        }
        try Data((root.serialized() + "\n").utf8).write(to: target, options: .atomic)
    }
}

/// JSON that keeps the order of object keys and the text of numbers, so a
/// settings file round-trips byte for byte.
public indirect enum JSONValue: Equatable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.array(let x), .array(let y)): return x == y
        case (.string(let x), .string(let y)), (.number(let x), .number(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let o) = self else { return nil }
            return o.first { $0.0 == key }?.1
        }
        set {
            guard case .object(var o) = self else { return }
            if let i = o.firstIndex(where: { $0.0 == key }) {
                if let v = newValue { o[i].1 = v } else { o.remove(at: i) }
            } else if let v = newValue {
                o.append((key, v))
            }
            self = .object(o)
        }
    }

    // MARK: Writing (the same text as JSON.stringify(value, null, 2))

    public func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent), inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let o):
            if o.isEmpty { return "{}" }
            return "{\n" + o.map { inner + Self.quote($0.0) + ": " + $0.1.serialized(indent: indent + 1) }.joined(separator: ",\n") + "\n" + pad + "}"
        case .array(let a):
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { inner + $0.serialized(indent: indent + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .string(let s): return Self.quote(s)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    // MARK: Reading

    public struct ParseError: LocalizedError {
        public var offset: Int
        public var errorDescription: String? { "invalid JSON near character \(offset)" }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(Array(text.unicodeScalars))
        p.skip()
        let v = try p.value()
        p.skip()
        guard p.i == p.s.count else { throw ParseError(offset: p.i) }
        return v
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func skip() { while i < s.count, [" ", "\n", "\r", "\t"].contains(s[i]) { i += 1 } }
        func fail() -> ParseError { ParseError(offset: i) }

        mutating func value() throws -> JSONValue {
            guard i < s.count else { throw fail() }
            switch s[i] {
            case "{":
                i += 1; skip()
                var o: [(String, JSONValue)] = []
                if i < s.count, s[i] == "}" { i += 1; return .object(o) }
                while true {
                    skip()
                    guard i < s.count, s[i] == "\"" else { throw fail() }
                    let k = try string()
                    skip()
                    guard i < s.count, s[i] == ":" else { throw fail() }
                    i += 1; skip()
                    o.append((k, try value()))
                    skip()
                    guard i < s.count else { throw fail() }
                    if s[i] == "," { i += 1; continue }
                    if s[i] == "}" { i += 1; return .object(o) }
                    throw fail()
                }
            case "[":
                i += 1; skip()
                var a: [JSONValue] = []
                if i < s.count, s[i] == "]" { i += 1; return .array(a) }
                while true {
                    skip()
                    a.append(try value())
                    skip()
                    guard i < s.count else { throw fail() }
                    if s[i] == "," { i += 1; continue }
                    if s[i] == "]" { i += 1; return .array(a) }
                    throw fail()
                }
            case "\"": return .string(try string())
            case "t": try word("true"); return .bool(true)
            case "f": try word("false"); return .bool(false)
            case "n": try word("null"); return .null
            default:
                let start = i
                while i < s.count, "+-0123456789.eE".unicodeScalars.contains(s[i]) { i += 1 }
                guard i > start else { throw fail() }
                var n = ""; n.unicodeScalars.append(contentsOf: s[start..<i])
                guard Double(n) != nil else { throw fail() }
                return .number(n)
            }
        }

        mutating func word(_ w: String) throws {
            for c in w.unicodeScalars {
                guard i < s.count, s[i] == c else { throw fail() }
                i += 1
            }
        }

        mutating func string() throws -> String {
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]; i += 1
                if c == "\"" { return String(out) }
                guard c == "\\" else { out.append(c); continue }
                guard i < s.count else { throw fail() }
                let e = s[i]; i += 1
                switch e {
                case "\"": out.append("\""); case "\\": out.append("\\"); case "/": out.append("/")
                case "n": out.append("\n"); case "r": out.append("\r"); case "t": out.append("\t")
                case "b": out.append("\u{08}"); case "f": out.append("\u{0C}")
                case "u":
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), i + 1 < s.count, s[i] == "\\", s[i + 1] == "u" {
                        i += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let u = Unicode.Scalar(code) else { throw fail() }
                    out.append(u)
                default: throw fail()
                }
            }
            throw fail()
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= s.count else { throw fail() }
            var t = ""; t.unicodeScalars.append(contentsOf: s[i..<i + 4])
            guard let v = UInt32(t, radix: 16) else { throw fail() }
            i += 4
            return v
        }
    }
}
