import Foundation

/// Voice approval for Claude Code permission prompts (HM-1369).
///
/// Claude Code runs the `PermissionRequest` hook (`needs-you permission-hook`)
/// when it is about to show a permission prompt. `PermissionGuard.classify`
/// decides whether the call is worth asking about out loud; anything else gets
/// no answer from the hook, so the normal on-screen prompt shows. The idea of a
/// short risky-command list comes from handsfree-code (guard.ts, MIT); the
/// patterns here are our own.
public enum PermissionGuard {
    public struct Risk: Equatable {
        public enum Kind: String, Equatable { case push, forcePush, gitDestroy, delete, deploy, publish, database, install, root, remote, secrets, system, github, mcp }
        public var kind: Kind
        /// What the agent wants to do, as a verb phrase: "force-push to main".
        public var phrase: String
        public init(_ kind: Kind, _ phrase: String) { self.kind = kind; self.phrase = phrase }
    }

    /// The risky part of a tool call, or nil for "show the normal prompt".
    public static func classify(toolName: String, toolInput: [String: Any]) -> Risk? {
        if toolName == "Bash", let command = toolInput["command"] as? String {
            return classify(command: command)
        }
        if toolName.hasPrefix("mcp__") { return classifyMCP(toolName) }
        return nil
    }

    // MARK: Shell

    public static func classify(command: String) -> Risk? {
        // A script piped into a shell straight from the network.
        if let m = command.firstMatch(#"\b(?:curl|wget)\b[^|;&]*?(https?://[^\s'"|]+)[^|;&]*\|\s*(?:sudo\s+)?(?:ba|z|da)?sh\b"#) {
            return Risk(.install, "run an install script from " + host(m[1]))
        }
        var found: [Risk] = []
        for segment in segments(command) {
            if let r = classify(words: words(segment)) { found.append(r) }
        }
        // The most serious one decides what is said.
        return found.min { rank($0.kind) < rank($1.kind) }
    }

    private static func rank(_ k: Risk.Kind) -> Int {
        let order: [Risk.Kind] = [.forcePush, .gitDestroy, .delete, .database, .deploy, .publish, .secrets, .root, .system, .github, .push, .remote, .install, .mcp]
        return order.firstIndex(of: k) ?? order.count
    }

    /// Splits on `&&`, `||`, `;`, `|` and newlines (outside quotes).
    static func segments(_ command: String) -> [String] {
        var out: [String] = [], cur = ""
        var quote: Character?
        var chars = Array(command)
        var i = 0
        chars.append(" ")
        while i < chars.count - 1 {
            let c = chars[i]
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil } else if c == "\\" && q == "\"" { cur.append(chars[i + 1]); i += 1 }
            } else if c == "'" || c == "\"" {
                quote = c; cur.append(c)
            } else if c == ";" || c == "\n" || c == "|" || (c == "&" && chars[i + 1] == "&") {
                out.append(cur); cur = ""
                if (c == "|" && chars[i + 1] == "|") || c == "&" { i += 1 }
            } else {
                cur.append(c)
            }
            i += 1
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Shell words with quotes removed (no expansion).
    static func words(_ segment: String) -> [String] {
        var out: [String] = [], cur = "", inWord = false
        var quote: Character?
        for c in segment {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c; inWord = true
            } else if c == " " || c == "\t" {
                if inWord { out.append(cur); cur = ""; inWord = false }
            } else {
                cur.append(c); inWord = true
            }
        }
        if inWord { out.append(cur) }
        return out
    }

    private static func classify(words input: [String]) -> Risk? {
        var w = input
        // Leading env assignments, (, wrappers.
        while let first = w.first, first == "(" || first == "{" || first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=.*"#, options: .regularExpression) != nil
                || ["env", "command", "time", "nohup", "exec", "xargs", "caffeinate", "npx", "bunx", "pnpx"].contains(first) {
            w.removeFirst()
            if first == "xargs" { while let f = w.first, f.hasPrefix("-") { w.removeFirst() } }
        }
        guard var tool = w.first else { return nil }
        if tool == "sudo" || tool == "doas" {
            w.removeFirst()
            while let f = w.first, f.hasPrefix("-") { w.removeFirst() }
            if let inner = classify(words: w) { return Risk(inner.kind, inner.phrase + " as root") }
            return Risk(.root, "run " + (w.prefix(2).joined(separator: " ").nonEmpty ?? "a command") + " as root")
        }
        tool = (tool as NSString).lastPathComponent
        let args = Array(w.dropFirst())
        let plain = args.filter { !$0.hasPrefix("-") }
        let has = { (flags: [String]) -> Bool in args.contains { a in flags.contains(a) } }

        switch tool {
        case "git":
            return git(args)
        case "rm":
            let recursive = args.contains { $0 == "--recursive" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R"))) }
            let force = args.contains { $0 == "--force" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f")) }
            guard recursive || (force && plain.contains { $0.contains("*") }) else { return nil }
            let target = plain.first.map(name) ?? "files"
            return Risk(.delete, plain.count > 1 ? "delete \(target) and \(plain.count - 1) more, with everything in them" : "delete \(target) and everything in it")
        case "find":
            if has(["-delete"]) || (args.firstIndex(of: "-exec").map { args.count > $0 + 1 && args[$0 + 1] == "rm" } ?? false) {
                return Risk(.delete, "delete files found with find")
            }
        case "shred", "srm":
            return Risk(.delete, "erase " + (plain.first.map(name) ?? "files"))
        case "dd":
            if args.contains(where: { $0.hasPrefix("of=/dev/") }) { return Risk(.system, "write a disk with dd") }
        case "mkfs", "newfs_apfs", "newfs_hfs":
            return Risk(.system, "format a disk")
        case "diskutil":
            if let s = plain.first, s.lowercased().hasPrefix("erase") || s == "partitionDisk" || s == "zeroDisk" { return Risk(.system, "erase a disk") }
        case "shutdown", "reboot", "halt":
            return Risk(.system, tool == "shutdown" ? "shut the Mac down" : "restart the Mac")
        case "killall", "pkill":
            return Risk(.system, "stop all " + (plain.last.map(name) ?? "matching") + " processes")
        case "launchctl":
            if let s = plain.first, ["unload", "bootout", "remove", "disable"].contains(s) { return Risk(.system, "unload a launch service") }
        case "chmod", "chown":
            if has(["-R"]) { return Risk(.system, "change permissions of everything in " + (plain.last.map(name) ?? "a folder")) }
        case "ssh", "mosh":
            guard let host = sshHost(args) else { return nil }
            return Risk(.remote, "run a command on " + host)
        case "scp", "rsync", "sftp":
            if let remote = plain.last(where: { $0.contains(":") && !$0.hasPrefix("/") }) {
                return Risk(.remote, "copy files to " + String(remote.split(separator: ":").first ?? "a server").split(separator: "@").last.map(String.init)!)
            }
            if tool == "rsync" && has(["--delete"]) { return Risk(.delete, "sync with rsync and delete extra files") }
        // Deploys and releases.
        case "vercel":
            if has(["--prod", "--production"]) || plain.first == "deploy" || plain.first == "promote" || plain.isEmpty { return Risk(.deploy, "deploy with Vercel") }
        case "fly", "flyctl":
            if let s = plain.first, ["deploy", "launch", "destroy", "scale"].contains(s) { return Risk(.deploy, s == "destroy" ? "destroy a Fly app" : "\(s) on Fly") }
        case "wrangler":
            if let s = plain.first, ["deploy", "publish", "delete"].contains(s) || (s == "secret" && plain.count > 1) { return Risk(.deploy, "deploy with Wrangler") }
        case "netlify", "firebase", "serverless", "sls", "railway", "render", "heroku", "amplify":
            if let s = plain.first, ["deploy", "up", "release", "destroy", "remove"].contains(s) || s.hasPrefix("deploy") { return Risk(.deploy, "deploy with \(tool.capitalized)") }
        case "coolify":
            return Risk(.deploy, "change Coolify")
        case "kubectl", "oc":
            if let s = plain.first, ["apply", "delete", "create", "replace", "patch", "scale", "rollout", "drain", "cordon", "edit", "set"].contains(s) {
                return Risk(.deploy, "\(s) in Kubernetes")
            }
        case "helm":
            if let s = plain.first, ["install", "upgrade", "uninstall", "delete", "rollback"].contains(s) { return Risk(.deploy, "\(s) a Helm release") }
        case "terraform", "tofu", "pulumi", "cdk":
            if let s = plain.first, ["apply", "destroy", "up", "deploy", "import"].contains(s) { return Risk(.deploy, "\(s == "up" ? "apply" : s) \(tool == "tofu" ? "OpenTofu" : tool.capitalized) changes") }
        case "docker", "podman":
            if plain.first == "push" { return Risk(.publish, "push a container image") }
            if plain.first == "system", plain.dropFirst().first == "prune" { return Risk(.delete, "prune Docker data") }
            if plain.first == "volume", plain.dropFirst().first == "rm" || plain.dropFirst().first == "prune" { return Risk(.delete, "delete Docker volumes") }
        case "eas":
            if let s = plain.first, ["submit", "update"].contains(s) || plain.prefix(2) == ["build"] && has(["--auto-submit"]) { return Risk(.deploy, "\(s) with EAS") }
        case "fastlane":
            if let s = plain.first, ["release", "deploy", "beta", "upload_to_app_store", "pilot", "deliver"].contains(s) { return Risk(.deploy, "ship with fastlane") }
        case "xcrun":
            if let s = plain.first, s == "altool" || (s == "notarytool" && plain.dropFirst().first == "submit") { return Risk(.publish, "upload to Apple") }
        case "gh":
            return gh(plain)
        case "npm", "pnpm", "yarn", "bun":
            return node(tool, plain, args)
        case "cargo":
            if plain.first == "publish" { return Risk(.publish, "publish a crate") }
            if plain.first == "install" { return Risk(.install, "install " + list(plain.dropFirst()) + " with cargo") }
        case "twine":
            if plain.first == "upload" { return Risk(.publish, "upload a Python package") }
        case "gem":
            if plain.first == "push" { return Risk(.publish, "publish a gem") }
            if plain.first == "install" { return Risk(.install, "install " + list(plain.dropFirst()) + " with gem") }
        case "pod":
            if plain.first == "trunk", plain.dropFirst().first == "push" { return Risk(.publish, "publish a pod") }
        // Databases.
        case "psql", "mysql", "mariadb", "sqlite3", "duckdb", "clickhouse-client", "mongosh", "mongo", "cqlsh":
            if writes(args.joined(separator: " ")) { return Risk(.database, "write to the database with \(tool)") }
        case "redis-cli", "valkey-cli":
            if let s = plain.first(where: { ["flushall", "flushdb", "del", "unlink", "set", "hset", "expire", "rename"].contains($0.lowercased()) }) {
                return Risk(.database, s.lowercased().hasPrefix("flush") ? "wipe Redis" : "write to Redis")
            }
        case "prisma":
            if plain.starts(with: ["migrate", "deploy"]) || plain.starts(with: ["migrate", "reset"]) || plain.starts(with: ["db", "push"]) { return Risk(.database, "change the database schema with Prisma") }
        case "drizzle-kit":
            if plain.first == "push" || plain.first == "migrate" { return Risk(.database, "change the database schema with Drizzle") }
        case "supabase":
            if plain.starts(with: ["db", "push"]) || plain.starts(with: ["db", "reset"]) { return Risk(.database, "change the Supabase database") }
        case "rails", "rake":
            if plain.contains(where: { $0.hasPrefix("db:") && $0 != "db:migrate:status" }) { return Risk(.database, "run a database task") }
        // Installs from the network.
        case "brew":
            if let s = plain.first, ["install", "reinstall", "upgrade", "tap", "uninstall", "remove"].contains(s) {
                return Risk(.install, ["uninstall", "remove"].contains(s) ? "uninstall " + list(plain.dropFirst()) + " with brew" : "\(s == "upgrade" ? "upgrade" : "install") " + list(plain.dropFirst()) + " with brew")
            }
        case "pip", "pip3", "pipx", "uv":
            var p = plain
            if tool == "uv", p.first == "pip" || p.first == "tool" { p.removeFirst() }
            if p.first == "install" { return Risk(.install, "install " + list(p.dropFirst()) + " with \(tool == "pip3" ? "pip" : tool)") }
        case "go":
            if plain.first == "install" { return Risk(.install, "install " + list(plain.dropFirst()) + " with go") }
        case "apt", "apt-get", "dnf", "yum", "pacman", "apk", "mas", "port":
            if let s = plain.first, ["install", "add", "-S"].contains(s) || args.contains("-S") { return Risk(.install, "install " + list(plain.dropFirst()) + " with \(tool)") }
        // Secrets.
        case "infisical":
            if plain.first == "secrets", let s = plain.dropFirst().first, ["set", "delete"].contains(s) { return Risk(.secrets, "\(s == "set" ? "change" : "delete") secrets in Infisical") }
        case "op":
            if plain.count >= 2, ["create", "edit", "delete"].contains(plain[1]) { return Risk(.secrets, "\(plain[1]) a 1Password item") }
        case "security":
            if let s = plain.first, s.hasPrefix("delete-") || s.hasPrefix("add-") { return Risk(.secrets, "change the keychain") }
        case "curl", "http", "xh", "wget":
            let method = args.firstIndex(where: { $0 == "-X" || $0 == "--request" }).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1].uppercased() : nil }
            let joined = args.joined(separator: " ")
            let url = args.first { $0.hasPrefix("http") }
            if joined.range(of: #"/deploy\b|/api/v\d+/deploy|/restart\b"#, options: .regularExpression) != nil {
                return Risk(.deploy, "start a deploy" + (url.map { " on " + host($0) } ?? ""))
            }
            if let m = method, ["DELETE", "PUT", "PATCH", "POST"].contains(m), let u = url, !isLocal(u) {
                return Risk(.remote, "send a \(m) request to " + host(u))
            }
        default:
            break
        }
        return nil
    }

    private static func git(_ input: [String]) -> Risk? {
        var a = input
        // Global options before the subcommand.
        while let f = a.first, f.hasPrefix("-") {
            a.removeFirst()
            if ["-C", "-c", "--git-dir", "--work-tree"].contains(f), !a.isEmpty { a.removeFirst() }
        }
        guard let sub = a.first else { return nil }
        let args = Array(a.dropFirst())
        let plain = args.filter { !$0.hasPrefix("-") }
        switch sub {
        case "push":
            let force = args.contains { ["--force", "-f", "--force-with-lease", "--force-if-includes", "--mirror"].contains($0) || $0.hasPrefix("--force-with-lease=") }
                || plain.dropFirst().contains { $0.hasPrefix("+") }
            let delete = args.contains("--delete") || args.contains("-d") || plain.dropFirst().contains { $0.hasPrefix(":") }
            let refs = plain.dropFirst().map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+:")) }
            let branch = refs.last.map { String($0.split(separator: ":").last ?? Substring($0)) }
            if delete { return Risk(.forcePush, "delete the branch \(branch ?? "") on \(plain.first ?? "the remote")") }
            let target = branch.map { " to \($0)" } ?? (plain.first.map { " to \($0)" } ?? "")
            if args.contains("--tags") { return Risk(.push, "push tags" + target) }
            return force ? Risk(.forcePush, "force-push" + target) : Risk(.push, "push" + (branch.map { " to \(plain.first ?? "origin") \($0)" } ?? target))
        case "reset":
            if args.contains("--hard") { return Risk(.gitDestroy, "throw away local changes with a hard reset") }
        case "clean":
            if args.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f") }) || args.contains("--force") { return Risk(.gitDestroy, "delete untracked files with git clean") }
        case "branch":
            if args.contains("-D") || (args.contains("--delete") && args.contains("--force")) { return Risk(.gitDestroy, "delete the branch " + (plain.last ?? "")) }
        case "checkout":
            if args.contains("--") || plain == ["."] || args.contains("-f") || args.contains("--force") { return Risk(.gitDestroy, "discard local changes") }
        case "restore":
            if !args.contains("--staged") { return Risk(.gitDestroy, "discard local changes") }
        case "stash":
            if plain.first == "drop" || plain.first == "clear" { return Risk(.gitDestroy, "drop stashed changes") }
        case "filter-branch", "filter-repo":
            return Risk(.gitDestroy, "rewrite the git history")
        case "update-ref":
            if args.contains("-d") { return Risk(.gitDestroy, "delete a git ref") }
        case "tag":
            if args.contains("-d") || args.contains("--delete") { return Risk(.gitDestroy, "delete a tag") }
        default:
            break
        }
        return nil
    }

    private static func gh(_ plain: [String]) -> Risk? {
        guard plain.count >= 2 else { return nil }
        let (group, verb) = (plain[0], plain[1])
        switch (group, verb) {
        case ("pr", "merge"): return Risk(.github, "merge a pull request" + (plain.count > 2 ? " number \(plain[2])" : ""))
        case ("repo", "delete"): return Risk(.github, "delete a GitHub repo")
        case ("repo", "archive"): return Risk(.github, "archive a GitHub repo")
        case ("repo", "edit") where plain.contains("--visibility"): return Risk(.github, "change a repo's visibility")
        case ("release", "create"), ("release", "delete"): return Risk(.publish, "\(verb) a GitHub release")
        case ("workflow", "run"), ("run", "rerun"): return Risk(.deploy, "start a GitHub workflow")
        case ("secret", "set"), ("secret", "delete"), ("variable", "set"), ("variable", "delete"): return Risk(.secrets, "change GitHub \(group)s")
        case ("api", _):
            return nil
        default: return nil
        }
    }

    private static func node(_ tool: String, _ plain: [String], _ args: [String]) -> Risk? {
        guard let s = plain.first else { return nil }
        if s == "publish" || (s == "npm" && plain.dropFirst().first == "publish") { return Risk(.publish, "publish a package to npm") }
        if s == "unpublish" || s == "deprecate" { return Risk(.publish, "\(s) a package on npm") }
        let global = args.contains("-g") || args.contains("--global") || plain.starts(with: ["global", "add"])
        let pkgs = plain.dropFirst().filter { $0 != "add" }
        if ["add", "install", "i", "global"].contains(s) && (global || !pkgs.isEmpty) {
            return Risk(.install, "install " + list(pkgs) + (global ? " globally" : "") + " with \(tool)")
        }
        if s == "deploy" || (s == "run" && plain.dropFirst().first.map { $0.hasPrefix("deploy") || $0.hasPrefix("release") } == true) {
            return Risk(.deploy, "run the deploy script")
        }
        return nil
    }

    private static func classifyMCP(_ name: String) -> Risk? {
        let parts = name.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        // mcp__<server>__<tool>: server is parts[1], the tool the rest.
        guard parts.count >= 3 else { return nil }
        let server = parts[1]
        let action = parts.dropFirst(2).joined(separator: " ").lowercased()
        let risky = ["delete", "remove", "drop", "destroy", "deploy", "merge", "publish", "send", "transfer", "pay", "refund", "revoke", "archive", "rotate"]
        guard risky.contains(where: { action.contains($0) }) else { return nil }
        let human = server.replacingOccurrences(of: "-", with: " ")
        return Risk(.mcp, "use \(human) to \(action)")
    }

    // MARK: Helpers

    static func writes(_ sql: String) -> Bool {
        sql.range(of: #"\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|DROP\s+(TABLE|DATABASE|SCHEMA|INDEX|VIEW|USER|ROLE)|TRUNCATE|ALTER\s+(TABLE|DATABASE|ROLE|USER)|CREATE\s+(TABLE|DATABASE|ROLE|USER|INDEX)|GRANT|REVOKE|deleteMany|deleteOne|drop\(|updateMany|insertMany)\b"#,
                  options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func sshHost(_ args: [String]) -> String? {
        var i = 0
        let withValue: Set<String> = ["-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-W", "-b", "-c", "-E", "-e", "-m", "-O", "-Q", "-S", "-w", "-B", "-I"]
        while i < args.count {
            let a = args[i]
            if withValue.contains(a) { i += 2; continue }
            if a.hasPrefix("-") { i += 1; continue }
            return String(a.split(separator: "@").last ?? Substring(a))
        }
        return nil
    }

    private static func host(_ url: String) -> String {
        URL(string: url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "the internet"
    }

    private static func isLocal(_ url: String) -> Bool {
        guard let h = URL(string: url)?.host else { return false }
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasSuffix(".local") || h.hasSuffix(".localhost")
    }

    /// The last part of a path, for speaking.
    private static func name(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if trimmed == "/" { return "the whole disk" }
        if trimmed == "~" || trimmed == "$HOME" { return "the home folder" }
        if trimmed == "." { return "this folder" }
        if trimmed == "*" { return "everything here" }
        return (trimmed as NSString).lastPathComponent
    }

    private static func list<S: Sequence>(_ items: S) -> String where S.Element == String {
        let a = items.filter { !$0.hasPrefix("-") && !$0.isEmpty }
        switch a.count {
        case 0: return "packages"
        case 1: return a[0]
        case 2: return a[0] + " and " + a[1]
        default: return a[0] + ", " + a[1] + " and \(a.count - 2) more"
        }
    }

    // MARK: The spoken question and the hook's answer

    /// "website wants to force-push to main. Allow?"
    public static func question(project: String, risk: Risk) -> String {
        let p = risk.phrase.trimmingCharacters(in: .whitespaces)
        return "\(project) wants to \(p). Allow?"
    }

    /// Short spoken name for the chat: the folder name ("Home" for the home folder).
    public static func projectLabel(cwd: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if trimmed.isEmpty || trimmed == home { return "Home" }
        // Worktrees: ".../repo/.worktrees/<branch>" is the repo.
        let parts = trimmed.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(where: { $0 == ".worktrees" || $0 == "worktrees" }), i > 0 { return parts[i - 1] }
        return parts.last ?? "A chat"
    }

    /// Hides values that look like secrets before the command is shown or stored.
    public static func redact(_ command: String) -> String {
        var s = command
        s = s.subst(#"\b([A-Z][A-Z0-9_]{2,}=)("[^"]*"|'[^']*'|\S+)"#, "$1•••")
        s = s.subst(#"(?i)(--?(?:token|password|passwd|secret|api-?key|key|auth)[= ])("[^"]*"|'[^']*'|\S+)"#, "$1•••")
        s = s.subst(#"(?i)(bearer\s+)\S+"#, "$1•••")
        s = s.subst(#"(?i)(://[^:/\s]+:)[^@\s]+@"#, "$1•••@")
        return s
    }
}

/// What his spoken answer means.
public enum PermissionAnswer: String, Equatable {
    case allow, always, deny, unclear

    public static func parse(_ transcript: String) -> PermissionAnswer {
        var t = " " + transcript.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"[^a-z0-9' ]+"#, with: " ", options: .regularExpression) + " "
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let words = t.split(separator: " ")
        guard !words.isEmpty, words.count <= 12 else { return .unclear }

        func any(_ phrases: [String]) -> Bool { phrases.contains { t.contains(" \($0) ") } }
        // He wants to look first, or did not decide.
        if any(["show me", "on screen", "on the screen", "screen", "keyboard", "let me see", "let me look", "let me check",
                "i'll check", "i'll look", "not sure", "i don't know", "dunno", "what", "why", "wait", "hold on", "maybe",
                "depends", "which", "explain", "repeat", "again please", "say that again"]) { return .unclear }

        let alwaysPhrases = ["always", "don't ask again", "do not ask again", "stop asking", "from now on", "every time"]
        let always = any(alwaysPhrases)
        if always {
            for p in alwaysPhrases { t = t.replacingOccurrences(of: " \(p) ", with: " ") }
        }
        let no = any(["no", "nope", "nah", "deny", "denied", "don't", "dont", "do not", "stop", "cancel", "never", "negative",
                      "reject", "refuse", "abort", "not now", "no way", "hold off", "skip", "not allowed", "decline"])
        let yes = any(["yes", "yeah", "yep", "yup", "ya", "yah", "sure", "allow", "allowed", "approve", "approved", "okay", "ok",
                       "go ahead", "do it", "go for it", "fine", "alright", "all right", "correct", "of course", "please do",
                       "affirmative", "go", "ship it", "push it", "run it", "absolutely", "definitely", "proceed", "accept", "sounds good"])
        if no && (yes || always) { return .unclear }
        if no { return .deny }
        if always { return .always }
        if yes { return .allow }
        return .unclear
    }

    /// What Needs You says after his answer.
    public var closing: String {
        switch self {
        case .allow: return "Okay."
        case .always: return "Okay, and I'll allow that from now on."
        case .deny: return "Okay, I'll say no."
        case .unclear: return "It's on the screen."
        }
    }
}

/// The JSON the hook prints for Claude Code. nil: print nothing (the normal prompt shows).
public enum PermissionHookOutput {
    public static func json(_ answer: PermissionAnswer, transcript: String, suggestions: [Any]?) -> String? {
        var decision: [String: Any]
        switch answer {
        case .allow:
            decision = ["behavior": "allow"]
        case .always:
            decision = ["behavior": "allow"]
            // Claude Code's own "don't ask again" suggestions (allow rules for this project).
            let rules = (suggestions ?? []).compactMap { $0 as? [String: Any] }.filter {
                ($0["type"] as? String) == "addRules" && ($0["behavior"] as? String) == "allow"
            }
            if !rules.isEmpty { decision["updatedPermissions"] = rules }
        case .deny:
            decision = ["behavior": "deny", "message": "The user said no out loud (Needs You): \"\(transcript)\". Do not retry it; ask in the chat if it still matters."]
        case .unclear:
            return nil
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }

    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: self).map { String(self[$0]) } ?? "" }
    }

    func subst(_ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return self }
        return re.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
}
