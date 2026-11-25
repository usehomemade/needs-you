import Foundation

/// Turns an agent's line into what should be said out loud (HM-1370). Kokoro
/// reads paths, hashes, URLs and markdown letter by letter; this keeps the
/// meaning and drops the noise. Applied right before speech, never to the
/// subtitles or history (they keep the original text).
///
/// Ideas from Heard (daemon.py, path collapse that leaves "and/or" alone,
/// Apache-2.0) and claude-speak (normalizer.py, MIT); the rules and code here
/// are our own.
public enum SpeechText {
    public static func spoken(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "\r\n", with: "\n")

        // Code fences first: their content is never read.
        s = s.sub(#"```[^\n]*\n[\s\S]*?(?:```|$)"#) { _ in "\n\u{E000}\n" }
        s = s.sub(#"```"#) { _ in "" }

        // Markdown links and images keep their text.
        s = s.sub(#"!\[([^\]]*)\]\([^)]*\)"#) { $0[1] }
        s = s.sub(#"\[([^\]]+)\]\((?:[^()]|\([^)]*\))*\)"#) { $0[1] }
        // <https://…> autolinks
        s = s.sub(#"<(https?://[^>\s]+)>"#) { $0[1] }

        // Inline code: plain words (the rules below still apply to them).
        s = s.sub(#"`+([^`\n]*)`+"#) { $0[1] }

        // URLs: their domain.
        s = s.sub(#"\b(?:https?|ftp)://(?:[^\s/@]+@)?([A-Za-z0-9.-]+)(?::\d+)?[^\s]*"#) { m in
            domain(m[1]) + trailingPunctuation(m[0])
        }
        s = s.sub(#"\bwww\.([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)[^\s]*"#) { m in
            domain(m[1]) + trailingPunctuation(m[0])
        }

        s = lines(s)

        // Emphasis markers.
        s = s.sub(#"(\*\*|__)(?=\S)([\s\S]+?)(?<=\S)\1"#) { $0[2] }
        s = s.sub(#"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#) { $0[1] }
        s = s.sub(#"(?<![\w])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w])"#) { $0[1] }
        s = s.sub(#"~~([^~\n]+)~~"#) { $0[1] }

        s = dropEmoji(s)

        // Paths become their last part ("Sources/NeedsYou/Sounds.swift" -> "Sounds.swift").
        s = s.sub(#"(?<![\w@/:.-])(?:~/|\.{1,2}/|/)?(?:[\w.@+-]+/)+[\w.@+-]*(?![\w/])"#) { m in
            path(m[0])
        }
        s = s.sub(#"(?<![\w/])~/"#) { _ in "home folder" }

        // Versions: "v1.2.3" -> "version 1.2.3".
        s = s.sub(#"\b[vV](\d+(?:\.\d+)+(?:-[\w.]+)?)\b"#) { "version " + $0[1] }

        // Hashes and ids carry no meaning out loud.
        s = s.sub(#"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, options: [.caseInsensitive]) { _ in "" }
        s = s.sub(#"\b(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,}\b"#) { _ in "" }
        s = s.sub(#"\b(?=[A-Za-z0-9]*[0-9])(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{16,}\b"#) { _ in "" }

        // File names and domains: "Sounds.swift" -> "Sounds dot swift".
        s = s.sub(#"(?<![\w.])\.?[A-Za-z0-9][\w-]*(?:\.[A-Za-z0-9][\w-]*)+(?![\w])"#) { m in
            dotted(m[0])
        }
        s = s.sub(#"(?<![\w.])\.([A-Za-z][\w-]{1,15})\b"#) { m in
            knownSuffixes.contains(m[1].lowercased()) || m[1].count > 2 ? "dot " + m[1] : m[0]
        }

        s = symbols(s)
        s = units(s)

        // Dashes: pauses, or "to" between numbers.
        s = s.sub(#"(\d)\s?[–—]\s?(\d)"#) { $0[1] + " to " + $0[2] }
        s = s.sub(#"\s*[—–]+\s*"#) { _ in ", " }
        s = s.sub(#"(?<=\s)-{1,2}(?=\s)"#) { _ in "," }

        // "#123" -> "number 123"; snake_case -> words; leftover markup.
        s = s.sub(#"(?<![\w&])#(\d+)\b"#) { "number " + $0[1] }
        s = s.sub(#"(?<=[A-Za-z0-9])_+(?=[A-Za-z0-9])"#) { _ in " " }
        s = s.sub(#"[`*_#|<>\\^]+"#) { _ in " " }
        s = s.sub(#"\[\s*\]|\(\s*\)"#) { _ in "" }
        s = s.replacingOccurrences(of: "\u{E000}", with: "a code block")

        return tidy(s)
    }

    // MARK: Lines (headings, quotes, lists, tables)

    private static func lines(_ s: String) -> String {
        var out: [String] = []
        for raw in s.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { out.append(""); continue }
            // Horizontal rules and table separators.
            if line.range(of: #"^(?:[-*_]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            if line.range(of: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#, options: .regularExpression) != nil { continue }
            line = line.sub(#"^(?:>\s*)+"#) { _ in "" }
            line = line.sub(#"^#{1,6}\s+"#) { _ in "" }
            line = line.sub(#"^[-*+•]\s+(?:\[[ xX]\]\s+)?"#) { _ in "" }
            if line.hasPrefix("|") || line.filter({ $0 == "|" }).count >= 2 {
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                line = cells.joined(separator: ", ")
            }
            out.append(line)
        }
        // One spoken flow: a line that ends without punctuation gets a full stop.
        var joined: [String] = []
        for line in out where !line.isEmpty {
            var l = line
            if let last = l.last, !".,;:!?)".contains(last) { l += "." }
            joined.append(l)
        }
        // A single line is left as it was (no full stop added).
        if out.filter({ !$0.isEmpty }).count == 1 { return out.first { !$0.isEmpty } ?? "" }
        return joined.joined(separator: " ")
    }

    // MARK: Pieces

    private static func domain(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// Sentence punctuation swallowed by a URL match ("see https://x.com/a.").
    private static func trailingPunctuation(_ match: String) -> String {
        guard let last = match.last, ".,;:!?)".contains(last) else { return "" }
        return String(last)
    }

    private static let orPairs: Set<String> = [
        "and/or", "yes/no", "on/off", "in/out", "either/or", "he/she", "his/her", "true/false",
        "input/output", "read/write", "open/close", "start/stop", "before/after", "client/server",
        "allow/deny", "up/down", "left/right", "push/pull", "get/set", "pros/cons", "this/that",
    ]

    private static func path(_ token: String) -> String {
        var t = token
        var tail = ""
        while let last = t.last, ".,;:!?".contains(last), t.count > 1 { tail = String(last) + tail; t.removeLast() }
        if t.contains("://") { return token }
        // Dates and fractions: 25/11, 1/2.
        if t.allSatisfy({ $0.isNumber || $0 == "/" || $0 == "." }) { return token }
        let marked = t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") || t.hasPrefix("../")
        let skip: Set<String> = ["", "~", ".", ".."]
        let parts: [String] = t.split(separator: "/").map { String($0) }.filter { (p: String) -> Bool in !skip.contains(p) }
        guard let last = parts.last else { return marked ? tail : token }
        if !marked && parts.count == 2 {
            let lower = t.lowercased()
            if orPairs.contains(lower) || parts.allSatisfy({ $0.count == 1 }) {
                return parts.joined(separator: " or ") + tail
            }
        }
        return last + tail
    }

    /// File extensions and domain endings that are read as "dot …".
    static let knownSuffixes: Set<String> = [
        // code and docs
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "c", "h", "m", "mm", "cpp", "hpp",
        "java", "kt", "kts", "cs", "php", "sh", "bash", "zsh", "fish", "md", "mdx", "txt", "json", "jsonl", "yml", "yaml",
        "toml", "ini", "cfg", "conf", "env", "lock", "plist", "xml", "html", "htm", "css", "scss", "sql", "csv", "tsv",
        "log", "pdf", "png", "jpg", "jpeg", "gif", "svg", "webp", "wav", "mp3", "m4a", "mp4", "mov", "zip", "gz", "tgz",
        "dmg", "pkg", "app", "icns", "entitlements", "xcframework", "xcodeproj", "pem", "p8", "p12", "key", "lua", "vue",
        "svelte", "astro", "dart", "ex", "exs", "erl", "zig", "nix", "tf", "proto", "graphql", "wasm", "ipynb", "service",
        // domains
        "com", "dev", "io", "co", "org", "net", "ai", "so", "gg", "me", "us", "uk", "de", "at", "tr", "fr", "it", "ru",
        "eu", "xyz", "tech", "cloud", "page", "run", "site", "website", "info", "biz", "tv", "fm", "ly", "to", "is",
        "local", "internal", "ts.net",
    ]

    private static func dotted(_ token: String) -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // Numbers, initials ("e.g.", "p.m."), and tokens whose last part is not a known ending stay.
        guard parts.count >= 2, let last = parts.last, !last.isEmpty else { return token }
        if parts.allSatisfy({ $0.allSatisfy(\.isNumber) || $0.isEmpty }) { return token }
        if parts.filter({ !$0.isEmpty }).allSatisfy({ $0.count == 1 }) { return token }
        guard knownSuffixes.contains(last.lowercased()) else { return token }
        let words = parts.map { $0.isEmpty ? "" : $0 }
        var out = words.first == "" ? "dot " : ""
        out += words.drop { $0.isEmpty }.joined(separator: " dot ")
        return out
    }

    private static func symbols(_ s: String) -> String {
        var s = s
        s = s.sub(#"\s*(?:→|⟶|->|=>|⇒)\s*"#) { _ in " to " }
        s = s.sub(#"\s*(?:←|<-)\s*"#) { _ in " from " }
        s = s.sub(#"\s*(?:≥|>=)\s*"#) { _ in " at least " }
        s = s.sub(#"\s*(?:≤|<=)\s*"#) { _ in " at most " }
        s = s.sub(#"\s*(?:≠|!=)\s*"#) { _ in " not " }
        s = s.sub(#"\s*≈\s*"#) { _ in " about " }
        s = s.sub(#"(?<![\w~])~\s?(?=\d)"#) { _ in "about " }
        s = s.sub(#"\s*±\s*"#) { _ in " plus or minus " }
        s = s.sub(#"\b0x[0-9a-fA-F]+\b"#) { _ in "" }
        s = s.sub(#"(\d)\s*[×x]\s*(?=\d)"#) { $0[1] + " by " }
        s = s.sub(#"(\d)[×x](?![\w])"#) { $0[1] + " times" }
        s = s.sub(#"\s*×\s*"#) { _ in " times " }
        s = s.sub(#"\s+&\s+"#) { _ in " and " }
        s = s.sub(#"(\d)\s?%"#) { $0[1] + " percent" }
        s = s.sub(#"\$(\d+(?:[.,]\d+)?)"#) { $0[1] + " dollars" }
        s = s.sub(#"€\s?(\d+(?:[.,]\d+)?)|(\d+(?:[.,]\d+)?)\s?€"#) { ($0[1].isEmpty ? $0[2] : $0[1]) + " euros" }
        s = s.sub(#"(\d)\s?°C\b"#) { $0[1] + " degrees" }
        s = s.sub(#"\s*[…]"#) { _ in "..." }
        s = s.sub(#"[✓✔]"#) { _ in "" }
        return s
    }

    private static let unitNames: [String: (one: String, many: String)] = [
        "ms": ("millisecond", "milliseconds"), "s": ("second", "seconds"), "sec": ("second", "seconds"),
        "secs": ("second", "seconds"), "min": ("minute", "minutes"), "mins": ("minute", "minutes"),
        "h": ("hour", "hours"), "hr": ("hour", "hours"), "hrs": ("hour", "hours"),
        "kb": ("kilobyte", "kilobytes"), "mb": ("megabyte", "megabytes"), "gb": ("gigabyte", "gigabytes"),
        "tb": ("terabyte", "terabytes"), "hz": ("hertz", "hertz"), "khz": ("kilohertz", "kilohertz"),
        "mhz": ("megahertz", "megahertz"), "ghz": ("gigahertz", "gigahertz"), "fps": ("frame per second", "frames per second"),
        "px": ("pixel", "pixels"), "pt": ("point", "points"), "db": ("decibel", "decibels"),
        "mbps": ("megabit per second", "megabits per second"), "gbps": ("gigabit per second", "gigabits per second"),
    ]

    private static func units(_ s: String) -> String {
        var s = s
        s = s.sub(#"(?<![\w.])(\d+(?:\.\d+)?)(\s?)(ms|secs?|s|mins?|hrs?|h|[kKMGT][bB]|[kKMG]?Hz|fps|px|pt|dB|[MG]bps)\b(?!['’]\w)"#) { m in
            let number = m[1], unit = m[3]
            // "1990s", "4h" without a space only for short numbers; "s"/"h" need a short number.
            if (unit == "s" || unit == "h") && m[2].isEmpty && number.count > 3 { return m[0] }
            guard let name = unitNames[unit.lowercased()] else { return m[0] }
            return number + " " + (number == "1" ? name.one : name.many)
        }
        s = s.sub(#"(?<![\w.])(\d+(?:\.\d+)?)k\b"#) { $0[1] + " thousand" }
        return s
    }

    private static func dropEmoji(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let p = u.properties
            if p.isEmojiPresentation || (p.isEmoji && u.value > 0x238C && !(0x2190...0x21FF).contains(u.value) && u.value != 0x2122) {
                continue
            }
            if u.value == 0xFE0F || u.value == 0x200D || (0x1F3FB...0x1F3FF).contains(u.value) { continue }
            out.append(u)
        }
        return String(out)
    }

    private static func tidy(_ s: String) -> String {
        var s = s
        s = s.sub(#"\s+"#) { _ in " " }
        s = s.sub(#"\s+([,.;:!?)])"#) { $0[1] }
        s = s.sub(#"\(\s+"#) { _ in "(" }
        s = s.sub(#",(?:\s*,)+"#) { _ in "," }
        s = s.sub(#",\s*([.;:!?])"#) { $0[1] }
        s = s.sub(#"([;:!?])\s*,"#) { $0[1] }
        s = s.sub(#"^[\s,.;:]+"#) { _ in "" }
        s = s.sub(#":\s*\."#) { _ in "." }
        s = s.sub(#"\.{4,}"#) { _ in "..." }
        s = s.sub(#"(?<!\.)\.\.(?!\.)"#) { _ in "." }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

fileprivate extension String {
    /// Regex replace with a closure over the capture groups (index 0 = whole match;
    /// a group that did not take part is "").
    func sub(_ pattern: String, options: NSRegularExpression.Options = [], _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        let ns = self as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += transform(groups)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
