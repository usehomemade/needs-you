@testable import NeedsYouShared
import XCTest

final class PermissionGuardTests: XCTestCase {
    private func phrase(_ command: String) -> String? {
        PermissionGuard.classify(command: command)?.phrase
    }

    func testRiskyCommands() {
        let cases: [(String, PermissionGuard.Risk.Kind, String)] = [
            ("git push origin main", .push, "push to origin main"),
            ("git push", .push, "push"),
            ("git push --force origin main", .forcePush, "force-push to main"),
            ("git push -f", .forcePush, "force-push"),
            ("git push origin +main", .forcePush, "force-push to main"),
            ("git push --force-with-lease origin feature/x", .forcePush, "force-push to feature/x"),
            ("git push origin --delete old-branch", .forcePush, "delete the branch old-branch on origin"),
            ("cd ~/Projects/app && git push origin next", .push, "push to origin next"),
            ("git -C /tmp/repo push origin main", .push, "push to origin main"),
            ("git reset --hard HEAD~3", .gitDestroy, "throw away local changes with a hard reset"),
            ("git clean -fdx", .gitDestroy, "delete untracked files with git clean"),
            ("git branch -D wip", .gitDestroy, "delete the branch wip"),
            ("rm -rf build/", .delete, "delete build and everything in it"),
            ("rm -rf node_modules dist", .delete, "delete node_modules and 1 more, with everything in them"),
            ("sudo rm -rf /", .delete, "delete the whole disk and everything in it as root"),
            ("rm -r ~/Library/Caches/foo", .delete, "delete foo and everything in it"),
            ("rm -f *.log", .delete, "delete *.log and everything in it"),
            ("find . -name '*.tmp' -delete", .delete, "delete files found with find"),
            ("vercel --prod", .deploy, "deploy with Vercel"),
            ("fly deploy", .deploy, "deploy on Fly"),
            ("kubectl apply -f k8s/", .deploy, "apply in Kubernetes"),
            ("terraform apply -auto-approve", .deploy, "apply Terraform changes"),
            ("curl -s -X POST https://hooks.example.com/api/v1/deploy?uuid=abc", .deploy, "start a deploy on hooks.example.com"),
            ("npm publish", .publish, "publish a package to npm"),
            ("docker push ghcr.io/acme/app:latest", .publish, "push a container image"),
            ("gh pr merge 42 --squash", .github, "merge a pull request number 42"),
            ("gh repo delete acme/test --yes", .github, "delete a GitHub repo"),
            ("gh release create v1.2.0", .publish, "create a GitHub release"),
            ("psql \"$DATABASE_URL\" -c 'DELETE FROM users WHERE id = 3'", .database, "write to the database with psql"),
            ("sqlite3 app.db \"drop table sessions\"", .database, "write to the database with sqlite3"),
            ("redis-cli FLUSHALL", .database, "wipe Redis"),
            ("npx prisma migrate deploy", .database, "change the database schema with Prisma"),
            ("brew install ffmpeg", .install, "install ffmpeg with brew"),
            ("npm install -g typescript", .install, "install typescript globally with npm"),
            ("pnpm add zod", .install, "install zod with pnpm"),
            ("pip install requests numpy pandas", .install, "install requests, numpy and 1 more with pip"),
            ("curl -fsSL https://bun.sh/install | bash", .install, "run an install script from bun.sh"),
            ("sudo launchctl bootout system/com.example", .system, "unload a launch service as root"),
            ("sudo tee /etc/hosts", .root, "run tee /etc/hosts as root"),
            ("ssh deploy@server.example.com 'systemctl restart app'", .remote, "run a command on server.example.com"),
            ("scp build.tgz host:/srv/", .remote, "copy files to host"),
            ("infisical secrets set KEY=value --env prod", .secrets, "change secrets in Infisical"),
            ("curl -X DELETE https://api.example.com/v1/items/3", .remote, "send a DELETE request to api.example.com"),
        ]
        for (command, kind, want) in cases {
            let r = PermissionGuard.classify(command: command)
            XCTAssertEqual(r?.kind, kind, command)
            XCTAssertEqual(r?.phrase, want, command)
        }
    }

    func testSafeCommandsAreNotAsked() {
        for command in [
            "git status", "git log --oneline -5", "git diff", "git commit -m 'rm -rf in a message'", "git fetch origin",
            "git checkout -b feature", "git pull", "ls -la", "rm file.txt", "rm -f one.log", "npm install", "npm ci", "npm test",
            "pnpm install", "swift build", "swift test", "cat README.md | grep push", "echo 'git push --force'",
            "psql -c 'select count(*) from users'", "curl -s https://example.com", "curl -X POST http://localhost:3000/api",
            "docker ps", "kubectl get pods", "terraform plan", "gh pr view 3", "gh pr create --fill", "brew list",
            "find . -name '*.swift'", "mkdir -p tmp", "vercel ls",
        ] {
            XCTAssertNil(PermissionGuard.classify(command: command), command)
        }
    }

    func testChainsPickTheMostSerious() {
        XCTAssertEqual(PermissionGuard.classify(command: "npm install -g x && git push --force")?.kind, .forcePush)
        XCTAssertEqual(PermissionGuard.classify(command: "git add . && git commit -m wip && git push origin main")?.phrase, "push to origin main")
        XCTAssertEqual(PermissionGuard.classify(command: "FOO=1 BAR=2 rm -rf out")?.kind, .delete)
    }

    func testToolsOtherThanBash() {
        XCTAssertNil(PermissionGuard.classify(toolName: "Edit", toolInput: ["file_path": "/tmp/x"]))
        XCTAssertNil(PermissionGuard.classify(toolName: "WebFetch", toolInput: ["url": "https://x.com"]))
        XCTAssertNil(PermissionGuard.classify(toolName: "mcp__linear__get_issue", toolInput: [:]))
        XCTAssertEqual(PermissionGuard.classify(toolName: "mcp__github__delete_repository", toolInput: [:])?.phrase, "use github to delete repository")
        XCTAssertEqual(PermissionGuard.classify(toolName: "Bash", toolInput: ["command": "git push"])?.kind, .push)
    }

    func testQuestionAndLabel() {
        let r = PermissionGuard.Risk(.forcePush, "force-push to main")
        XCTAssertEqual(PermissionGuard.question(project: "website", risk: r), "website wants to force-push to main. Allow?")
        XCTAssertEqual(PermissionGuard.projectLabel(cwd: "/Users/a/Projects/website", home: "/Users/a"), "website")
        XCTAssertEqual(PermissionGuard.projectLabel(cwd: "/Users/a/Projects/website/.worktrees/hm-1", home: "/Users/a"), "website")
        XCTAssertEqual(PermissionGuard.projectLabel(cwd: "/Users/a", home: "/Users/a"), "Home")
        // The spoken form reads well after the speech cleaner.
        XCTAssertEqual(SpeechText.spoken(PermissionGuard.question(project: "website", risk: PermissionGuard.classify(command: "rm -rf ./build/")!)),
                       "website wants to delete build and everything in it. Allow?")
    }

    func testRedact() {
        XCTAssertEqual(PermissionGuard.redact("infisical secrets set API_KEY=abc123 --env prod"), "infisical secrets set API_KEY=••• --env prod")
        XCTAssertEqual(PermissionGuard.redact("curl -H 'Authorization: Bearer xyz.abc' https://a.com"), "curl -H 'Authorization: Bearer ••• https://a.com")
        XCTAssertEqual(PermissionGuard.redact("psql postgres://me:hunter2@db/x"), "psql postgres://me:•••@db/x")
        XCTAssertEqual(PermissionGuard.redact("op read --token abc"), "op read --token •••")
    }

    // MARK: Answers

    func testAnswers() {
        let cases: [(String, PermissionAnswer)] = [
            ("Yes.", .allow), ("Yeah, go ahead.", .allow), ("Okay.", .allow), ("Sure, do it.", .allow), ("Allow.", .allow),
            ("Yep", .allow), ("Go for it.", .allow), ("All right.", .allow), ("Approved.", .allow), ("Yes please.", .allow),
            ("No.", .deny), ("Nope.", .deny), ("Deny.", .deny), ("Don't.", .deny), ("Stop.", .deny), ("No, don't push that.", .deny),
            ("Cancel.", .deny), ("Not now.", .deny), ("Never.", .deny),
            ("Always.", .always), ("Yes, always.", .always), ("Always allow that.", .always), ("Yes, and don't ask again.", .always),
            ("", .unclear), ("Hmm.", .unclear), ("Wait.", .unclear), ("Show me.", .unclear), ("What does it do?", .unclear),
            ("Yes, no, I mean no.", .unclear), ("Okay no.", .unclear), ("Let me check the screen.", .unclear),
            ("I think we should talk about the deploy plan first before anybody pushes anything at all today.", .unclear),
            ("Maybe.", .unclear), ("Purple.", .unclear),
        ]
        for (heard, want) in cases {
            XCTAssertEqual(PermissionAnswer.parse(heard), want, heard)
        }
    }

    func testHookOutput() throws {
        XCTAssertNil(PermissionHookOutput.json(.unclear, transcript: "hmm", suggestions: nil))

        let allow = try XCTUnwrap(PermissionHookOutput.json(.allow, transcript: "yes", suggestions: nil))
        XCTAssertEqual(allow, #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)

        let deny = try XCTUnwrap(PermissionHookOutput.json(.deny, transcript: "No.", suggestions: nil))
        let d = try JSONSerialization.jsonObject(with: Data(deny.utf8)) as! [String: Any]
        let dd = (d["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        XCTAssertEqual(dd["behavior"] as? String, "deny")
        XCTAssertTrue((dd["message"] as? String ?? "").contains("said no"))

        let suggestions: [Any] = [
            ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "git push:*"]], "behavior": "allow", "destination": "localSettings"],
            ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
        ]
        let always = try XCTUnwrap(PermissionHookOutput.json(.always, transcript: "always", suggestions: suggestions))
        let a = try JSONSerialization.jsonObject(with: Data(always.utf8)) as! [String: Any]
        let ad = (a["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        XCTAssertEqual(ad["behavior"] as? String, "allow")
        let ups = ad["updatedPermissions"] as! [[String: Any]]
        XCTAssertEqual(ups.count, 1)
        XCTAssertEqual(ups[0]["type"] as? String, "addRules")
        // No suggestions: a plain allow.
        XCTAssertEqual(PermissionHookOutput.json(.always, transcript: "always", suggestions: nil), allow)
    }
}
