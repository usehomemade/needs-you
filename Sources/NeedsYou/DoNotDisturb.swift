import Foundation
import NeedsYouShared

/// One thing an agent wanted to say while the user was away (or did not answer).
struct Voicemail: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case ask, say, noAnswer = "no_answer" }
    var id: String
    var at: Date
    var kind: Kind
    var text: String
    var title: String?
    var context: String?
    var project: String?
    /// Folder the agent runs in, and its herdr pane (so an answer finds its chat).
    var cwd: String?
    var pane: String?
    var conversationID: String?
    var heard = false
    var answer: String?

    /// "orchard" (the agent's folder), else its --project.
    var source: String {
        if let cwd, let last = cwd.split(separator: "/").last, cwd != NSHomeDirectory() { return String(last) }
        return project ?? "an agent"
    }
}

/// Do not disturb (HM-1352): while it is on, no agent speaks, plays a sound or
/// opens the mic. `ask`/`say` return at once with status "voicemail" and the text
/// is kept here. It stays on until he says "I'm back" / "Good morning", turns it off in the
/// menu or Settings, or the end he set ("for three hours", "until 8", HM-1433) comes.
/// Kept on disk, so a restart keeps it on.
@MainActor
final class DoNotDisturb: ObservableObject {
    static let shared = DoNotDisturb()

    struct State: Codable { var on = false; var goodNight = false; var since: Date?
        /// It turns itself off then (nil: until he is back).
        var until: Date? }

    @Published private(set) var state = State()
    @Published private(set) var voicemails: [Voicemail] = []

    var on: Bool { state.on }
    var unheard: [Voicemail] { voicemails.filter { !$0.heard }.sorted { $0.at < $1.at } }

    private var stateURL: URL { Wire.supportDir.appendingPathComponent("dnd.json") }
    private var mailURL: URL { Wire.supportDir.appendingPathComponent("voicemails.json") }

    init() {
        if let d = try? Data(contentsOf: stateURL), let s = try? LineIO.decoder.decode(State.self, from: d) { state = s }
        if let d = try? Data(contentsOf: mailURL), let v = try? LineIO.decoder.decode([Voicemail].self, from: d) { voicemails = v }
        // The end he set: checked every 15 s, so sleep and restarts cannot skip it.
        expiry = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in DoNotDisturb.shared.checkEnd() }
        }
        DispatchQueue.main.async { self.checkEnd() }
    }

    private var expiry: Timer?

    /// The end he set has come: off, with the cue.
    func checkEnd(now: Date = Date()) {
        guard state.on, let end = state.until, end <= now else { return }
        Isolation.note("dnd: the end he set came")
        turnOff(chime: true)
    }

    /// `chime`: play the DND cue (menu, Settings, voice). Test hooks stay silent.
    /// `until`: when it ends by itself (nil: until he is back). Turning it on again sets a new end.
    func turnOn(goodNight: Bool, until: Date? = nil, chime: Bool = false) {
        if chime && !state.on { Sounds.shared.play(.dndOn) }
        state = State(on: true, goodNight: goodNight || (state.on && state.goodNight), since: state.on ? state.since : Date(),
                      until: until.flatMap { $0 > Date() ? $0 : nil })
        saveState()
        Isolation.note("dnd: on (\(goodNight ? "good night" : "away"))" + (state.until.map { " until \($0)" } ?? ""))
    }

    func turnOff(chime: Bool = false) {
        guard state.on else { return }
        if chime { Sounds.shared.play(.dndOff) }
        state.on = false
        state.goodNight = false
        state.until = nil
        saveState()
        Isolation.note("dnd: off")
    }

    /// Menu and Settings switch.
    func set(_ on: Bool) { on ? turnOn(goodNight: false, chime: true) : turnOff(chime: true) }

    /// Menu and Settings: on until `end` (nil: until he turns it off).
    func turnOn(until end: Date?) { turnOn(goodNight: false, until: end, chime: true) }

    /// "until 3:30 PM" while it has an end.
    var untilText: String? {
        guard state.on, let u = state.until else { return nil }
        let cal = Calendar.current
        let time = u.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(u) { return "until \(time)" }
        if cal.isDateInTomorrow(u) { return "until tomorrow \(time)" }
        return "until \(u.formatted(.dateTime.weekday(.wide))) \(time)"
    }

    /// The menu's quick ends: in an hour, this evening (18:00, when that is still ahead), tomorrow morning (08:00).
    static func presets(now: Date = Date(), calendar: Calendar = .current) -> [(String, Date)] {
        var out: [(String, Date)] = [("For 1 Hour", now.addingTimeInterval(3600))]
        if let evening = AwayTime(part: .evening).end(now: now, calendar: calendar), calendar.isDate(evening, inSameDayAs: now),
           evening.timeIntervalSince(now) > 3600 {
            out.append(("Until This Evening", evening))
        }
        if let morning = AwayTime(day: .tomorrow, part: .morning).end(now: now, calendar: calendar) { out.append(("Until Tomorrow Morning", morning)) }
        return out
    }

    @discardableResult
    func store(_ req: Request, kind: Voicemail.Kind, conversationID: String? = nil) -> Voicemail {
        let v = Voicemail(id: "vm-" + UUID().uuidString.prefix(8).lowercased(), at: Date(), kind: kind,
                          text: req.text ?? "", title: req.title, context: req.context, project: req.project,
                          cwd: req.cwd, pane: req.env?["HERDR_PANE_ID"], conversationID: conversationID)
        voicemails.append(v)
        if voicemails.count > 500 { voicemails.removeFirst(voicemails.count - 500) }
        saveMail()
        return v
    }

    func update(_ v: Voicemail) {
        guard let i = voicemails.firstIndex(where: { $0.id == v.id }) else { return }
        voicemails[i] = v
        saveMail()
    }

    func remove(ids: Set<String>) {
        voicemails.removeAll { ids.contains($0.id) }
        saveMail()
    }

    func clearHeard() {
        voicemails.removeAll { $0.heard }
        saveMail()
    }

    /// The JSON an agent gets back while do not disturb is on.
    func response(_ v: Voicemail) -> Response {
        var r = Response(status: "voicemail")
        r.state = "\(UserName.ForAgents) is busy (do not disturb), left as a voicemail. They hear it when they are back: go on with other work and do not ask again."
        r.conversationID = v.id
        return r
    }

    // MARK: Spoken text

    static func when(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = cal.component(.minute, from: d) == 0 ? "h a" : "h:mm a"
        let time = f.string(from: d).replacingOccurrences(of: "AM", with: "a.m.").replacingOccurrences(of: "PM", with: "p.m.")
        if cal.isDate(d, inSameDayAs: now) { return "at \(time)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "yesterday at \(time)" }
        f.dateFormat = "EEEE"
        return "on \(f.string(from: d)) at \(time)"
    }

    /// One voicemail as it is read out.
    static func spoken(_ v: Voicemail, now: Date = Date()) -> String {
        let w = when(v.at, now: now)
        return "\(w.prefix(1).uppercased() + w.dropFirst()), from \(v.source): \(v.text)"
    }

    /// "What did you work on last night?": voicemails since do not disturb started
    /// (or the last 12 hours), grouped by where they came from.
    func summary(now: Date = Date()) -> String {
        let since = state.since.map { min($0, now.addingTimeInterval(-12 * 3600)) } ?? now.addingTimeInterval(-12 * 3600)
        let recent = voicemails.filter { $0.at >= since }.sorted { $0.at < $1.at }
        guard !recent.isEmpty else { return "Nothing came in while you were away." }
        var groups: [(String, [Voicemail])] = []
        for v in recent {
            if let i = groups.firstIndex(where: { $0.0 == v.source }) { groups[i].1.append(v) } else { groups.append((v.source, [v])) }
        }
        let n = recent.count
        var out = "\(n) voicemail\(n == 1 ? "" : "s") from \(groups.count) chat\(groups.count == 1 ? "" : "s"). "
        for (src, list) in groups.prefix(6) {
            let lines = list.suffix(2).map { Self.firstSentence($0.text) }
            out += "\(src.prefix(1).uppercased() + src.dropFirst()): " + lines.joined(separator: " Then: ") + " "
        }
        if groups.count > 6 { out += "And \(groups.count - 6) more chats. " }
        let open = unheard.count
        if open > 0 { out += "\(open) \(open == 1 ? "is" : "are") still unheard." }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func firstSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^.{12,}?[.!?](\s|$)"#, options: .regularExpression) { return String(t[r]).trimmingCharacters(in: .whitespaces) }
        return t.count > 160 ? String(t.prefix(160)) + "…" : t
    }

    private func saveState() {
        guard !Prefs.readOnly else { return }
        try? FileManager.default.createDirectory(at: Wire.supportDir, withIntermediateDirectories: true)
        if let d = try? LineIO.encoder.encode(state) { try? d.write(to: stateURL, options: .atomic) }
    }

    private func saveMail() {
        guard !Prefs.readOnly else { return }
        try? FileManager.default.createDirectory(at: Wire.supportDir, withIntermediateDirectories: true)
        if let d = try? LineIO.encoder.encode(voicemails) { try? d.write(to: mailURL, options: .atomic) }
    }
}
