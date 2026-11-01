import AppKit
import AVFoundation
import Foundation
import TranscriptCore

/// Record, Pause and Stop for calls. While a call is recorded, transcribing waits, the Mac stays awake, and a red
/// sign shows in the window, the Dock and the menu bar.
extension AppModel {
    var isRecording: Bool { recorder != nil }

    @available(macOS 14.2, *)
    private var callRecorder: CallRecorder? { recorder as? CallRecorder }

    func startRecording() {
        guard !isRecording else { return }
        guard #available(macOS 14.4, *) else {
            alert("Recording calls needs macOS 14.4 or newer",
                  "This Mac can still transcribe recordings and videos: drop them in the list below.")
            return
        }
        if consentReminder, !confirmConsent() { return }
        Task { @MainActor in
            guard await microphoneAllowed() else {
                alert("Call Transcriber can't hear the microphone",
                      "Allow it in System Settings > Privacy & Security > Microphone, then press Record again.",
                      settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return
            }
            beginRecording()
        }
    }

    @available(macOS 14.4, *)
    private func beginRecording() {
        let name = "Call " + Self.callStamp.string(from: Date())
        stopTest()
        let tracks = speakerMode == .tracks
        let recorder = CallRecorder(folder: uniqueFolder(recordingsFolder.appendingPathComponent(name)),
                                    inputs: inputChoices, macSound: tracks)
        recorder.onProblem = { [weak self] problem in
            Task { @MainActor in
                self?.appendLog("    " + problem)
                self?.lastMessage = problem
            }
        }
        if isRunning, !isPaused {  // a transcript being made waits until the call is over
            pause()
            pausedForCall = true
        }
        do {
            try recorder.start()
        } catch {
            alert("Couldn't start recording", error.localizedDescription)
            resumeAfterCall()
            return
        }
        self.recorder = recorder
        recordingTracks = tracks
        recordingPaused = false
        recordingStarted = Date()
        pausedTotal = 0
        pausedAt = nil
        recordingElapsed = 0
        heardThem = false
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                              reason: "Call Transcriber: recording a call")
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RecordingSign.shared.show(model: self)
        appendLog("— Recording \(recorder.folder!.lastPathComponent)")
        appendLog("    Files: \(recorder.folder!.path)")
        for (i, input) in recorder.inputs.enumerated() { appendLog("    Input \(i + 1): \(describe(input))") }
        if tracks { appendLog("    The other side: the Mac's sound") }
        lastMessage = "Recording. Press Stop (⌘.) when the call is over."
    }

    func pauseRecording(_ value: Bool) {
        guard #available(macOS 14.2, *), let recorder = callRecorder, recordingPaused != value else { return }
        recorder.setPaused(value)
        recordingPaused = value
        if value {
            pausedAt = Date()
        } else if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
        appendLog(value ? "    Recording paused" : "    Recording again")
        RecordingSign.shared.update(model: self)
    }

    /// Ends the recording and puts the call first in the queue to be transcribed.
    func stopRecording() {
        guard #available(macOS 14.2, *), let recorder = callRecorder else { return }
        recorder.stop()
        self.recorder = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
        RecordingSign.shared.hide()
        inputLevels = []
        themLevel = 0
        appendLog("    Recorded \(clock(recordingElapsed))")

        let folder = recorder.folder!
        let item = Item(url: folder, kind: .call)
        item.title = folder.lastPathComponent
        item.speakers = recorder.macSound ? 1 : 0  // one person on the other side, or work out how many voices
        item.cleanup = defaultCleanup
        item.duration = recordingElapsed
        items.append(item)
        selection = item.id
        lastMessage = "Recorded \(item.title)"
        if recorder.macSound, !heardThem {
            appendLog("    Nothing was heard from the other side. If they spoke, allow System Audio Recording for "
                      + "Call Transcriber in System Settings > Privacy & Security > Screen & System Audio Recording.")
        }
        // the inputs (and the other side) combined into one recording; then it's transcribed
        item.detail = "Combining the recording…"
        Task {
            do {
                try await CallFiles.combine(folder)
                appendLog("    Combined into \(CallFiles.both)")
            } catch {
                appendLog("    Couldn't combine the recording: \(error.localizedDescription)")
            }
            item.detail = ""
            queueOrder.insert(item.id, at: 0)
            saveQueue()
            resumeAfterCall()
            if startWhenAdded { startQueue() }
        }
    }

    /// "Scarlett 4i4 USB, channel 1"
    func describe(_ input: InputChoice) -> String {
        let device = (input.uid.flatMap(AudioDevices.device(uid:)) ?? AudioDevices.defaultInput()).flatMap(AudioDevices.name)
            ?? "the Mac's default input"
        return device + (input.channel == 0 ? ", all channels" : ", channel \(input.channel)")
    }

    // MARK: testing the inputs

    var isTesting: Bool { tester != nil }

    /// Settings' Test: the meters move with each input for a minute, nothing is recorded.
    func startTest() {
        guard #available(macOS 14.2, *), !isTesting, !isRecording else { return }
        Task { @MainActor in
            guard await microphoneAllowed() else {
                alert("Call Transcriber can't hear the inputs",
                      "Allow it in System Settings > Privacy & Security > Microphone.",
                      settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return
            }
            let tester = CallRecorder(folder: nil, inputs: inputChoices, macSound: false)
            do {
                try tester.start()
            } catch {
                alert("Couldn't test the inputs", error.localizedDescription)
                return
            }
            self.tester = tester
            let started = Date()
            testTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let tester = self.tester as? CallRecorder else { return }
                    self.inputLevels = tester.readLevels().inputs
                    if Date().timeIntervalSince(started) > 60 { self.stopTest() }
                }
            }
        }
    }

    func stopTest() {
        guard #available(macOS 14.2, *) else { return }
        (tester as? CallRecorder)?.stop()
        tester = nil
        testTimer?.invalidate()
        testTimer = nil
        if !isRecording { inputLevels = [] }
    }

    /// A call recorded earlier (a folder with Input.caf, Input 2.caf…, and Them.caf in two-track mode), e.g. one
    /// copied from another Mac.
    func addCall(_ folder: URL) {
        let twoTrack = FileManager.default.fileExists(atPath: folder.appendingPathComponent(CallFiles.them).path)
        guard !CallFiles.inputs(in: folder).isEmpty else {
            lastMessage = "\(folder.lastPathComponent) doesn't have \(CallFiles.input)"
            return
        }
        guard !items.contains(where: { $0.url == folder }) else { return }
        let item = Item(url: folder, kind: .call)
        item.speakers = twoTrack ? 1 : 0
        item.cleanup = defaultCleanup
        items.append(item)
        queueOrder.append(item.id)
        selection = item.id
        Task { await item.loadDetails() }
        saveQueue()
        if startWhenAdded { startQueue() }
    }

    private func resumeAfterCall() {
        if pausedForCall { resume() }
        pausedForCall = false
    }

    private func tick() {
        guard #available(macOS 14.2, *), let recorder = callRecorder else { return }
        let now = Date()
        recordingElapsed = now.timeIntervalSince(recordingStarted) - pausedTotal - (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
        let read = recorder.readLevels()
        inputLevels = read.inputs
        themLevel = read.them
        if read.heardThem, !heardThem { heardThem = true }
        RecordingSign.shared.update(model: self)
    }

    // MARK: asking

    /// The first time (and every time, unless turned off): some places require everyone on a call to agree to
    /// it being recorded.
    private func confirmConsent() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Does everyone on the call know it's being recorded?"
        alert.informativeText = "In many places everyone on a call must agree before it's recorded (in some US states, "
            + "Canada, the EU, the UK, Australia and elsewhere, the rules differ). Tell the other person at the start, "
            + "or paste the notice into the chat: the Copy notice button is next to the recording timer, and the "
            + "words are in Settings.\n\nThe recording and transcript stay on this Mac."
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on, answer == .alertFirstButtonReturn { consentReminder = false }
        return answer == .alertFirstButtonReturn
    }

    func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func copyNotice() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(noticeText, forType: .string)
        lastMessage = "Notice copied: paste it into the call's chat"
    }

    private func alert(_ title: String, _ text: String, settings: String? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if settings != nil {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        }
        if alert.runModal() == .alertFirstButtonReturn, let settings, let url = URL(string: settings) {
            NSWorkspace.shared.open(url)
        }
    }

    private func uniqueFolder(_ folder: URL) -> URL {
        var candidate = folder
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent) \(n)")
            n += 1
        }
        return candidate
    }

    /// "2026-10-28 14.05"
    static let callStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()
}

/// While recording: a red dot and the time in the menu bar (seen even when the call app covers the window), and
/// "REC" on the Dock icon. Clicking the menu bar item brings the window forward.
@MainActor
final class RecordingSign {
    static let shared = RecordingSign()
    private var item: NSStatusItem?

    func show(model: AppModel) {
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.target = self
            item?.button?.action = #selector(bringForward)
            item?.button?.toolTip = "Call Transcriber is recording. Click to show the window."
        }
        update(model: model)
    }

    func update(model: AppModel) {
        let paused = model.recordingPaused
        let title = NSMutableAttributedString(string: paused ? "❚❚ " : "● ", attributes: [
            .foregroundColor: paused ? NSColor.systemYellow : NSColor.systemRed,
            .font: NSFont.menuBarFont(ofSize: 0),
        ])
        title.append(NSAttributedString(string: clock(model.recordingElapsed),
                                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)]))
        item?.button?.attributedTitle = title
        NSApp.dockTile.badgeLabel = paused ? "Paused" : "REC"
    }

    func hide() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        NSApp.dockTile.badgeLabel = nil
    }

    @objc private func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.toolbar != nil }?.makeKeyAndOrderFront(nil)
    }
}
