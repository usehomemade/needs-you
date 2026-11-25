import SwiftUI

/// Training: record his voice with a background playing, then use the recordings.
struct TrainingView: View {
    @ObservedObject private var rec = TrainingRecorder.shared
    @ObservedObject private var lab = TrainingLab.shared
    @State private var pick: Set<String> = Set(SpeechModels.stt.filter { SpeechModels.downloaded($0.id) }.map(\.id))

    var body: some View {
        Form {
            Section("Record") {
                Picker("Playing in the background", selection: $rec.background) {
                    ForEach(["Quiet", "Music", "Game", "Video", "Other people"], id: \.self) { Text($0).tag($0) }
                }
                .disabled(rec.state != .idle)
                if rec.state == .idle || rec.state == .saving {
                    Text("Start the music, game or video first, then press Record. Each screen tells you what to do: read a line out loud, answer a question in your own words, or say nothing while the app records only the background. Up to 30 minutes; pause any time.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Record") { rec.start() }.keyboardShortcut(.defaultAction).disabled(rec.state == .saving)
                        if rec.state == .saving { ProgressView().controlSize(.small); Text("Saving…") }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(rec.prompt.kind == .silent || rec.prompt.kind == .free ? rec.prompt.text : "\u{201C}\(rec.prompt.text)\u{201D}")
                            .font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(trainingInstruction(rec.prompt, left: rec.prompt.auto.map { max(0, Int(($0 - (rec.elapsed - rec.promptStart)).rounded(.up))) }))
                            .font(.body).fixedSize(horizontal: false, vertical: true)
                        meter("Mac", rec.levels[0])
                        if let p = rec.phoneName { meter(p, rec.levels[1]) } else {
                            Text("iPhone mic: not in use").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(String(format: "%d:%02d of 30:00 · line %d", Int(rec.elapsed) / 60, Int(rec.elapsed) % 60, rec.promptIndex + 1))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        HStack {
                            Button("Next") { rec.next() }.keyboardShortcut(.space, modifiers: []).disabled(rec.state != .recording)
                            if rec.state == .recording { Button("Pause") { rec.pause() } } else { Button("Resume") { rec.resume() } }
                            Button("Stop and Save") { rec.stop() }
                        }
                    }
                }
                if let e = rec.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            }

            Section("Sessions") {
                if lab.sessions.isEmpty { Text("No recordings yet.").foregroundStyle(.secondary) }
                ForEach(lab.sessions) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.date.formatted(date: .abbreviated, time: .shortened))
                            Text("\(s.background) · \(Int(s.duration / 60)) min \(Int(s.duration) % 60) s · \(s.marks.count) lines · \(s.hasPhone ? "Mac + iPhone" : "Mac")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { lab.delete(s) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete this recording")
                    }
                }
            }

            Section("Use the recordings") {
                Text("Re-learns your voice from every recording, tunes how close a match must be, and builds a test set from your lines.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Learn From Recordings") { Task { await lab.process() } }
                        .disabled(lab.sessions.isEmpty || lab.busy != nil || rec.state != .idle)
                    if lab.canRestore {
                        Button("Undo") { Task { await lab.restore() } }
                            .help("Put back the voice and threshold from before the last learn")
                    }
                }
                if let r = lab.processReport { Text(r).font(.callout).textSelection(.enabled) }
            }

            Section("Evaluate") {
                Text("Scores each speech model on your test set. Models not on this Mac yet are downloaded first.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(SpeechModels.stt) { m in
                    Toggle(isOn: Binding(get: { pick.contains(m.id) }, set: { on in if on { pick.insert(m.id) } else { pick.remove(m.id) } })) {
                        Text(m.name) + Text(SpeechModels.downloaded(m.id) ? "" : "  (downloads \(m.size))").foregroundColor(.secondary)
                    }
                }
                HStack {
                    Button("Evaluate") { Task { await lab.evaluate(models: SpeechModels.stt.map(\.id).filter { pick.contains($0) }) } }
                        .disabled(lab.busy != nil || pick.isEmpty || rec.state != .idle)
                    if let b = lab.busy { ProgressView().controlSize(.small); Text(b).font(.caption) }
                }
                if !lab.results.isEmpty { ResultsTable(results: lab.results) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, minHeight: 560)
        .onAppear { lab.reload() }
    }

    private func meter(_ name: String, _ v: Float) -> some View {
        HStack {
            Text(name).font(.caption).frame(width: 140, alignment: .leading).lineLimit(1)
            LevelMeter(level: v, active: v > 0.35)
        }
    }
}

/// What to do on this screen, in one plain sentence.
func trainingInstruction(_ p: TrainingPrompt, left: Int?) -> String {
    switch p.kind {
    case .silent:
        return "Stay silent. The app is recording only the background. Next line in \(left ?? 0) s."
    case .free:
        return "Answer out loud in your own words until the timer runs out. \(left ?? 0) s left."
    default:
        return "Read this out loud, then press Next (space bar)."
    }
}

struct ResultsTable: View {
    var results: [TrainingLab.EvalResult]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(["Model", "Mic", "Wake", "False", "WER", "Speed", "CPU", "RAM"], id: \.self) { Text($0).font(.caption.weight(.semibold)) }
            }
            ForEach(results.sorted { ($0.source ?? "mac", $0.wer) < ($1.source ?? "mac", $1.wer) }) { r in
                GridRow {
                    Text(r.name).lineLimit(1)
                    Text(["iphone": "iPhone", "merge-iva": "Merged (AuxIVA)", "merge-nlms": "Merged (noise ref.)"][r.source ?? ""] ?? "Mac").lineLimit(1)
                    if let e = r.error { Text(e).foregroundStyle(.red).gridCellColumns(6) } else {
                        Text("\(r.wakeCaught)/\(r.wakeTotal)")
                        Text("\(r.falseWakes)/\(r.otherTotal)")
                        Text(String(format: "%.0f%%", r.wer * 100))
                        Text(String(format: "%.0f ms", r.medianMs))
                        Text(String(format: "%.0f%%", r.cpuPercent))
                        Text(String(format: "%.0f MB", r.footprintMB))
                    }
                }
                .font(.callout.monospacedDigit())
            }
        }
    }
}

/// Settings → Models: speech to text, wake check, speaker check, mics.
struct ModelSettings: View {
    @AppStorage("localSTTModel") private var stt = "wturbo+p"
    @AppStorage("wakeModel") private var wake = "wturbo+p"
    @AppStorage("speakerModel") private var speaker = "campp"
    @AppStorage("micMode") private var micMode = "best"
    @AppStorage("mergeMethod") private var mergeMethod = "iva"
    @AppStorage("ps4Enabled") private var ps4 = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            picker("Speech to text", $stt, SpeechModels.stt)
            picker("Wake check", $wake, SpeechModels.stt)
            picker("Speaker check", $speaker, SpeechModels.speaker)
            Picker("Two mics", selection: $micMode) {
                Text("Best mic per utterance").tag("best")
                Text("Merge (experimental)").tag("merge")
            }
            if micMode == "merge" {
                Picker("Merge method", selection: $mergeMethod) {
                    Text("Blind separation (AuxIVA)").tag("iva")
                    Text("Far mic as noise reference").tag("nlms")
                    Text("Per-band SNR weighting").tag("snr")
                }
                Text("Used only when both mics line up and the merge clearly beats the best single mic.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Voice extraction (PS4, experimental)", isOn: $ps4)
                .disabled(!PS4.installed)
            Text(ps4Note).font(.caption).foregroundStyle(.secondary)
            Button("Open Training…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "training") }
        }
    }

    private var ps4Note: String {
        if !PS4.installed { return "Model not installed (tools/ps4/README.md)." }
        let base = "Pulls your voice out of the mix before speech to text. 68 MB · RAM ~0.5-0.8 GB while loaded · GPU, ~30-50 ms per second of audio."
        return PS4.hasEnrollment ? base : base + " Learn your voice first (Training or Hey Claude → Learn My Voice)."
    }

    private func picker(_ title: String, _ value: Binding<String>, _ models: [SpeechModel]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: value) {
                ForEach(models) { m in Text(m.name).tag(m.id) }
            }
            if let m = SpeechModels.info(value.wrappedValue) {
                Text("\(m.size) · RAM \(m.ram) · \(m.speed)\(SpeechModels.downloaded(m.id) ? "" : " · downloads when first used")\(m.note.isEmpty ? "" : " · " + m.note)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
