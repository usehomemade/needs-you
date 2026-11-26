import Foundation

/// One element of an app's window, as Accessibility reports it (HM-1394).
public struct AXItem: Equatable, Sendable {
    public var role: String
    public var label: String
    public var depth: Int
    public var x, y, width, height: Double

    public init(role: String, label: String, depth: Int, x: Double, y: Double, width: Double, height: Double) {
        self.role = role; self.label = label; self.depth = depth
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Finds a chat app's conversation list with no knowledge of the app (HM-1394): the longest
/// column of same-size, same-depth clickable rows with text, outside the message field's
/// column. The Claude app's Pinned and Recents rows and the ChatGPT app's chat rows both
/// match it; their nav buttons sit at another depth or size, their headers at another size.
public enum ChatListFinder {
    public static let rowRoles: Set<String> = ["AXButton", "AXLink", "AXRow", "AXCell", "AXRadioButton"]

    /// Indices of `items` that are conversations, top to bottom. Empty when no column has 3 rows.
    public static func chats(_ items: [AXItem], messageField: AXItem?) -> [Int] {
        var groups: [String: [Int]] = [:]
        for (i, it) in items.enumerated() {
            guard rowRoles.contains(it.role), it.label.trimmingCharacters(in: .whitespaces).count >= 2,
                  it.width >= 120, it.height >= 16, it.height <= 64 else { continue }
            if let f = messageField, it.x < f.x + f.width, it.x + it.width > f.x { continue } // in the conversation itself
            let key = "\(it.role)|\(it.depth)|\(Int((it.x / 4).rounded()))|\(Int((it.width / 4).rounded()))|\(Int((it.height / 4).rounded()))"
            groups[key, default: []].append(i)
        }
        let best = groups.values.filter { $0.count >= 3 }.max { a, b in
            a.count != b.count ? a.count < b.count : items[a[0]].x > items[b[0]].x
        }
        return (best ?? []).sorted { items[$0].y < items[$1].y }
    }

    /// A chat app's layout: a message field at least 250 wide, below the middle of a chat
    /// column of 3 or more. A search field at the top of a list (1Password, Finder) is not one.
    public static func isChatLayout(_ items: [AXItem]) -> Bool {
        guard let field = messageField(items), field.width >= 250 else { return false }
        let rows = chats(items, messageField: field)
        guard rows.count >= 3, let first = rows.first, let last = rows.last else { return false }
        return field.y > (items[first].y + items[last].y) / 2
    }

    /// The message field: the widest text area or field.
    public static func messageField(_ items: [AXItem]) -> AXItem? {
        items.filter { $0.role == "AXTextArea" || $0.role == "AXTextField" }.max { $0.width < $1.width }
    }

    /// "Learning to bake sourdough - Claude" -> "Learning to bake sourdough"; nil for the bare app name.
    public static func chatTitle(_ title: String, appName: String) -> String? {
        var s = title.trimmingCharacters(in: .whitespaces)
        for sep in [" - ", " \u{2013} ", " \u{2014} ", " | "] where s.hasSuffix(sep + appName) { s = String(s.dropLast((sep + appName).count)) }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s.caseInsensitiveCompare(appName) == .orderedSame ? nil : s
    }
}
