import AppKit
import ApplicationServices
import Foundation
import NeedsYouShared

/// Types a voice message into an idle chat in whatever app shows it (HM-1374), through
/// one generic Accessibility path: find the window and tab, focus its text input, paste,
/// press Return, then put back the app, window, field and clipboard he had. No per-app
/// code. The only extra step is for terminal multiplexers (herdr, tmux): their pane is
/// selected with their own focus command first, by the pane id the agent reported.
///
/// Every step is checked; if one fails nothing is typed and the caller keeps the message
/// in the chat's inbox.
@MainActor
enum AXDelivery {
    struct Target {
        var hint: AXMatch.Hint
        /// The agent's process: its parent chain leads to the app that shows it.
        var pid: Int32?
        var pane: PaneRef?
        /// When no process is known (the Claude desktop app).
        var bundleID: String?
    }

    enum Outcome: Equatable {
        case typed(String)      // the app's name
        case notTyped(String)   // why, one line
    }

    static let inputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
    /// How long he must not have touched the keyboard or mouse before focus moves (HM-1374).
    static var idleNeeded: TimeInterval = 1.5
    static var idleMaxWait: TimeInterval = 20
    /// Last run, step by step (for the log and the test hook).
    static var lastLog: [String] = []

    static func log(_ s: String) {
        lastLog.append(s)
        Isolation.note("ax: " + s)
    }

    // MARK: Entry

    static func send(_ text0: String, to target: Target, dryRun: Bool = false) async -> Outcome {
        // One line: a newline inside a paste would send the message by itself in a terminal
        // without bracketed paste, before our checks allow Return. The voice line stays last.
        let text = text0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        var t = target
        let t0 = Date()
        guard AXIsProcessTrusted() else { return .notTyped("Needs You has no Accessibility access") }

        // 1. Where is it: the app, then the window and tab.
        var muxRestore: (() async -> Void)?
        var hostPid: pid_t?
        if let pane = t.pane, let pid = t.pid, !Mux.owns(pane, pid: pid) {
            // An env var inherited from somewhere else (a terminal started from a herdr pane): not its pane.
            log("\(pane.kind.rawValue) pane \(pane.id) does not run the agent, ignored")
            t.pane = nil
        }
        if let pane = t.pane {
            guard let m = await Mux.focus(pane) else { return .notTyped("could not select its \(pane.kind.rawValue) pane") }
            muxRestore = m.restore
            // The pane's own last lines are what its window must show now.
            let lines = m.screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 16 }
            t.hint.texts = Array(lines.suffix(6)) + t.hint.texts
            hostPid = m.clientPid.flatMap(guiApp)?.processIdentifier
            log("\(pane.kind.rawValue) pane \(pane.id) selected, client app pid \(hostPid.map(String.init) ?? "none")")
        }
        if hostPid == nil, let pid = t.pid { hostPid = guiApp(pid)?.processIdentifier }
        if hostPid == nil, let b = t.bundleID { hostPid = NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.processIdentifier }
        guard let hostPid, let app = NSRunningApplication(processIdentifier: hostPid) else {
            await muxRestore?()
            return .notTyped("could not find the app that shows it")
        }
        if isElectron(app) { enableWebAX(app) }
        let axApp = AXUIElementCreateApplication(hostPid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        // A pane switch redraws the terminal a moment later.
        if muxRestore != nil { try? await Task.sleep(nanoseconds: 120_000_000) }
        var places = scan(axApp)
        var scores = places.map { AXMatch.score($0.place, t.hint) }
        // After a pane switch the terminal may still show the old pane for a moment.
        for _ in 0..<6 where muxRestore != nil && AXMatch.pick(scores) == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
            places = scan(axApp)
            scores = places.map { AXMatch.score($0.place, t.hint) }
        }
        for (p, s) in zip(places, scores) { log(String(format: "candidate %.1f \"%@\"%@ %@", s.score, String(p.place.title.prefix(60)), p.tab != nil ? " (tab)" : "", s.why.joined(separator: ", "))) }
        guard let i = AXMatch.pick(scores, alone: muxRestore == nil) else {
            await muxRestore?()
            return .notTyped(places.isEmpty ? "\(app.localizedName ?? "the app") shows no window" : "not sure which \(app.localizedName ?? "") window it is")
        }
        let place = places[i]
        log("picked \"\(place.place.title.prefix(60))\" in \(app.localizedName ?? "?") after \(ms(t0)) ms")
        if dryRun { await muxRestore?(); return .typed(app.localizedName ?? "?") }

        // 2. Wait until he is not typing or moving the mouse.
        let tIdle = Date()
        while hidIdle() < idleNeeded {
            if Date().timeIntervalSince(tIdle) > idleMaxWait { await muxRestore?(); return .notTyped("you kept typing") }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        log("idle after \(ms(tIdle)) ms")

        // 3. What to put back afterwards.
        let saved = Saved.take()
        defer { _ = saved }

        // 4. Focus app, window, tab, input.
        let tFocus = Date()
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(place.window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(place.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        var previousTab: AXUIElement?
        if let tab = place.tab {
            previousTab = place.selectedTab
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
        }
        var window = place.window
        var front = false
        for n in 0..<120 {
            if n == 25 && NSWorkspace.shared.frontmostApplication?.processIdentifier != hostPid {
                // A background app's first AXFrontmost does not always take (seen with a second Ghostty).
                app.activate(options: [.activateAllWindows])
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPid, let fw = element(axApp, kAXFocusedWindowAttribute) {
                // Native window tabs (Terminal, Ghostty) are one AXWindow each: after a tab press the window changes.
                // Native window tabs (Terminal, Ghostty) can be one AXWindow each: after the press, the
                // focused window is the one whose tab bar shows the pressed tab as selected.
                if let tab = place.tab {
                    if tabSelected(tab) || tabTitles(fw, selected: true).contains(place.place.title) { window = fw; front = true; break }
                } else if CFEqual(fw, place.window) { window = fw; front = true; break }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let input = chooseInput(inputs(window), terminal: target.bundleID == nil) else {
            await undo(saved, previousTab, muxRestore, hostPid)
            return .notTyped("not sure which text field in \(app.localizedName ?? "the window") is the chat")
        }
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        // 5. Check before pasting: the right app in front, the right window, a text input in it.
        func verified(_ stage: String) -> String? {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPid else { return "\(stage): another app came to the front" }
            guard let fw = element(axApp, kAXFocusedWindowAttribute) else { return "\(stage): no focused window" }
            guard CFEqual(fw, window) else { return "\(stage): another window took focus (\u{201C}\(title(fw).prefix(40))\u{201D}, \(role(fw)))" }
            guard let fe = element(axApp, kAXFocusedUIElementAttribute) else { return "\(stage): no focused field" }
            guard inputRoles.contains(role(fe)) else { return "\(stage): the focused element is a \(role(fe)), not a text field" }
            guard CFEqual(fe, input) else { return "\(stage): another text field has focus (\u{201C}\(label(fe).prefix(40))\u{201D})" }
            if let w = windowOf(fe), !CFEqual(w, window) { return "\(stage): the focused field is in another window" }
            if let tab = place.tab, !tabSelected(tab), !tabTitles(window, selected: true).contains(place.place.title) { return "\(stage): the tab did not switch" }
            if muxRestore != nil, let p = t.pane, !Mux.isFocused(p) { return "\(stage): the pane lost focus" }
            return nil
        }
        if !front { log("not in front after \(ms(tFocus)) ms") }
        if let why = verified("before paste") {
            await undo(saved, previousTab, muxRestore, hostPid)
            return .notTyped(why)
        }
        if hidIdle() < 0.25 { await undo(saved, previousTab, muxRestore, hostPid); return .notTyped("you started typing") }
        log("focused in \(ms(tFocus)) ms")

        // 6. Paste through a transient clipboard item, check again, Return.
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org markers: clipboard managers skip transient, concealed items.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        board.writeObjects([item])
        key(9, .maskCommand)
        try? await Task.sleep(nanoseconds: 90_000_000)
        if let why = verified("before Return") {
            // The text may be in the field already; without Return it is not sent.
            await undo(saved, previousTab, muxRestore, hostPid)
            return .notTyped(why + " (pasted but not sent)")
        }
        key(36)
        try? await Task.sleep(nanoseconds: 120_000_000)
        log("pasted and sent")

        // 7. Put everything back.
        await undo(saved, previousTab, muxRestore, hostPid)
        log("restored to \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") (was \(saved.app?.localizedName ?? "?")), total \(ms(t0)) ms")
        return .typed(app.localizedName ?? "the app")
    }

    // MARK: Restore

    @MainActor struct Saved {
        var app: NSRunningApplication?
        var window: AXUIElement?
        var focus: AXUIElement?
        var board: [NSPasteboardItem]

        static func take() -> Saved {
            let front = NSWorkspace.shared.frontmostApplication
            var s = Saved(app: front, board: [])
            if let f = front {
                let a = AXUIElementCreateApplication(f.processIdentifier)
                s.window = element(a, kAXFocusedWindowAttribute)
                s.focus = element(a, kAXFocusedUIElementAttribute)
            }
            s.board = (NSPasteboard.general.pasteboardItems ?? []).map { item in
                let c = NSPasteboardItem()
                for t in item.types { if let d = item.data(forType: t) { c.setData(d, forType: t) } }
                return c
            }
            return s
        }
    }

    private static func undo(_ s: Saved, _ previousTab: AXUIElement?, _ mux: (() async -> Void)?, _ hostPid: pid_t) async {
        if let previousTab { AXUIElementPerformAction(previousTab, kAXPressAction as CFString) }
        await mux?()
        if let p = s.app, p.processIdentifier != hostPid {
            let pa = AXUIElementCreateApplication(p.processIdentifier)
            AXUIElementSetAttributeValue(pa, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if let w = s.window { AXUIElementPerformAction(w, kAXRaiseAction as CFString); AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue) }
            if let f = s.focus { AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
            var n = 0
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != p.processIdentifier, n < 80 {
                if n == 20 { p.activate(options: []) }
                if n == 40 {
                    // Raise one of its windows, then ask again.
                    if let w = s.window ?? (attr(pa, kAXWindowsAttribute) as? [AXUIElement])?.first { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
                    AXUIElementSetAttributeValue(pa, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                }
                if n == 60, let url = p.bundleURL {
                    // Last resort: what clicking its Dock icon does.
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
                n += 1
            }
            log("restore front after \(n * 10) ms")
        } else if let w = s.window, let f = s.focus {
            // Same app (he was in it): back to his window and field.
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        // The target has read the paste by now.
        let board = NSPasteboard.general
        board.clearContents()
        if !s.board.isEmpty { board.writeObjects(s.board) }
    }

    // MARK: Reading the screen

    struct Found {
        var window: AXUIElement
        var tab: AXUIElement?          // press this to show it (nil: already showing)
        var selectedTab: AXUIElement?  // what was showing, to switch back
        var input: AXUIElement?
        var place: AXMatch.Place
    }

    /// Every window of the app, and each background tab as its own place.
    static func scan(_ app: AXUIElement) -> [Found] {
        var out: [Found] = []
        for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            var tabs: [AXUIElement] = [], ins: [AXUIElement] = [], text: [String] = []
            var budget = 5000
            walk(w, budget: &budget) { e in
                let r = role(e)
                if isTab(e) { tabs.append(e) }
                if inputRoles.contains(r) {
                    ins.append(e)
                    if let v = attr(e, kAXValueAttribute) as? String { text.append(String(v.suffix(100_000))) }
                } else if r == "AXStaticText", text.count < 400, let v = attr(e, kAXValueAttribute) as? String { text.append(v) }
                return true
            }
            let selected = tabs.first(where: tabSelected)
            let wTitle = title(w)
            let doc = str(w, kAXDocumentAttribute) ?? ""
            let focusedInput = ins.first { (attr($0, kAXFocusedAttribute) as? Bool) == true } ?? ins.first
            out.append(Found(window: w, tab: nil, selectedTab: selected, input: focusedInput,
                             place: AXMatch.Place(title: wTitle, document: doc, screen: text.joined(separator: "\n"))))
            for t in tabs where !tabSelected(t) {
                out.append(Found(window: w, tab: t, selectedTab: selected, input: nil, place: AXMatch.Place(title: title(t))))
            }
        }
        return out
    }

    /// Titles of a window's tabs (only the selected one with `selected`).
    static func tabTitles(_ w: AXUIElement, selected: Bool) -> [String] {
        var out: [String] = []
        var budget = 3000
        walk(w, budget: &budget) { e in
            if isTab(e), !selected || tabSelected(e) { out.append(title(e)) }
            return true
        }
        return out
    }

    static func inputs(_ w: AXUIElement) -> [AXUIElement] {
        var ins: [AXUIElement] = []
        var budget = 5000
        walk(w, budget: &budget) { e in
            if inputRoles.contains(role(e)) { ins.append(e) }
            return true
        }
        return ins
    }

    /// Test guard: the Claude app's page is a new, empty session (nothing of his is in it).
    static func desktopShowsNewSession() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Router.desktopBundleID).first else { return false }
        enableWebAX(app)
        let a = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = element(a, kAXFocusedWindowAttribute) ?? (attr(a, kAXWindowsAttribute) as? [AXUIElement])?.first else { return false }
        var found = false
        var budget = 400
        walk(w, budget: &budget) { e in
            if role(e) == "AXWebArea" { let t = title(e); if t.hasPrefix("New session") || t.hasPrefix("New chat") { found = true }; return false }
            return !found
        }
        return found
    }

    // MARK: Processes

    /// The regular app up the parent chain of a process (the terminal that runs a shell).
    static func guiApp(_ pid: Int32) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<30 {
            if let a = NSRunningApplication(processIdentifier: p), a.activationPolicy == .regular { return a }
            guard let i = AgentProcess.info(p), i.ppid > 1 else { return nil }
            p = i.ppid
        }
        return nil
    }

    static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let u = app.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: u.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    /// Chromium and Electron build their accessibility tree only when asked.
    static func enableWebAX(_ app: NSRunningApplication) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: AX helpers

    static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    static func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
    static func element(_ e: AXUIElement, _ a: String) -> AXUIElement? {
        guard let v = attr(e, a), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute) ?? "?" }
    static func title(_ e: AXUIElement) -> String {
        if let t = str(e, kAXTitleAttribute), !t.isEmpty { return t }
        return str(e, kAXDescriptionAttribute) ?? ""
    }
    /// What a text field says about itself (web apps: its aria label and CSS classes).
    static func label(_ e: AXUIElement) -> String {
        let cls = (attr(e, "AXDOMClassList") as? [String])?.joined(separator: " ") ?? ""
        return [str(e, kAXDescriptionAttribute) ?? "", str(e, kAXTitleAttribute) ?? "", str(e, "AXPlaceholderValue") ?? "", cls].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The window's text field for the chat. One field: that one. Several (an editor with a
    /// terminal panel, a chat app with a search box): a terminal agent needs the one that
    /// says it is a terminal; an app chat the one that says it is the prompt. Otherwise the
    /// focused one, but only if no other field also qualifies. Unsure: nil (nothing typed).
    static func chooseInput(_ ins: [AXUIElement], terminal: Bool) -> AXUIElement? {
        if ins.count <= 1 { return ins.first }
        let focused = ins.first { (attr($0, kAXFocusedAttribute) as? Bool) == true }
        let words = terminal ? ["terminal", "xterm", "shell"] : ["prompt", "message", "reply", "chat", "ask claude", "composer"]
        let marked = ins.filter { e in let l = label(e).lowercased(); return words.contains { l.contains($0) } }
        if marked.count == 1 { return marked[0] }
        if let f = focused, marked.contains(where: { CFEqual($0, f) }) { return f }
        return nil
    }
    static func windowOf(_ e: AXUIElement) -> AXUIElement? { element(e, kAXWindowAttribute) }
    static func isTab(_ e: AXUIElement) -> Bool {
        let r = role(e), sr = str(e, kAXSubroleAttribute) ?? ""
        return (r == "AXRadioButton" && sr != "AXSortButton" && parentIsTabGroup(e)) || r == "AXTab" || sr == "AXTabButton"
    }
    static func parentIsTabGroup(_ e: AXUIElement) -> Bool {
        guard let p = element(e, kAXParentAttribute) else { return false }
        return role(p) == "AXTabGroup"
    }
    static func tabSelected(_ e: AXUIElement) -> Bool {
        (attr(e, kAXValueAttribute) as? Int) == 1 || (attr(e, kAXSelectedAttribute) as? Bool) == true
    }
    static func walk(_ e: AXUIElement, depth: Int = 0, budget: inout Int, visit: (AXUIElement) -> Bool) {
        guard budget > 0, depth <= 40 else { return }
        budget -= 1
        guard visit(e) else { return }
        for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1, budget: &budget, visit: visit) }
    }

    static func hidIdle() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
    static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        // A private source: our own events do not reset his idle time.
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
    static func ms(_ t: Date) -> String { String(format: "%.0f", Date().timeIntervalSince(t) * 1000) }
}

/// Terminal multiplexers: one small focus command each, by the pane id the agent
/// reported from its environment (`$HERDR_PANE_ID`, `$TMUX_PANE`). Nothing is typed
/// through them; typing goes through `AXDelivery` like every other app.
@MainActor
enum Mux {
    struct Focused {
        var clientPid: Int32?
        /// The pane's visible text as the multiplexer sees it: the host window must show it.
        var screen: String = ""
        var restore: () async -> Void
    }

    static func focus(_ p: PaneRef) async -> Focused? {
        switch p.kind {
        case .herdr: return await herdrFocus(p)
        case .tmux: return await tmuxFocus(p)
        }
    }

    static func isFocused(_ p: PaneRef) -> Bool {
        switch p.kind {
        case .herdr:
            guard let json = sync(herdrArgs(p, ["pane", "get", p.id]), env: herdrEnv(p)), let pane = herdrPane(json) else { return false }
            return (pane["focused"] as? Bool) ?? false
        case .tmux:
            return sync(tmuxArgs(p, ["display-message", "-p", "-t", p.id, "#{pane_active}#{window_active}"]))?.trimmingCharacters(in: .whitespacesAndNewlines) == "11"
        }
    }

    /// The pane really runs this agent: the agent descends from the pane's shell.
    static func owns(_ p: PaneRef, pid: Int32) -> Bool {
        var root: Int32?
        switch p.kind {
        case .herdr:
            if let json = sync(herdrArgs(p, ["pane", "process-info", "--pane", p.id]), env: herdrEnv(p)),
               let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let info = (o["result"] as? [String: Any])?["process_info"] as? [String: Any] {
                root = (info["shell_pid"] as? NSNumber)?.int32Value
            }
        case .tmux:
            root = sync(tmuxArgs(p, ["display-message", "-p", "-t", p.id, "#{pane_pid}"])).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard let root else { return false }
        var q = pid
        for _ in 0..<30 {
            if q == root { return true }
            guard let i = AgentProcess.info(q), i.ppid > 1 else { return false }
            q = i.ppid
        }
        return false
    }

    // herdr

    static func herdrArgs(_ p: PaneRef, _ a: [String]) -> [String] { [Router.herdr] + a }
    static func herdrEnv(_ p: PaneRef) -> [String: String] { p.socket.map { ["HERDR_SOCKET_PATH": $0] } ?? [:] }

    static func herdrPane(_ json: String) -> [String: Any]? {
        guard let d = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (root["result"] as? [String: Any])?["pane"] as? [String: Any]
    }

    static func herdrFocus(_ p: PaneRef) async -> Focused? {
        let env = herdrEnv(p)
        // What he was looking at, to switch back.
        var previous: String?
        if let json = try? await Router.run(herdrArgs(p, ["pane", "list"]), env: env),
           let d = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let panes = (root["result"] as? [String: Any])?["panes"] as? [[String: Any]] {
            previous = panes.first { ($0["focused"] as? Bool) == true }?["pane_id"] as? String
        }
        guard let json = try? await Router.run(herdrArgs(p, ["pane", "get", p.id]), env: env), let pane = herdrPane(json) else { return nil }
        if (pane["focused"] as? Bool) != true {
            let ok = (try? await Router.run(herdrArgs(p, ["agent", "focus", p.id]), checkExit: true, env: env)) != nil
            if !ok, let tab = pane["tab_id"] as? String { _ = try? await Router.run(herdrArgs(p, ["tab", "focus", tab]), env: env) }
        }
        guard isFocused(p) else { return nil }
        let client = herdrClientPid(socket: p.socket)
        let screen = (try? await Router.run(herdrArgs(p, ["pane", "read", p.id, "--source", "visible", "--lines", "40"]), env: env)) ?? ""
        return Focused(clientPid: client, screen: screen) {
            guard let previous, previous != p.id else { return }
            if (try? await Router.run(herdrArgs(p, ["agent", "focus", previous]), checkExit: true, env: env)) == nil,
               let json = try? await Router.run(herdrArgs(p, ["pane", "get", previous]), env: env),
               let tab = herdrPane(json)?["tab_id"] as? String {
                _ = try? await Router.run(herdrArgs(p, ["tab", "focus", tab]), env: env)
            }
        }
    }

    /// A herdr client (not the server) for this socket: its terminal shows the pane.
    static func herdrClientPid(socket: String?) -> Int32? {
        guard let out = sync(["/bin/ps", "-axo", "pid=,command="], env: [:]) else { return nil }
        var best: Int32?
        for line in out.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let cmd = parts[1]
            let exe = (cmd.split(separator: " ").first.map(String.init) ?? "")
            guard (exe as NSString).lastPathComponent == "herdr" else { continue }
            if cmd.contains(" server") || cmd.contains(" agent ") || cmd.contains(" pane ") || cmd.contains(" tab ") { continue }
            // A client started for another session uses --session <name>; the socket path holds that name.
            if let socket, let r = cmd.range(of: "--session ") {
                let name = cmd[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                if !socket.contains(name) { continue }
            } else if let socket, !socket.hasSuffix("/herdr.sock") { continue }
            best = pid
        }
        return best
    }

    // tmux

    static func tmuxArgs(_ p: PaneRef, _ a: [String]) -> [String] {
        ["/opt/homebrew/bin/tmux"] + (p.socket.map { ["-S", $0] } ?? []) + a
    }

    static func tmuxFocus(_ p: PaneRef) async -> Focused? {
        // The client that shows this pane's session (the most recently active one).
        let sess = sync(tmuxArgs(p, ["display-message", "-p", "-t", p.id, "#{session_name}"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sess.isEmpty else { return nil }
        let clients = (sync(tmuxArgs(p, ["list-clients", "-F", "#{client_activity} #{client_pid} #{client_tty} #{session_name}"])) ?? "")
            .split(separator: "\n").map { $0.split(separator: " ").map(String.init) }.filter { $0.count >= 4 }
            .sorted { (Int($0[0]) ?? 0) > (Int($1[0]) ?? 0) }
        guard let client = clients.first(where: { $0[3] == sess }) ?? clients.first else { return nil }
        let tty = client[2]
        let prev = sync(tmuxArgs(p, ["display-message", "-p", "-c", tty, "#{pane_id}"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = sync(tmuxArgs(p, ["switch-client", "-c", tty, "-t", p.id]))
        _ = sync(tmuxArgs(p, ["select-window", "-t", p.id]))
        _ = sync(tmuxArgs(p, ["select-pane", "-t", p.id]))
        guard isFocused(p) else { return nil }
        let screen = sync(tmuxArgs(p, ["capture-pane", "-p", "-t", p.id])) ?? ""
        return Focused(clientPid: Int32(client[1]), screen: screen) {
            guard let prev, !prev.isEmpty, prev != p.id else { return }
            _ = sync(tmuxArgs(p, ["switch-client", "-c", tty, "-t", prev]))
            _ = sync(tmuxArgs(p, ["select-window", "-t", prev]))
            _ = sync(tmuxArgs(p, ["select-pane", "-t", prev]))
        }
    }

    /// Short commands (tens of ms): run and wait.
    static func sync(_ args: [String], env extra: [String: String]? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for (k, v) in extra ?? [:] { env[k] = v }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
