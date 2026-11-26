import Foundation
import NeedsYouShared

let usage = """
needs-you: ask the user something out loud and get their spoken answer back.

  needs-you ask "<one or two spoken sentences>" [--title T] [--context <file or text>] [--project P]
      Speaks the request once, listens, prints JSON. Waits for its turn if another
      conversation is running. No answer: kept as a voicemail for when the user is
      back (status "voicemail", exit 2). While do not disturb is on, ask and say
      return at once with status "voicemail" (exit 2) and nothing is spoken: go on
      with other work, do not ask again.
      --once: no voicemail (status "no_answer", exit 2 right away when unanswered).
      Exit 0 answered, 2 no answer or voicemail, 1 error.
  needs-you say "<reply>" [--id <conversation_id>] [--no-listen]
      Continues the open conversation: speaks, listens again, prints JSON.
  needs-you done ["<last words>"] [--id <conversation_id>]
      Ends the conversation (optionally saying something first).
  needs-you status
      Prints what the app is doing.
  needs-you chats
      Lists the chats Needs You can reach by voice (JSON).
  needs-you mcp
      Runs the Needs You MCP server on stdio (tools: status, ask, say, done, inbox).
      Add it to an agent once; then the agent's chat can be reached by voice.

Output: {"status":"answered"|"interrupted"|"voicemail"|"no_answer"|"spoken"|"done",
         "conversation_id":..,"transcript":..,"turns":[..],"state":..}
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { print(usage); exit(1) }
args.removeFirst()
if verb == "-h" || verb == "--help" || verb == "help" { print(usage); exit(0) }
if verb == "mcp" { MCPServer().run() }
if verb == "hook" { Hook.run(args) }
if verb == "chats" {
    var r = Request(command: .chats)
    r.cwd = FileManager.default.currentDirectoryPath
    guard let line = Client.send(r, launch: false) else { fail("Needs You is not running") }
    print(String(data: line, encoding: .utf8) ?? "")
    exit(0)
}
// Claude Code PermissionRequest hook (installed from Settings → Agents, HM-1369).
if verb == "permission-hook" { PermissionHookCLI.run() }
// Lowers other audio while he talks; started by the app (HM-1413).
if verb == "duck-hold" { DuckHold.run() }
guard let command = Request.Command(rawValue: verb) else { fail("unknown command: \(verb)\n\n\(usage)") }

var request = Request(command: command)
var positional: [String] = []
var i = 0
func value(_ flag: String) -> String {
    i += 1
    guard i < args.count else { fail("\(flag) needs a value") }
    return args[i]
}
while i < args.count {
    let a = args[i]
    switch a {
    case "--title": request.title = value(a)
    case "--context":
        let v = value(a)
        let expanded = (v as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded),
           let text = try? String(contentsOfFile: expanded, encoding: .utf8) {
            request.context = String(text.prefix(60_000))
        } else {
            request.context = v
        }
    case "--project": request.project = value(a)
    case "--id": request.conversationID = value(a)
    case "--no-listen": request.noListen = true
    case "--once": request.once = true
    // test hooks
    case "--wait": request.waitSeconds = Double(value(a))
    case "--mute": request.mute = true
    case "--input-file": request.inputFile = (value(a) as NSString).expandingTildeInPath
    case "--simulate-silence": request.simulateSilence = true
    case "--arm-pane": request.armPane = value(a)
    case "--transcript": request.context = value(a); if request.dryRun == nil { request.dryRun = true }
    case "--send": request.dryRun = false
    case "--dry-run": request.dryRun = true
    case "--projects-root": request.projectsRoot = (value(a) as NSString).expandingTildeInPath
    case "--vad-file": request.vadFile = (value(a) as NSString).expandingTildeInPath
    case "--tts-out": request.ttsOut = (value(a) as NSString).expandingTildeInPath
    case "-h", "--help": print(usage); exit(0)
    default:
        if a.hasPrefix("--") { fail("unknown flag: \(a)") }
        positional.append(a)
    }
    i += 1
}
request.text = positional.isEmpty ? nil : positional.joined(separator: " ")
if command == .wake, let f = request.text { request.vadFile = (f as NSString).expandingTildeInPath; request.text = nil }
if command == .clean || command == .stt || command == .tts || command == .turn || command == .voice || command == .clarify || command == .intentEval, let m = request.title { request.context = m }
if command == .stt || command == .stop || command == .turn, let f = request.text { request.inputFile = (f as NSString).expandingTildeInPath; request.text = nil }
if (command == .ask || command == .say), (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    fail("\(verb) needs the text to speak")
}
request.cwd = FileManager.default.currentDirectoryPath
request.env = Client.callerEnv()

guard let line = Client.send(request) else { fail("Needs You app is not running and could not be started (open ~/Applications/Needs You.app)") }

guard let response = try? LineIO.decoder.decode(Response.self, from: line) else {
    fail("bad response from Needs You")
}
print(String(data: line, encoding: .utf8) ?? "")
switch response.status {
case "answered", "interrupted", "spoken", "done", "status", "sent", "dry_run", "armed", "measured": exit(0)
case "no_answer", "voicemail": exit(2)
default: exit(1)
}
