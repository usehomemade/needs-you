import AppKit
import NeedsYouShared
import SwiftUI

/// `NeedsYou --ui-demo <window> [options]`: opens the windows without the socket,
/// the mic, the hot keys or any audio, so it runs next to the installed app for
/// screenshots. It reads the installed app's settings, history and voicemails and
/// writes none of them (Prefs.readOnly). Agent instructions are only touched when
/// NEEDS_YOU_CLAUDE_DIR points at a test folder.
///
///   main [--section conversations|voicemails|<project>] [--select first]
///   settings [--pane general|heyClaude|voice|microphones|models|doNotDisturb|agents]
///   training
///
/// Prints "window <number> <title>" for each window it shows (screencapture -l).
@MainActor
enum UIDemo {
    static func start() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let what = args.firstIndex(of: "--ui-demo").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "main"
        if ProcessInfo.processInfo.environment["NEEDS_YOU_CLAUDE_DIR"] != nil { AgentsStore.shared.sync() }
        func findButton(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, String(describing: type(of: v)).contains("StatusBar") { return b }
            for sub in v.subviews { if let b = findButton(sub) { return b } }
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            switch what {
            case "settings":
                AgentsPane.demoSheet = value("--sheet")
                if let p = value("--pane") { UserDefaults.standard.set(p, forKey: "settingsPane") }
                Nav.openSettings()
            case "training":
                Nav.open("training")
            case "name":
                Nav.open("name")
            case "menu":
                // Click our menu bar item; prints its frame (top-left screen points) for screencapture -R.
                let button = NSApp.windows.compactMap { $0.contentView.flatMap(findButton) }.first
                if let button, let w = button.window, let screen = w.screen ?? NSScreen.main {
                    let f = w.convertToScreen(button.convert(button.bounds, to: nil))
                    print("statusitem \(Int(f.minX)) \(Int(screen.frame.maxY - f.maxY)) \(Int(f.width)) \(Int(f.height))")
                    fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { button.performClick(nil) }
                } else { print("no status item") }
                return
            default:
                let nav = Nav.shared
                switch value("--section") ?? "conversations" {
                case "conversations": nav.section = .conversations
                case "voicemails": nav.section = .voicemails
                case let p: nav.section = .project(p)
                }
                if value("--select") == "first" {
                    if case .voicemails = nav.section {
                        nav.voicemail = DoNotDisturb.shared.unheard.first?.id ?? DoNotDisturb.shared.voicemails.last?.id
                    } else {
                        nav.conversation = Conductor.shared.history.first { $0.kind != "voicemail" && $0.turns.count > 1 }?.id
                    }
                }
                Nav.open("main")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let size = value("--size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
                   let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                    w.setFrame(NSRect(x: 80, y: 80, width: size[0], height: size[1]), display: true)
                }
                for w in NSApp.windows where w.isVisible && w.frame.width > 200 {
                    print("window \(w.windowNumber) \(w.title)")
                }
                fflush(stdout)
            }
        }
    }
}
