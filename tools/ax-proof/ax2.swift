// AX proof for HM-1374 (phase 1, throwaway targets only). Build: swiftc -O tools/ax-proof/ax2.swift -o /tmp/ax2
//   ax2 list [appNameSubstr...]           candidates: app, window, tabs, cwd(doc), inputs; timing
//   ax2 send <pid> <win> <tab|-> <text> [--no-return] [--idle 1.5]
//   ax2 chain <pid>                        agent pid -> tty -> owning GUI app
import AppKit
import ApplicationServices
import Darwin

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func el(_ e: AXUIElement, _ a: String) -> AXUIElement? {
    guard let v = attr(e, a), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute) ?? "?" }
func title(_ e: AXUIElement) -> String { str(e, kAXTitleAttribute) ?? str(e, kAXDescriptionAttribute) ?? "" }
func has(_ hay: String, _ q: String) -> Bool {
    let esc = NSRegularExpression.escapedPattern(for: q)
    return hay.range(of: "(^|[^A-Za-z0-9_-])" + esc + "($|[^A-Za-z0-9_-])", options: [.regularExpression, .caseInsensitive]) != nil
}
func ms(_ t: Date) -> String { String(format: "%.0f", Date().timeIntervalSince(t) * 1000) }

func walk(_ e: AXUIElement, depth: Int = 0, maxDepth: Int = 40, budget: inout Int, visit: (AXUIElement, Int) -> Bool) {
    guard budget > 0, depth <= maxDepth else { return }
    budget -= 1
    guard visit(e, depth) else { return }
    for c in kids(e) { walk(c, depth: depth + 1, maxDepth: maxDepth, budget: &budget, visit: visit) }
}

let inputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
func isTab(_ e: AXUIElement) -> Bool {
    let r = role(e), sr = str(e, kAXSubroleAttribute) ?? ""
    return r == "AXRadioButton" && sr != "AXSortButton" || r == "AXTab" || sr == "AXTabButton"
}

func isElectron(_ app: NSRunningApplication) -> Bool {
    guard let u = app.bundleURL else { return false }
    return FileManager.default.fileExists(atPath: u.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
}
func enableWebAX(_ app: NSRunningApplication) {
    let a = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(a, "AXManualAccessibility" as CFString, kCFBooleanTrue)
}

struct Tab { let el: AXUIElement; let title: String; let selected: Bool }
struct Win { let el: AXUIElement; let title: String; let doc: String; var tabs: [Tab]; var inputs: [AXUIElement] }

func scan(_ w: AXUIElement) -> Win {
    var tabs: [Tab] = [], inputs: [AXUIElement] = []
    var budget = 6000
    walk(w, budget: &budget) { e, _ in
        let r = role(e)
        if isTab(e) { tabs.append(Tab(el: e, title: title(e), selected: (attr(e, kAXValueAttribute) as? Int) == 1 || (attr(e, kAXSelectedAttribute) as? Bool) == true)) }
        if inputRoles.contains(r) { inputs.append(e) }
        return true
    }
    let doc = (attr(w, kAXDocumentAttribute) as? String) ?? ""
    return Win(el: w, title: title(w), doc: doc.removingPercentEncoding ?? doc, tabs: tabs, inputs: inputs)
}

func list(_ filters: [String]) {
    let t0 = Date()
    var n = 0
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let name = app.localizedName ?? "?"
        if !filters.isEmpty && !filters.contains(where: { name.localizedCaseInsensitiveContains($0) }) { continue }
        if isElectron(app) { enableWebAX(app) }
        let a = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(a, 0.25)
        let ta = Date()
        let wins = (attr(a, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in wins {
            let s = scan(w); n += 1
            print("\(name) pid=\(app.processIdentifier) win=\"\(s.title)\" doc=\"\(s.doc)\" tabs=[\(s.tabs.map { $0.title + ($0.selected ? "*" : "") }.joined(separator: " | "))] inputs=\(s.inputs.count)")
            if ProcessInfo.processInfo.environment["AXV"] != nil { for i in s.inputs { print("    input \(role(i)) desc=\"\(title(i))\" focused=\((attr(i, kAXFocusedAttribute) as? Bool) ?? false) value=\"\(((attr(i, kAXValueAttribute) as? String) ?? "").suffix(120).replacingOccurrences(of: "\n", with: "⏎"))\"") } }
        }
        print("  (\(name) \(ms(ta)) ms, electron=\(isElectron(app)))")
    }
    print("TOTAL \(n) windows in \(ms(t0)) ms")
}

func ppid(_ pid: pid_t) -> pid_t? {
    var kp = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
    return kp.kp_eproc.e_ppid
}
func guiApp(for pid: pid_t) -> (NSRunningApplication, [pid_t])? {
    var p = pid, chain: [pid_t] = []
    while p > 1 {
        chain.append(p)
        if let a = NSRunningApplication(processIdentifier: p), a.activationPolicy == .regular { return (a, chain) }
        guard let n = ppid(p) else { return nil }
        p = n
    }
    return nil
}

// MARK: send
func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
}
func hidIdle() -> Double { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) }
func windowOf(_ e: AXUIElement) -> AXUIElement? { el(e, kAXWindowAttribute) ?? el(e, "AXTopLevelUIElement") }

func send(pid: pid_t, win: String, tab: String?, text: String, pressReturn: Bool, idle: Double) async -> Int32 {
    let t0 = Date()
    while hidIdle() < idle { try? await Task.sleep(nanoseconds: 50_000_000); if Date().timeIntervalSince(t0) > 60 { print("ABORT never idle"); return 2 } }
    print("idle wait \(ms(t0)) ms"); let t1 = Date()
    guard let target = NSRunningApplication(processIdentifier: pid) else { print("no app"); return 2 }
    if isElectron(target) { enableWebAX(target) }
    // 1. save the user's state
    let prevApp = NSWorkspace.shared.frontmostApplication
    var prevWin: AXUIElement?, prevFocus: AXUIElement?
    if let p = prevApp {
        let pa = AXUIElementCreateApplication(p.processIdentifier)
        prevWin = el(pa, kAXFocusedWindowAttribute); prevFocus = el(pa, kAXFocusedUIElementAttribute)
    }
    let board = NSPasteboard.general
    let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
        let c = NSPasteboardItem(); for t in item.types { if let d = item.data(forType: t) { c.setData(d, forType: t) } }; return c
    }
    let savedText = board.string(forType: .string)
    // 2. find target window + tab
    let app = AXUIElementCreateApplication(pid)
    let wins = ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).map(scan)
    guard let w0 = wins.first(where: { has($0.title, win) || has($0.doc, win) || $0.tabs.contains { has($0.title, win) } }) else { print("ABORT no window \(win)"); return 2 }
    print("found window \"\(w0.title)\" in \(ms(t1)) ms"); let t2 = Date()
    // 3. focus app, window, tab, input
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w0.el, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(w0.el, kAXMainAttribute as CFString, kCFBooleanTrue)
    var tabTitle: String? = nil
    if let tab, let t = w0.tabs.first(where: { has($0.title, tab) }) {
        let r = AXUIElementPerformAction(t.el, kAXPressAction as CFString)
        tabTitle = t.title
        print("pressed tab \"\(t.title)\" -> \(r.rawValue)")
        try? await Task.sleep(nanoseconds: 30_000_000)
    } else if tab != nil { print("ABORT tab not found \(tab!)"); return 2 }
    // re-scan after tab switch: the visible input may have changed
    var w = w0
    if tabTitle != nil {
        // Native window tabs (Terminal, Ghostty): every tab is its own AXWindow. Re-resolve the window.
        for _ in 0..<30 {
            if let fw = el(app, kAXFocusedWindowAttribute), has(title(fw), tab!) || has((attr(fw, kAXDocumentAttribute) as? String)?.removingPercentEncoding ?? "", tab!) { w = scan(fw); break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    let w2 = scan(w.el)
    let inp = w2.inputs.first { (attr($0, kAXFocusedAttribute) as? Bool) == true } ?? w2.inputs.first
    if let inp { AXUIElementSetAttributeValue(inp, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
    var ok = false
    for i in 0..<100 {
        if i == 20 && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { print("AXFrontmost did not take; NSRunningApplication.activate"); target.activate(options: [.activateAllWindows]) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
           let fw = el(app, kAXFocusedWindowAttribute), CFEqual(fw, w.el) { ok = true; break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    // 4. the guard: focused element must be a text input inside the target window (and tab)
    let fe = el(app, kAXFocusedUIElementAttribute)
    let feRole = fe.map(role) ?? "nil"
    let feWin = fe.flatMap(windowOf)
    let inWin = feWin.map { CFEqual($0, w.el) } ?? false
    let isInput = inputRoles.contains(feRole)
    var tabOK = true
    if let tabTitle { tabOK = scan(w.el).tabs.contains { $0.title == tabTitle && $0.selected } || has(w.title, tab!) }
    print("front now pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    print("focus: front+window=\(ok) element=\(feRole) inWindow=\(inWin) tabSelected=\(tabOK) in \(ms(t2)) ms")
    guard ok, isInput, inWin, tabOK else { print("ABORT: target not verified, nothing pasted"); await restore(prevApp, prevWin, prevFocus, pid); return 3 }
    if hidIdle() < 0.2 { print("ABORT: user input during focus"); await restore(prevApp, prevWin, prevFocus, pid); return 3 }
    let t3 = Date()
    board.clearContents(); board.setString(text, forType: .string)
    key(9, .maskCommand)                  // cmd-V
    try? await Task.sleep(nanoseconds: 60_000_000)
    if pressReturn {
        // re-check right before Return
        let fe2 = el(app, kAXFocusedUIElementAttribute)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let fe2, let w3 = windowOf(fe2), CFEqual(w3, w.el) { key(36) }
        else { print("ABORT: focus moved before Return") }
    }
    try? await Task.sleep(nanoseconds: 60_000_000)
    print("paste+return \(ms(t3)) ms")
    let t4 = Date()
    await restore(prevApp, prevWin, prevFocus, pid)
    board.clearContents(); if !saved.isEmpty { board.writeObjects(saved) }
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    let pf = prevApp.flatMap { el(AXUIElementCreateApplication($0.processIdentifier), kAXFocusedUIElementAttribute) }
    let focusBack = (pf != nil && prevFocus != nil) ? CFEqual(pf!, prevFocus!) : false
    print("restore \(ms(t4)) ms -> front=\(front) (was \(prevApp?.localizedName ?? "?")) focusBack=\(focusBack) clipboardSame=\(board.string(forType: .string) == savedText)")
    print("TOTAL after idle \(ms(t1)) ms")
    return 0
}

func restore(_ prevApp: NSRunningApplication?, _ prevWin: AXUIElement?, _ prevFocus: AXUIElement?, _ pid: pid_t) async {
    guard let p = prevApp, p.processIdentifier != pid else { return }
    let pa = AXUIElementCreateApplication(p.processIdentifier)
    AXUIElementSetAttributeValue(pa, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let pw = prevWin { AXUIElementPerformAction(pw, kAXRaiseAction as CFString); AXUIElementSetAttributeValue(pw, kAXMainAttribute as CFString, kCFBooleanTrue) }
    if let pf = prevFocus { AXUIElementSetAttributeValue(pf, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
    for _ in 0..<50 { if NSWorkspace.shared.frontmostApplication?.processIdentifier == p.processIdentifier { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
}

let a = CommandLine.arguments
guard AXIsProcessTrusted() else { print("NOT TRUSTED for AX"); exit(3) }
switch a.count > 1 ? a[1] : "" {
case "list": list(Array(a.dropFirst(2)))
case "chain":
    let p = pid_t(a[2])!
    if let (g, c) = guiApp(for: p) { print("pid \(p) chain \(c) -> \(g.localizedName ?? "?") pid \(g.processIdentifier)") } else { print("pid \(p) -> no GUI app in parent chain") }
case "send":
    let noRet = a.contains("--no-return")
    var idle = 1.5
    if let i = a.firstIndex(of: "--idle") { idle = Double(a[i + 1])! }
    let rest = a.enumerated().filter { $0.element != "--no-return" && $0.element != "--idle" && ($0.offset == 0 || a[$0.offset - 1] != "--idle") }.map(\.element)
    let tab = rest[4] == "-" ? nil : rest[4]
    var code: Int32 = 0
    let sem = DispatchSemaphore(value: 0)
    Task { code = await send(pid: pid_t(rest[2])!, win: rest[3], tab: tab, text: rest[5], pressReturn: !noRet, idle: idle); sem.signal() }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    exit(code)
default: print("usage: list|chain|send")
}
