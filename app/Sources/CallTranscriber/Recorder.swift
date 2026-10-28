import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Records a call as two files in `folder`: Me.caf from the microphone, and Them.caf from the Mac's sound (Zoom,
/// FaceTime, a phone call through the iPhone, a browser…). Both start at the same moment, so the engine can lay
/// the two sides side by side. AAC in CAF: small (about 0.5 MB a minute each), and readable even if the app quits
/// in the middle of a call.
///
/// The Mac's sound comes from a Core Audio process tap (macOS 14.2 and newer): a copy of what every app plays,
/// before it reaches the speakers or headphones. It needs the "System Audio Recording" permission, which macOS
/// asks for the first time; nothing else about the call apps changes.
/// The two files in a call's folder.
enum CallFiles {
    static let me = "Me.caf"
    static let them = "Them.caf"
    /// Both sides together, to listen to (made when recording stops).
    static let both = "Call.m4a"

    /// Mixes Me.caf and Them.caf in `folder` into Call.m4a.
    static func mix(_ folder: URL) async throws {
        let composition = AVMutableComposition()
        for name in [me, them] {
            let asset = AVURLAsset(url: folder.appendingPathComponent(name))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: source, at: .zero)
        }
        let output = folder.appendingPathComponent(both)
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return }
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        if let error = export.error { throw error }
    }
}

@available(macOS 14.2, *)
final class CallRecorder: @unchecked Sendable {
    enum Track { case me, them }

    let folder: URL
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var files: [Track: AVAudioFile] = [:]
    private var levels: [Track: Float] = [.me: 0, .them: 0]
    private var heardThem = false
    private var paused = false
    private var startedAt = Date()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let tapQueue = DispatchQueue(label: "Call Transcriber: the Mac's sound", qos: .userInitiated)

    init(folder: URL) {
        self.folder = folder
    }

    // MARK: start and stop

    func start() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        startedAt = Date()
        try startMicrophone()
        do {
            try startMacSound()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
        lock.lock()
        files = [:]  // closes them
        lock.unlock()
    }

    /// While paused nothing is written to either file, so the two stay in step.
    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        levels = [.me: 0, .them: 0]
        lock.unlock()
    }

    /// How loud each side is right now (0-1), for the meters; falls back towards 0 between reads.
    func readLevels() -> (me: Float, them: Float, heardThem: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let now = (levels[.me] ?? 0, levels[.them] ?? 0, heardThem)
        levels[.me] = (levels[.me] ?? 0) * 0.5
        levels[.them] = (levels[.them] ?? 0) * 0.5
        return now
    }

    // MARK: microphone

    private func startMicrophone() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        let file = try Self.makeFile(folder.appendingPathComponent(CallFiles.me), sampleRate: format.sampleRate)
        lock.lock()
        files[.me] = file
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.write(buffer, to: .me)
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: the Mac's sound

    private func startMacSound() throws {
        // Everything the Mac plays except this app's own sound, mixed to one channel.
        let ownProcess = Self.processObject(for: getpid())
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.name = "Call Transcriber"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the sound tap")

        // A tap is read through a private "aggregate device" clocked by the speakers or headphones.
        let output = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Call Transcriber",
            kAudioAggregateDeviceUIDKey: "com.technaudiotoolz.calltranscriber.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "set up the sound tap")

        var tapFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &tapFormat), "read the sound tap's format")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: tapFormat.mSampleRate,
                                         channels: 1, interleaved: false),
              tapFormat.mFormatID == kAudioFormatLinearPCM, tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else { throw RecorderError.coreAudio("use the sound tap's format", 0) }
        let channels = Int(max(1, tapFormat.mChannelsPerFrame))
        let file = try Self.makeFile(folder.appendingPathComponent(CallFiles.them), sampleRate: tapFormat.mSampleRate)
        lock.lock()
        files[.them] = file
        lock.unlock()

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, tapQueue) { [weak self] _, input, _, _, _ in
            // The tap's sound is the last input stream (the speakers have none of their own; a headset might).
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let last = buffers.last, let data = last.mData else { return }
            let frames = Int(last.mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int(last.mNumberChannels)))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            let source = data.assumingMemoryBound(to: Float.self)
            let step = Int(last.mNumberChannels) > 0 ? Int(last.mNumberChannels) : channels
            let target = buffer.floatChannelData![0]
            for i in 0..<frames { target[i] = source[i * step] }
            self?.write(buffer, to: .them)
        }, "read the sound tap")
        try check(AudioDeviceStart(aggregateID, procID), "start the sound tap")
    }

    // MARK: writing

    /// Writes one channel of `buffer`. The first time, silence goes in first for the time since Record was
    /// pressed, so both files start at the same moment.
    private func write(_ buffer: AVAudioPCMBuffer, to track: Track) {
        lock.lock()
        defer { lock.unlock() }
        guard !paused, let file = files[track], buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames { sum += channel[i] * channel[i] }
        let level = min(1, sqrt(sum / Float(frames)) * 4)
        levels[track] = max(levels[track] ?? 0, level)
        if track == .them, level > 0.01 { heardThem = true }

        let mono = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        mono.frameLength = AVAudioFrameCount(frames)
        mono.floatChannelData![0].update(from: channel, count: frames)
        do {
            if file.length == 0 {
                let lead = Int(Date().timeIntervalSince(startedAt) * file.processingFormat.sampleRate) - frames
                if lead > 0, let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(lead)) {
                    silence.frameLength = AVAudioFrameCount(lead)
                    memset(silence.floatChannelData![0], 0, lead * MemoryLayout<Float>.size)
                    try file.write(from: silence)
                }
            }
            try file.write(from: mono)
        } catch {
            NSLog("Call Transcriber: couldn't write %@: %@", file.url.lastPathComponent, error.localizedDescription)
        }
    }

    private static func makeFile(_ url: URL, sampleRate: Double) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    // MARK: Core Audio lookups

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw RecorderError.coreAudio(what, status) }
    }

    /// Core Audio's id for a running process, if it has used sound.
    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw RecorderError.coreAudio("find the speakers", status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw RecorderError.coreAudio("find the speakers", status) }
        return uid.takeRetainedValue() as String
    }
}

enum RecorderError: LocalizedError {
    case noMicrophone
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone was found"
        case .coreAudio(let what, let status): return "Couldn't \(what) (Core Audio error \(status))"
        }
    }
}
