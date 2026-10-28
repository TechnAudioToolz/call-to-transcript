import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct CallTranscriberApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Hover text appears after half a second instead of the Mac's usual second or so.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
    }

    var body: some Scene {
        WindowGroup("Call Transcriber") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    model.restoreQueue()  // the files from last time
                    if model.startWhenAdded, !model.queueOrder.isEmpty { model.startQueue() }  // e.g. a call recorded before the app was quit
                    handleLaunchArguments()
                }
                .onOpenURL { model.add([$0]) }  // files dropped on the app's Dock icon
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("Support this project…") { openDonatePage() }
                Button("Project on GitHub") { NSWorkspace.shared.open(projectURL) }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }

    /// Optional launch arguments, for scripting and testing:
    ///   open -a "Call Transcriber" --args --add video.mp4 --add talk.mp3 --start --keep-awake
    ///   open -a "Call Transcriber" --args --record-for 30     (record for 30 seconds, then stop: for testing)
    ///   open -a "Call Transcriber" --args --add-call FOLDER   (a call recorded earlier: FOLDER has Me.caf and Them.caf)
    func handleLaunchArguments() {
        let args = CommandLine.arguments
        let files = zip(args, args.dropFirst()).filter { $0.0 == "--add" }.map { URL(fileURLWithPath: $0.1) }
        if !files.isEmpty { model.add(files) }
        if args.contains("--keep-awake") { KeepAwake.shared.isOn = true }
        for folder in zip(args, args.dropFirst()).filter({ $0.0 == "--add-call" }).map({ URL(fileURLWithPath: $0.1) }) {
            model.addCall(folder)
        }
        if args.contains("--start") { model.startQueue() }
        if let i = args.firstIndex(of: "--record-for"), args.indices.contains(i + 1), let seconds = Double(args[i + 1]) {
            model.startRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 1) { model.stopRecording() }
        }
        if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
            startSnapshots(to: URL(fileURLWithPath: args[i + 1]))
        }
    }

    /// For testing and README images: saves a picture of the window to `file` every 3 seconds.
    func startSnapshots(to file: URL) {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            DispatchQueue.main.async {
                guard let frame = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil })?.contentView?.superview,
                      let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
        }
    }
}

// Not published yet; Transcript Maker's page until Call Transcriber has its own.
let projectURL = URL(string: "https://github.com/TechnAudioToolz/video-audio-to-transcript")!

/// The donation page ships inside the app and opens in the default browser.
func openDonatePage() {
    if let page = Bundle.main.url(forResource: "donate", withExtension: "html") {
        NSWorkspace.shared.open(page)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VSplitView {
                    CallsBox()
                        .frame(minHeight: 200)
                    FilesBox()
                        .frame(minHeight: 120, idealHeight: 180)
                }
                .frame(minWidth: 320, idealWidth: 420)
                detail
                    .frame(minWidth: 380)
            }
            if model.showLog {
                Divider()
                LogView()
                    .frame(height: 200)
            }
            statusBar
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isRecording {
                    if model.recordingPaused {
                        Button { model.pauseRecording(false) } label: { Label("Resume recording", systemImage: "record.circle") }
                            .keyboardShortcut("p")
                            .help(tip("Resume recording"))
                    } else {
                        Button { model.pauseRecording(true) } label: { Label("Pause recording", systemImage: "pause.fill") }
                            .keyboardShortcut("p")
                            .help(tip("Pause recording"))
                    }
                    Button { model.stopRecording() } label: { Label("Stop recording", systemImage: "stop.fill") }
                        .keyboardShortcut(".")
                        .help(tip("Stop recording"))
                } else {
                    Button { model.startRecording() } label: {
                        Label("Record", systemImage: "record.circle").foregroundStyle(.red)
                    }
                    .keyboardShortcut("r")
                    .help(tip("Record"))
                }
                Button { model.add(chooseMedia(audio: false)) } label: { Label("Add files", systemImage: "plus") }
                    .help(tip("Add files"))
                    .keyboardShortcut("o")
                if model.isRecording {
                    // transcribing waits during a call
                } else if model.isRunning {
                    if model.isPaused {
                        Button { model.resume() } label: { Label("Resume", systemImage: "play.fill") }
                            .keyboardShortcut("p")
                            .help(tip("Resume"))
                    } else {
                        Button { model.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                            .keyboardShortcut("p")
                            .help(tip("Pause"))
                    }
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .keyboardShortcut(".")
                        .help(tip("Stop"))
                } else {
                    Button { model.startQueue() } label: { Label("Start queue", systemImage: "play.fill") }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .help(tip("Start queue"))
                        .disabled(model.queueOrder.isEmpty)
                }
                Button {
                    try? FileManager.default.createDirectory(at: model.outputFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.outputFolder)
                } label: { Label("Output folder", systemImage: "folder") }
                    .help(tip("Output folder"))
                Toggle(isOn: $model.showLog) { Label("Verbose mode", systemImage: "text.alignleft") }
                    .keyboardShortcut("l")
                    .help(tip("Verbose mode"))
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help(tip("Settings"))
                Button { openDonatePage() } label: { Label("Donate", systemImage: "heart") }
                    .help(tip("Donate"))
                KeepAwakeButton()
            }
        }
        // SwiftUI's .help doesn't always show on toolbar buttons, so the toolbar items get the same text as
        // ordinary Mac tooltips too, again whenever a button changes (Pause/Resume, the cup).
        .onAppear { applyToolbarTips() }
        .onChange(of: model.isRunning) { applyToolbarTips() }
        .onChange(of: model.isPaused) { applyToolbarTips() }
        .onChange(of: model.isRecording) { applyToolbarTips() }
        .onChange(of: model.recordingPaused) { applyToolbarTips() }
        .onReceive(KeepAwake.shared.$isOn) { _ in applyToolbarTips() }
    }

    /// What each toolbar button does, shown when the mouse rests on it. Keyed by the button's label.
    private func tip(_ label: String) -> String {
        switch label {
        case "Record": return "Record (⌘R): record a call, your microphone and the Mac's sound (the other side)"
        case "Pause recording": return "Pause recording (⌘P): leave out part of the call; nothing is recorded until you resume"
        case "Resume recording": return "Resume recording (⌘P)"
        case "Stop recording": return "Stop recording (⌘.): end the recording and make the transcript"
        case "Add files": return "Add files (⌘O): recordings or videos to transcribe, or a folder of them"
        case "Start queue": return "Start queue (⇧⌘R): transcribe the queued calls and files, one after another"
        case "Pause": return "Pause (⌘P): freeze the transcript being made; it uses no CPU until you resume"
        case "Resume": return "Resume (⌘P): carry on making the transcript"
        case "Stop": return "Stop (⌘.): stop the queue; the file being transcribed starts over next time"
        case "Output folder": return "Open the output folder: where finished transcripts are saved"
        case "Verbose mode": return "Verbose mode (⌘L): show what the engine is doing, with progress and time left"
        case "Settings": return "Settings (⌘,)"
        case "Donate": return "Donate: support this project"
        case "No sleep mode": return KeepAwakeButton.tip
        default: return ""
        }
    }

    private func applyToolbarTips() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {  // after SwiftUI has rebuilt the toolbar
            for window in NSApp.windows {
                for item in window.toolbar?.items ?? [] where !tip(item.label).isEmpty {
                    item.toolTip = tip(item.label)
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let item = model.selectedItem {
            ItemDetail(item: item)
        } else {
            Text("Press Record during a call, or select a call to see its transcript")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.lastMessage)
            Spacer()
            Text("Output: \(model.outputFolder.path)").lineLimit(1).truncationMode(.head)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct KeepAwakeButton: View {
    @ObservedObject var keepAwake = KeepAwake.shared

    var body: some View {
        Toggle(isOn: $keepAwake.isOn) {
            Label("No sleep mode", systemImage: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
        .help(Self.tip)
    }

    @MainActor static var tip: String {
        KeepAwake.shared.isOn
            ? "No sleep mode is on: the Mac won't go to sleep while the app is open. Click to turn it off."
            : "No sleep mode: keep the Mac awake while the app is open, so transcripts keep being made when you "
              + "walk away. The screen can still turn off; closing a laptop's lid still sleeps it."
    }
}

/// Standard macOS open panel; files and folders can be picked together.
@MainActor
func chooseMedia(audio: Bool) -> [URL] {
    let panel = NSOpenPanel()
    panel.title = audio ? "Add audio" : "Add recordings or videos"
    panel.prompt = "Add"
    panel.message = audio ? "Choose audio files (MP3, M4A, WAV…), or a folder of them"
                          : "Choose videos or audio files, or a folder of them"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    let types = (audio ? AppModel.audioTypes : AppModel.videoTypes + AppModel.audioTypes)
        .compactMap { UTType(filenameExtension: $0) }
    panel.allowedContentTypes = types + [.folder]
    return panel.runModal() == .OK ? panel.urls : []
}

func chooseFolder(_ message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.message = message
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
}

/// Turns dropped Finder items into file URLs.
func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock(); urls.append(url); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}
