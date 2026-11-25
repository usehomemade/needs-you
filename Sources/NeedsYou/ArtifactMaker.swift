import Foundation
import NeedsYouShared
import AppKit

enum ArtifactMaker {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func html(title: String, message: String, context: String?, askedAt: Date, cwd: String?) -> String {
        let when = DateFormatter.localizedString(from: askedAt, dateStyle: .medium, timeStyle: .short)
        var contextBlock = ""
        if let c = context, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextBlock = """
            <h2>Details</h2>
            <pre>\(escape(c))</pre>
            """
        }
        let from = cwd.map { " from <code>\(escape($0))</code>" } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { --bg:#fbfbfa; --fg:#1d1d1f; --muted:#6e6e73; --card:#ffffff; --line:#e3e3e6; --code:#f2f2f4; --accent:#0a66d8; }
        @media (prefers-color-scheme: dark) {
          :root { --bg:#161618; --fg:#f2f2f4; --muted:#a1a1a6; --card:#1f1f22; --line:#333338; --code:#26262a; --accent:#5aa2ff; }
        }
        * { box-sizing: border-box; }
        body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
        main { max-width: 720px; margin: 0 auto; padding: 48px 16px 64px; }
        h1 { font-size: 28px; line-height:1.2; margin: 0 0 8px; letter-spacing: -0.01em; }
        .meta { color: var(--muted); font-size: 14px; margin: 0 0 28px; }
        .ask { background: var(--card); border:1px solid var(--line); border-radius: 12px; padding: 18px 20px; font-size: 19px; line-height:1.45; }
        h2 { font-size: 17px; margin: 32px 0 10px; }
        pre { background: var(--code); border-radius: 10px; padding: 14px 16px; white-space: pre-wrap; word-break: break-word; font: 14px/1.5 ui-monospace, "SF Mono", Menlo, monospace; margin:0; }
        code { font: 13px ui-monospace, "SF Mono", Menlo, monospace; }
        p.note { color: var(--muted); font-size: 14px; margin-top: 32px; }
        </style>
        </head>
        <body>
        <main>
        <h1>\(escape(title))</h1>
        <p class="meta">Asked out loud at \(escape(when))\(from). Nobody answered after two tries.</p>
        <div class="ask">\(escape(message))</div>
        \(contextBlock)
        <p class="note">Answer in the agent's session, or run the steps above yourself.</p>
        </main>
        </body>
        </html>
        """
    }

    /// Writes the page and runs `artifact publish`, using the caller's PATH so
    /// the CLI finds node the same way the agent does. Returns the URL.
    static func publish(conversationID: String, title: String, message: String, context: String?,
                        project: String?, askedAt: Date, cwd: String?, env: [String: String]?) async throws -> String {
        let dir = Wire.supportDir.appendingPathComponent("artifacts/\(conversationID)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("index.html")
        try html(title: title, message: message, context: context, askedAt: askedAt, cwd: cwd)
            .write(to: file, atomically: true, encoding: .utf8)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env ?? [:] { environment[k] = v }
        let fallback = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = ([environment["PATH"] ?? ""] + fallback).joined(separator: ":")

        let args = ["artifact", "publish", file.path, "-m", "Needs You: \(title)", "--title", title,
                    "--project", (project?.isEmpty == false ? project! : "needs-you")]
        let output = try await run(args, environment: environment, cwd: cwd)
        if let url = firstURL(output) { return url }

        // The caller's PATH did not work (for example the app started on its own): try a login shell.
        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let shellOut = try await run(["/bin/zsh", "-lic", quoted], environment: environment, cwd: cwd, direct: true)
        if let url = firstURL(shellOut) { return url }
        throw NSError(domain: "NeedsYou", code: 3, userInfo: [NSLocalizedDescriptionKey: "artifact publish failed: \(shellOut.suffix(300))"])
    }

    private static func firstURL(_ s: String) -> String? {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .first { $0.hasPrefix("https://artifacts.") }
    }

    private static func run(_ args: [String], environment: [String: String], cwd: String?, direct: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            if direct {
                p.executableURL = URL(fileURLWithPath: args[0])
                p.arguments = Array(args.dropFirst())
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args
            }
            p.environment = environment
            if let cwd, FileManager.default.fileExists(atPath: cwd) { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
