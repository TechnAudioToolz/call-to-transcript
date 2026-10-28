import AppKit
import SwiftUI
import TranscriptCore

/// A list of items (the calls, or the other files), in queue order.
struct ItemList: View {
    @EnvironmentObject var model: AppModel
    let items: [Item]
    let label: String

    var body: some View {
        List(selection: $model.selection) {
            ForEach(items) { item in
                ItemRow(item: item, position: model.queuePosition(item.id),
                        move: { model.moveInQueue(item.id, by: $0) },
                        isLastInQueue: model.queuePosition(item.id) == model.queueOrder.count,
                        paused: model.isPaused)
                    .tag(item.id)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { model.selection = item.id })
                    .contextMenu {
                        if item.state != .working { Button("Transcribe again") { model.again(item) } }
                        if !item.outputs.isEmpty {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.outputs) }
                        }
                        if model.hasFinished { Button("Clear finished") { model.clearFinished() } }
                        Divider()
                        Button("Remove from list") { model.remove(item) }
                    }
            }
        }
        .onDeleteCommand { if let item = model.selectedItem { model.remove(item) } }  // Delete key
        .accessibilityLabel(label)
    }
}

struct Thumbnail: View {
    @ObservedObject var item: Item
    var width: CGFloat

    var body: some View {
        Group {
            if let image = item.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: item.kind == .video ? "film" : item.kind == .call ? "phone" : "waveform")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: width, height: width * 0.5625)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct ItemRow: View {
    @ObservedObject var item: Item
    var position: Int? = nil
    var move: ((Int) -> Void)? = nil   // -1 up, +1 down in the queue
    var isLastInQueue = false
    var paused = false

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(item: item, width: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.medium).lineLimit(1)
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                if item.state == .working {
                    ProgressView(value: item.progress)
                    Text(item.detail).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let position, let move, item.state != .working {
                QueueArrows(position: position, isLast: isLastInQueue, move: move)
            }
            StateBadge(state: item.state, position: position, paused: paused)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, subtitle, item.state.label].joined(separator: ", "))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let duration = item.duration { parts.append(clock(duration)) }
        if let t = item.transcript {
            parts.append("\(t.wordCount) words")
            parts.append("\(t.speakers.count) speaker\(t.speakers.count == 1 ? "" : "s")")
        } else if item.state == .failed {
            parts.append(item.error)
        } else if item.kind != .call {
            parts.append(item.url.lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }
}

/// Up and down arrows on a queued row, to change its place in the queue.
struct QueueArrows: View {
    let position: Int
    let isLast: Bool
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(position == 1).help("Earlier in the queue").accessibilityLabel("Move up in the queue")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(isLast).help("Later in the queue").accessibilityLabel("Move down in the queue")
        }
        .buttonStyle(.borderless)
    }
}

struct StateBadge: View {
    let state: ItemState
    var position: Int? = nil
    var paused = false

    /// "Queued · #2" for an item waiting its turn, so it's clear what runs next.
    private var label: String {
        if paused && state == .working { return "Paused" }
        if let position, state != .working, state != .done { return "Queued · #\(position)" }
        return state.label
    }

    private var color: Color {
        if paused && state == .working { return .yellow }
        if position != nil, state != .working, state != .done { return .orange }
        switch state {
        case .done: return .green
        case .failed: return .red
        case .working: return .accentColor
        default: return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
            .accessibilityLabel("Status: \(label)")
    }
}

/// The calls: the one being recorded on top, then the recorded ones.
struct CallsBox: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Calls", systemImage: "phone").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if model.isRecording {
                RecordingPanel()
                Divider()
            }
            if model.calls.isEmpty {
                if !model.isRecording {
                    VStack(spacing: 10) {
                        Image(systemName: "record.circle").font(.system(size: 36)).foregroundColor(.red)
                            .accessibilityHidden(true)
                        Text("Press Record when the call starts").font(.title3)
                        Text("Your microphone and the other side (Zoom, FaceTime, Teams, a browser, a phone call "
                             + "through your iPhone…) are recorded separately, so the transcript knows who said what.")
                            .foregroundColor(.secondary).multilineTextAlignment(.center)
                        Button("Record") { model.startRecording() }
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            } else {
                ItemList(items: model.calls, label: "Recorded calls")
            }
        }
    }
}

/// The red box while recording: time, how loud each side is, and the consent notice.
struct RecordingPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(model.recordingPaused ? Color.yellow : Color.red).frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(model.recordingPaused ? "Paused" : "Recording").fontWeight(.semibold)
                Text(clock(model.recordingElapsed)).monospacedDigit()
                Spacer()
                Button(model.recordingPaused ? "Resume" : "Pause") { model.pauseRecording(!model.recordingPaused) }
                Button("Stop") { model.stopRecording() }
            }
            LevelMeter(label: model.myName, systemImage: "mic", level: model.levels.me)
            LevelMeter(label: model.theirName, systemImage: "speaker.wave.2", level: model.levels.them)
            if !model.heardThem, model.recordingElapsed > 20, !model.recordingPaused {
                Text("Nothing heard from the other side yet. If they're talking, allow Call Transcriber under System Settings > "
                     + "Privacy & Security > Screen & System Audio Recording (System Audio Recording Only).")
                    .font(.caption).foregroundColor(.orange)
            }
            HStack {
                Text("Let everyone know the call is recorded.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Copy notice") { model.copyNotice() }
                    .help(model.noticeText)
            }
        }
        .padding(12)
        .background((model.recordingPaused ? Color.yellow : Color.red).opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.recordingPaused ? "Recording paused" : "Recording")
    }
}

struct LevelMeter: View {
    let label: String
    let systemImage: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: systemImage).frame(width: 110, alignment: .leading).lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(level > 0.8 ? Color.orange : Color.green)
                        .frame(width: geometry.size.width * CGFloat(min(1, level)))
                }
            }
            .frame(height: 8)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(Int(level * 100)) percent")
    }
}

/// Recordings and videos made elsewhere, below the calls: the same queue, its own drop area.
struct FilesBox: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Other recordings → transcript", systemImage: "waveform").font(.headline)
                Spacer()
                Button { model.add(chooseMedia(audio: false)) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add recordings or videos, or a folder of them")
                    .accessibilityLabel("Add recordings or videos")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if model.files.isEmpty {
                VStack(spacing: 6) {
                    Text("Drop recordings or videos here").font(.title3)
                    Text("MP3, M4A, WAV, MP4, MOV and more: calls recorded elsewhere, voice memos, meetings")
                        .foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ItemList(items: model.files, label: "Other recordings to transcribe")
            }
        }
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { model.add($0) }
            return true
        }
    }
}

/// The right-hand panel: the file, its speakers, what to save, and the transcript itself.
struct ItemDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var item: Item
    @State private var names: [Int: String] = [:]
    @State private var title = ""

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Thumbnail(item: item, width: 150)
                    VStack(alignment: .leading, spacing: 6) {
                        if item.kind == .call {
                            TextField("Name of the call", text: $title)
                                .onSubmit { model.rename(item, title: title) }
                                .font(.headline)
                                .help("Name the call (for example the client's name) and press Return: the saved files are renamed")
                        } else {
                            Text(item.title).font(.headline).lineLimit(3)
                        }
                        Text(info).font(.caption).foregroundColor(.secondary)
                        HStack {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(item.outputs.isEmpty ? [item.url] : item.outputs)
                            }
                            if item.kind == .call {
                                Button("Recording") { NSWorkspace.shared.activateFileViewerSelecting([item.meFile, item.themFile]) }
                                    .help("Show the two sound files: \(CallFiles.me) (your microphone) and \(CallFiles.them) (the other side)")
                            }
                        }
                    }
                }
            }
            Section { status }
            Section("Speakers") {
                if item.kind == .call {
                    Picker("People on the other side", selection: $item.speakers) {
                        Text("Work it out").tag(0)
                        ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .help("You are always your own speaker (your microphone). If several people were on the other side, say how many and press Transcribe again")
                } else {
                    Picker("People talking", selection: $item.speakers) {
                        Text("Work it out").tag(0)
                        ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .help("If you know how many people talk, say so: it helps tell similar voices apart")
                }
                if let transcript = item.transcript {
                    ForEach(transcript.speakers.indices, id: \.self) { i in
                        HStack {
                            TextField("Person \(i + 1)", text: binding(i, transcript))
                                .onSubmit { model.rename(item, speaker: i, to: names[i] ?? "") }
                                .frame(maxWidth: 160)
                            Text(firstWords(of: i, transcript)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    Text("Type a name and press Return: the saved files are written again with it.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section("Sound") {
                Picker("Clean up the sound", selection: $item.cleanup) {
                    ForEach(Cleanup.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(cleanupNote).font(.caption).foregroundColor(.secondary)
            }
            Section("Save as") {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Toggle(format.label, isOn: Binding(
                        get: { model.formats.contains(format) },
                        set: { if $0 { model.formats.insert(format) } else { model.formats.remove(format) } }))
                    .toggleStyle(.checkbox)
                }
                Toggle("Timestamps before each paragraph", isOn: $model.timestamps).toggleStyle(.checkbox)
                if item.transcript != nil {
                    Button("Save again with these settings") { model.exportAll(item) }
                }
            }
            if let transcript = item.transcript {
                Section("Transcript") {
                    TranscriptPreview(transcript: transcript)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: item.id, initial: true) {
            names = [:]
            title = item.title
        }
    }

    private var cleanupNote: String {
        switch item.cleanup {
        case .off: return "Best for most recordings: the speech model copes with noise on its own."
        case .gentle: return "Takes out rumble and hum and evens out loud and quiet voices. Try it when someone is hard to hear."
        case .strong: return "Also removes background noise and room echo. Can blur quiet words, so compare with Off."
        }
    }

    private var info: String {
        var parts = item.kind == .call ? [item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")] : [item.url.lastPathComponent]
        if let d = item.duration { parts.append(clock(d)) }
        if let t = item.transcript { parts.append("\(t.wordCount) words, \(t.speakers.count) speaker\(t.speakers.count == 1 ? "" : "s")") }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .working:
            VStack(alignment: .leading) {
                ProgressView(value: item.progress)
                Text(item.detail).font(.caption).foregroundColor(.secondary)
            }
        case .done:
            HStack {
                Label("Finished", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                Spacer()
                Button("Transcribe again") { model.again(item) }
            }
        case .failed:
            HStack {
                Label(item.error, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red)
                Spacer()
                Button("Try again") { model.again(item) }
            }
        case .waiting, .stopped:
            HStack {
                Text(model.queuePosition(item.id).map { "Queued · #\($0)" } ?? item.state.label)
                Spacer()
                if model.queuePosition(item.id) == nil { Button("Transcribe") { model.again(item) } }
            }
        }
    }

    private func binding(_ i: Int, _ t: Transcript) -> Binding<String> {
        Binding(get: { names[i] ?? (t.speakers[i] == "Person \(i + 1)" ? "" : t.speakers[i]) },
                set: { names[i] = $0 })
    }

    /// The first thing a speaker says, to help tell who's who.
    private func firstWords(of speaker: Int, _ t: Transcript) -> String {
        guard let p = t.paragraphs.first(where: { $0.speaker == speaker && $0.words.count >= 4 })
                ?? t.paragraphs.first(where: { $0.speaker == speaker }) else { return "" }
        return "“" + p.words.prefix(10).map(\.text).joined(separator: " ") + "…” at \(clock(p.start))"
    }
}

/// The transcript, as it will read in the saved files.
struct TranscriptPreview: View {
    let transcript: Transcript

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(transcript.paragraphs.indices, id: \.self) { i in
                let p = transcript.paragraphs[i]
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(transcript.name(of: p.speaker)).fontWeight(.semibold)
                        Text(clock(p.start)).font(.caption).foregroundColor(.secondary)
                    }
                    Text(p.text).textSelection(.enabled)
                }
            }
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.log.indices, id: \.self) { i in
                        Text(model.log[i]).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                    if let item = model.items.first(where: { $0.state == .working }) {
                        Text(item.detail).font(.system(.caption, design: .monospaced)).fontWeight(.bold).padding(.top, 6)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.log.count) { proxy.scrollTo(model.log.count - 1) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("Log")
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Output") {
                HStack {
                    Text(model.outputFolder.path).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choose…") { if let url = chooseFolder("Choose where transcripts are saved") { model.outputPath = url.path } }
                    if !model.outputPath.isEmpty { Button("Default") { model.outputPath = "" } }
                }
            }
            Section("Calls") {
                LabeledContent("You in transcripts") { TextField("", text: $model.myName).frame(maxWidth: 160) }
                LabeledContent("The other side") { TextField("", text: $model.theirName).frame(maxWidth: 160) }
                Toggle("Remind me to tell the other person before recording", isOn: $model.consentReminder)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notice to read out or paste into the chat")
                    TextEditor(text: $model.noticeText).frame(height: 54).font(.callout)
                    if model.noticeText != AppModel.defaultNotice {
                        Button("Default") { model.noticeText = AppModel.defaultNotice }
                    }
                }
                Text("Recordings are kept in \(model.recordingsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")), one folder per call.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Queue") {
                Toggle("Start transcribing as soon as files are added", isOn: $model.startWhenAdded)
                Picker("Clean up the sound for new files", selection: $model.defaultCleanup) {
                    ForEach(Cleanup.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section("Privacy") {
                Text("Everything happens on this Mac. Recordings and transcripts are never uploaded.")
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
    }
}
