import Foundation

/// Spoken commands for chat apps that have no hooks of their own, such as the Claude app
/// and ChatGPT (HM-1383):
///
/// - "create a new chat on Claude desktop, ask what's the weather like"
/// - "open ChatGPT and start a new chat: ..."
/// - "use ChatGPT to ask how my business is doing", "ask ChatGPT whether ..."
///
/// All of them start a new chat in the app: a fresh question should not land in
/// whatever conversation happens to be open there. "ChatGPT: ..." (a name and a colon)
/// still goes to the open chat through `ChatMatcher`.
public enum AppCommand {
    public struct Match: Equatable, Sendable {
        /// Index into the apps passed to `parse`.
        public var app: Int
        public var message: String
    }

    /// `apps`: each app's spoken names ("claude desktop", "chatgpt"). A bare "desktop" is
    /// never an app name here ("open desktop and ..." is about the Finder).
    public static func parse(_ rest: String, apps: [[String]]) -> Match? {
        var owner: [String: Int] = [:]
        for (i, names) in apps.enumerated() {
            for n in names {
                let k = n.lowercased().trimmingCharacters(in: .whitespaces)
                if k.isEmpty || k == "desktop" || owner[k] != nil { continue }
                owner[k] = i
            }
        }
        guard !owner.isEmpty else { return nil }
        let alt = owner.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
            .joined(separator: "|")
        let app = #"(?:the\s+)?("# + alt + #")(?:\s+app)?"#
        let polite = #"^(?:please\s+|okay\s+|ok\s+|so\s+)?(?:(?:can|could|would)\s+you\s+)?(?:please\s+)?"#
        let chat = #"(?:chat|conversation|session|thread)"#
        let patterns = [
            // "create a new chat on Claude desktop, ask ..."
            polite + #"(?:create|start|open|make|begin)?\s*(?:a\s+)?new\s+"# + chat + #"\s+(?:on|in|with|at|using|inside|for)\s+"# + app + #"\b(.*)$"#,
            // "open ChatGPT and start a new chat: ..."
            polite + #"(?:open|start|launch|go\s+to)\s+"# + app + #"\s*(?:,|\.|and|with|then)?\s*(?:(?:create|start|open|make)\s+)?(?:a\s+)?new\s+"# + chat + #"\b(.*)$"#,
            // "start a ChatGPT conversation about ..."
            polite + #"(?:create|start|open|make|begin)\s+(?:a\s+)?(?:new\s+)?"# + app + #"\s+"# + chat + #"\b(.*)$"#,
            // "use ChatGPT to ask ...", "ask ChatGPT ...", "open ChatGPT and ask ..."
            polite + #"(?:use|ask|open|go\s+to|switch\s+to|with)\s+"# + app + #"\b(.*)$"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: "(?i)" + p),
                  let m = re.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let ar = Range(m.range(at: 1), in: rest), let tr = Range(m.range(at: 2), in: rest) else { continue }
            let name = rest[ar].lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard let i = owner[name] else { continue }
            return Match(app: i, message: tail(String(rest[tr])))
        }
        return nil
    }

    /// What is left after the app's name: the question itself ("to ask how ..." -> "how ...").
    static func tail(_ s: String) -> String {
        var t = s
        let steps = [
            #"^[\s,.:;!-]+"#,
            #"^(?i)(?:and|then|to|so)\s+"#,
            #"^(?i)(?:(?:start|create|open|make)\s+)?(?:a\s+)?new\s+(?:chat|conversation|session|thread)\b[\s,.:;-]*"#,
            #"^(?i)(?:and|then|to)\s+"#,
            #"^(?i)(?:ask(?:\s+(?:it|them|him|her))?|tell\s+(?:it|them)(?:\s+to)?|say|type|write|send)\b(?:\s+(?:that|this))?[\s,:;-]*"#,
        ]
        for p in steps {
            if let r = t.range(of: p, options: .regularExpression) { t.removeSubrange(r) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ChatMatcher {
    /// Words that say nothing about which chat a message is for.
    public static let topicFiller: Set<String> = [
        "how", "does", "did", "do", "is", "are", "was", "were", "what", "whats", "what's", "when", "where", "why", "who", "which",
        "going", "goes", "doing", "done", "status", "update", "updates", "progress", "news", "there", "that", "this", "these", "those",
        "it", "its", "it's", "my", "me", "you", "your", "we", "our", "us", "can", "could", "would", "should", "will", "please",
        "check", "any", "anything", "some", "something", "now", "today", "still", "yet", "with", "about", "from", "into", "just",
        "also", "ok", "okay", "hey", "thanks", "thank", "like", "get", "got", "let", "let's", "lets", "know", "tell", "ask", "see",
        "look", "all", "has", "have", "had", "been", "be", "not", "no", "yes", "so", "then", "than", "but", "or", "if", "by", "at",
        "as", "up", "out", "go", "good", "well", "new", "work", "working", "there's", "i'm", "i", "he", "she", "they", "them",
    ]

    /// The chat a message is about when it names none ("how is the orchard linter going"):
    /// the one sharing the most words with it (folder, tab label, title, what it works on).
    /// nil when nothing is shared or two chats tie. A chat app counts only by the chat open in it.
    public static func topic(_ message: String, _ chats: [ChatCandidate]) -> Int? {
        let want = Set(tokens(message).filter { $0.count >= 3 && !topicFiller.contains($0) })
        guard !want.isEmpty else { return nil }
        let labels = usableLabels(chats)
        let counts = chats.enumerated().map { i, c -> Int in
            if c.isDesktop && c.detail.isEmpty { return 0 }
            let text = (c.isDesktop ? [c.detail] : [labels[i], c.folder, c.title]).joined(separator: " ")
                .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            let have = tokens(text)
            return want.filter { w in have.contains { similar(w, $0) } }.count
        }
        guard let best = counts.max(), best > 0, counts.filter({ $0 == best }).count == 1 else { return nil }
        return counts.firstIndex(of: best)
    }
}
