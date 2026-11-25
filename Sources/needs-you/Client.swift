import Foundation
import NeedsYouShared

/// The socket round trip shared by the CLI commands, `needs-you mcp` and `needs-you hook`.
enum Client {
    /// Environment the app may use: where the caller runs and which pane it is in.
    static func callerEnv(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        env.filter { k, _ in
            k == "PATH" || k == "HOME" || k.hasPrefix("CLAUDE") || k == "NVM_DIR" || k == "NODE_PATH"
                || k.hasPrefix("HERDR_") || k == "TMUX" || k == "TMUX_PANE"
        }
    }

    /// Sends one request and returns the raw response line. Starts the app when
    /// `launch` is set and it is not running.
    static func send(_ request: Request, launch: Bool = true) -> Data? {
        var fd = UnixSocket.connect(Wire.socketPath)
        if fd == nil && launch {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-b", Wire.bundleID]
            try? p.run()
            p.waitUntilExit()
            for _ in 0..<50 {
                usleep(200_000)
                if let c = UnixSocket.connect(Wire.socketPath) { fd = c; break }
            }
        }
        guard let sock = fd else { return nil }
        defer { close(sock) }
        guard let body = try? LineIO.encoder.encode(request), LineIO.writeLine(fd: sock, body) else { return nil }
        return LineIO.readLine(fd: sock)
    }

    static func response(_ request: Request, launch: Bool = true) -> Response? {
        send(request, launch: launch).flatMap { try? LineIO.decoder.decode(Response.self, from: $0) }
    }
}
