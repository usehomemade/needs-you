import Foundation
import SwiftUI

/// The user's name (Settings → General, and the first-run prompt). Empty by
/// default: then Needs You says "you" to them and "the user" to agents.
///
/// - `heardAs`: spellings the speech models write instead of the name
///   (comma separated, e.g. "Toonch, Tunge"); fixed in every transcript.
/// - `heardAsPattern` (no UI): a regular expression for the same, for names
///   the models mangle in many ways.
/// - `sayAs`: how the system voice should spell it to say it right.
/// - `phonemes` (no UI): the IPA Kokoro uses for the name.
enum UserName {
    static let key = "userName"
    static let heardAsKey = "userNameHeardAs"
    static let heardAsPatternKey = "userNameHeardAsPattern"
    static let sayAsKey = "userNameSayAs"
    static let phonemesKey = "userNamePhonemes"
    static let askedKey = "userNameAsked"

    private static var d: UserDefaults { .standard }
    private static func str(_ k: String) -> String? {
        let v = d.string(forKey: k)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? nil : v
    }

    /// The name, or nil when not set.
    static var value: String? { str(key) }
    /// For agents: the name, or "the user" / "The user".
    static var forAgents: String { value ?? "the user" }
    static var ForAgents: String { value ?? "The user" }
    /// ", Alex" after a greeting, or nothing.
    static var commaName: String { value.map { ", \($0)" } ?? "" }
    /// " Alex" after "Hi", or nothing.
    static var spaceName: String { value.map { " \($0)" } ?? "" }

    static var sayAs: String? { str(sayAsKey) }
    static var phonemes: String? { str(phonemesKey) }

    /// Transcript fixes for the name (Parakeet, Whisper and Apple speech).
    static var fixes: [(String, String)] {
        guard let name = value else { return [] }
        var out: [(String, String)] = []
        if let p = str(heardAsPatternKey) { out.append(("(?i)\\b(\(p))\\b", name)) }
        let words = (str(heardAsKey) ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let alternatives = ([name] + words).map(NSRegularExpression.escapedPattern(for:))
        out.append(("(?i)\\b(" + alternatives.joined(separator: "|") + ")\\b", name))
        return out
    }

    /// Hints for the speech recognisers (contextual strings, Whisper prompt).
    static var hints: [String] { value.map { [$0] } ?? [] }
}

/// Settings → General: "Your Name" and how it is heard and said.
struct UserNameSection: View {
    @AppStorage(UserName.key) private var name = ""
    @AppStorage(UserName.heardAsKey) private var heardAs = ""
    @AppStorage(UserName.sayAsKey) private var sayAs = ""

    var body: some View {
        Section {
            TextField("Your Name", text: $name, prompt: Text("Optional"))
                .onSubmit { AgentsStore.shared.sync() }
            if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                TextField("Also Heard As", text: $heardAs, prompt: Text("Spellings to fix, comma separated"))
                TextField("Say It Like", text: $sayAs, prompt: Text("How the voice should spell it"))
            }
        } footer: {
            Text("Needs You greets you by name and tells agents who they are asking. Without a name it says \u{201C}you\u{201D}.")
                .foregroundStyle(.secondary)
        }
        .onChange(of: name) { _, _ in
            UserDefaults.standard.set(true, forKey: UserName.askedKey)
            AgentsStore.shared.sync()
        }
    }
}

/// First run: one small window that asks for the name (can be skipped).
struct UserNamePrompt: View {
    @AppStorage(UserName.key) private var name = ""
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What should Needs You call you?").font(.title3.weight(.semibold))
            Text("Agents use your name when they ask you something out loud. You can change it later in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Your Name", text: $name, prompt: Text("Your name"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(done)
            HStack {
                Spacer()
                Button("Skip") { name = ""; done() }
                Button("Continue", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func done() {
        UserDefaults.standard.set(true, forKey: UserName.askedKey)
        AgentsStore.shared.sync()
        dismissWindow(id: "name")
    }
}
