import Foundation

/// Wire protocol between the `needs-you` CLI and the app: one JSON request
/// line from the CLI, then one JSON response line from the app, over a Unix
/// domain socket that only the local user can reach.
public enum Wire {
    public static let bundleID = "dev.homemade.needs-you"

    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Needs You", isDirectory: true)
    }

    public static var socketPath: String {
        supportDir.appendingPathComponent("needs-you.sock").path
    }
}

public struct Request: Codable {
    public enum Command: String, Codable { case ask, say, done, status, wake = "wake-test", clean = "clean-test", sounds = "play-sounds", stt = "stt-test", tts = "tts-test", stop = "stop-test", turn = "turn-test", voice = "voice-test", register, inbox, chats, clarify = "clarify-test"
        /// Test hook (HM-1433): the intent evaluation set through the real on-device model.
        case intentEval = "intent-eval"
        /// From `needs-you permission-hook` (HM-1369): ask out loud whether to allow a tool call.
        case permission = "permission-ask" }

    public var command: Command
    public var text: String?
    public var title: String?
    public var context: String?
    public var project: String?
    public var conversationID: String?
    /// `say` only: speak and return without listening.
    public var noListen: Bool?
    /// ask: one try, no "Sorry to ask again", no no-answer page; exits 2 right away.
    public var once: Bool?
    /// Caller environment, so the app can run `artifact` the way the agent would.
    public var cwd: String?
    public var env: [String: String]?
    /// register / inbox: the chat this comes from (HM-1364).
    public var chat: ChatUpdate?

    // Test hooks (not in the README for agents).
    public var waitSeconds: Double?
    public var mute: Bool?
    public var inputFile: String?
    public var simulateSilence: Bool?
    public var ttsOut: String?
    /// Feeds an audio file through the real listening path (VAD, pauses, stop words) in real time.
    public var vadFile: String?
    /// wake-test: allow this herdr pane as a target for 10 minutes (no file needed).
    public var armPane: String?
    /// wake-test: parse and route, but do not send.
    public var dryRun: Bool?
    /// wake-test: folder that stands in for ~/Projects and ~ (new-chat tests).
    public var projectsRoot: String?

    public init(command: Command) { self.command = command }
}

public struct Turn: Codable, Hashable {
    public enum Role: String, Codable {
        case agent, user
        /// Older history files used another name for the user's role: anything
        /// that is not "agent" is the user.
        public init(from decoder: Decoder) throws {
            self = try decoder.singleValueContainer().decode(String.self) == "agent" ? .agent : .user
        }
    }
    public var role: Role
    public var text: String
    /// What was heard before cleanup (only when it differs from `text`).
    public var original: String?
    public var at: Date

    public init(role: Role, text: String, original: String? = nil, at: Date = Date()) {
        self.role = role; self.text = text; self.at = at
        self.original = (original == text) ? nil : original
    }
}

public struct Response: Codable {
    /// answered | no_answer | spoken | done | error | status
    public var status: String
    public var conversationID: String?
    public var transcript: String?
    /// The transcript exactly as heard, when the Transcript setting changed it.
    public var transcriptVerbatim: String?
    /// status "interrupted": what Needs You had said when the user said "Stop, Mac".
    public var spokenUntil: String?
    public var turns: [Turn]?
    public var artifactURL: String?
    public var error: String?
    public var queued: Int?
    public var state: String?
    /// tts-test: which voice spoke each part, e.g. ["en=kokoro(af_heart)", "tr=supertonic3(F2)"].
    public var engines: [String]?
    /// chats: the chats Needs You can reach (HM-1364).
    public var chats: [ChatInfo]?
    /// inbox: messages from the user waiting for this chat.
    public var messages: [String]?
    /// permission-ask: allow | always | deny | unclear (HM-1369).
    public var decision: String?

    public init(status: String) { self.status = status }

    enum CodingKeys: String, CodingKey {
        case status, transcript, turns, error, queued, state, engines, chats, messages, decision
        case conversationID = "conversation_id"
        case transcriptVerbatim = "transcript_verbatim"
        case spokenUntil = "spoken_until"
        case artifactURL = "artifact_url"
    }
}

public enum LineIO {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Reads bytes until a newline or EOF.
    public static func readLine(fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return data.isEmpty ? nil : data }
            if byte == 0x0A { return data }
            data.append(byte)
            if data.count > 4_000_000 { return nil }
        }
    }

    public static func writeLine(fd: Int32, _ data: Data) -> Bool {
        var payload = data
        payload.append(0x0A)
        return payload.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

public enum UnixSocket {
    public static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.prefix(buf.count - 1).enumerated() { buf[i] = b }
        }
        return addr
    }

    public static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 { close(fd); return nil }
        return fd
    }
}
