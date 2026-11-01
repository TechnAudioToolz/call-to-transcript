import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// One input to record: a sound card (its Core Audio UID; nil is the Mac's default input when Record is pressed)
/// and one of its channels (0 mixes them all).
struct InputChoice: Sendable, Equatable {
    var uid: String?
    var channel: Int
}

/// The files in a call's folder. Each input is recorded on its own (Input.caf, Input 2.caf), the Mac's sound as
/// Them.caf in two-track mode; when recording stops they're combined.
enum CallFiles {
    static let input = "Input.caf"
    static let them = "Them.caf"
    /// Everything together: to listen to, and what's transcribed when voices are told apart.
    static let both = "Call.m4a"
    /// The inputs together: your side, in two-track mode.
    static let mine = "Me.m4a"
    /// Your side in calls recorded before there could be two inputs.
    static let me = "Me.caf"

    static func inputName(_ index: Int) -> String { index == 0 ? input : "Input \(index + 1).caf" }

    /// The inputs recorded in `folder`, in order.
    static func inputs(in folder: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for i in 0..<8 {
            let url = folder.appendingPathComponent(inputName(i))
            guard fm.fileExists(atPath: url.path) else { break }
            found.append(url)
        }
        let legacy = folder.appendingPathComponent(me)
        return found.isEmpty && fm.fileExists(atPath: legacy.path) ? [legacy] : found
    }

    /// After recording: Call.m4a from everything, and in two-track mode Me.m4a from the inputs.
    static func combine(_ folder: URL) async throws {
        let inputs = inputs(in: folder)
        let them = folder.appendingPathComponent(them)
        let twoTrack = FileManager.default.fileExists(atPath: them.path)
        try await mix(inputs + (twoTrack ? [them] : []), to: folder.appendingPathComponent(both))
        if twoTrack { try await mix(inputs, to: folder.appendingPathComponent(mine)) }
    }

    /// Plays `files` together from the start, as one mono AAC file.
    static func mix(_ files: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        for file in files {
            let asset = AVURLAsset(url: file)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: source, at: .zero)
        }
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return }
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        if let error = export.error { throw error }
    }
}

/// Records a call into `folder`: each input (a channel of a sound card, a microphone) to its own file, and in
/// two-track mode the Mac's sound (Zoom, FaceTime, a phone call through the iPhone, a browser…) as Them.caf. All
/// start at the same moment. AAC in CAF: small (about 0.5 MB a minute each), and readable even if the app quits
/// in the middle of a call. Each input has its own audio engine pinned to its device, so the recording never
/// follows changes of the Mac's default input. With no folder it only measures levels (Settings' Test).
///
/// The Mac's sound comes from a Core Audio process tap (macOS 14.2 and newer): a copy of what every app plays,
/// before it reaches the speakers or headphones. It needs the "System Audio Recording" permission, which macOS
/// asks for the first time; nothing else about the call apps changes.
@available(macOS 14.2, *)
final class CallRecorder: @unchecked Sendable {
    enum Track: Hashable { case input(Int), them }

    let folder: URL?
    let inputs: [InputChoice]
    /// Also record the Mac's sound (the other side of a call) as its own track.
    let macSound: Bool
    /// Called (on any thread) if an input device stops or changes while recording.
    var onProblem: (@Sendable (String) -> Void)?
    private var engines: [AVAudioEngine] = []
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    private var files: [Track: AVAudioFile] = [:]
    private var levels: [Track: Float] = [:]
    private var heardThem = false
    private var paused = false
    private var startedAt = Date()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let tapQueue = DispatchQueue(label: "Call Transcriber: the Mac's sound", qos: .userInitiated)

    init(folder: URL?, inputs: [InputChoice], macSound: Bool) {
        self.folder = folder
        self.inputs = inputs
        self.macSound = macSound
    }

    // MARK: start and stop

    func start() throws {
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        startedAt = Date()
        do {
            for (i, input) in inputs.enumerated() { try startInput(i, input) }
            if macSound { try startMacSound() }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for engine in engines {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engines = []
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

    /// While paused nothing is written to any file, so they stay in step.
    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        levels = [:]
        lock.unlock()
    }

    /// How loud each input and the other side are right now (0-1), for the meters; falls back towards 0
    /// between reads.
    func readLevels() -> (inputs: [Float], them: Float, heardThem: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let now = (inputs.indices.map { levels[.input($0)] ?? 0 }, levels[.them] ?? 0, heardThem)
        for key in levels.keys { levels[key]! *= 0.5 }
        return now
    }

    // MARK: inputs

    private func startInput(_ index: Int, _ choice: InputChoice) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let device = try choice.uid.map { uid -> AudioDeviceID in
            guard let device = AudioDevices.device(uid: uid) else { throw RecorderError.inputMissing(index + 1) }
            return device
        } ?? AudioDevices.defaultInput()
        // Pin the engine to this device, so it records from it however the Mac's default changes.
        if var device, let unit = input.audioUnit {
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "use input \(index + 1)")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        if choice.channel > Int(format.channelCount) {
            throw RecorderError.noChannel(index + 1, choice.channel, Int(format.channelCount))
        }
        if let folder {
            let file = try Self.makeFile(folder.appendingPathComponent(CallFiles.inputName(index)), sampleRate: format.sampleRate)
            lock.lock()
            files[.input(index)] = file
            lock.unlock()
        }
        let channel = choice.channel
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.write(buffer, channel: channel, to: .input(index))
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak self] _ in
            self?.onProblem?("Input \(index + 1) changed or was unplugged; the recording may have stopped hearing it")
        })
        engines.append(engine)
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

        // A tap is read through a private "aggregate device" clocked by a real device: the chosen sound card if
        // it has outputs, otherwise the speakers or headphones in use now (and those stay, whatever changes later).
        let output = try inputs.first?.uid.flatMap { AudioDevices.device(uid: $0) }.flatMap { AudioDevices.hasOutput($0) ? $0 : nil }
            .flatMap(AudioDevices.uid) ?? Self.defaultOutputUID()
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
        if let folder {
            let file = try Self.makeFile(folder.appendingPathComponent(CallFiles.them), sampleRate: tapFormat.mSampleRate)
            lock.lock()
            files[.them] = file
            lock.unlock()
        }

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
            self?.write(buffer, channel: 1, to: .them)
        }, "read the sound tap")
        try check(AudioDeviceStart(aggregateID, procID), "start the sound tap")
    }

    // MARK: writing

    /// Writes `channel` of `buffer` (0: all channels mixed). The first time, silence goes in first for the time
    /// since Record was pressed, so all the files start at the same moment.
    private func write(_ buffer: AVAudioPCMBuffer, channel: Int, to track: Track) {
        lock.lock()
        defer { lock.unlock() }
        guard !paused, buffer.frameLength > 0, let data = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1)!,
                                          frameCapacity: buffer.frameLength) else { return }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        mono.frameLength = buffer.frameLength
        let out = mono.floatChannelData![0]
        // the chosen channel of the sound card, or all of them mixed
        if count == 1 || channel > 0 {
            out.update(from: data[min(max(channel, 1), count) - 1], count: frames)
        } else {
            out.update(repeating: 0, count: frames)
            for c in 0..<count { for i in 0..<frames { out[i] += data[c][i] / Float(count) } }
        }
        var sum: Float = 0
        for i in 0..<frames { sum += out[i] * out[i] }
        let level = min(1, sqrt(sum / Float(frames)) * 4)
        levels[track] = max(levels[track] ?? 0, level)
        if track == .them, level > 0.01 { heardThem = true }

        guard let file = files[track] else { return }  // testing: levels only
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
    case inputMissing(Int)
    case noChannel(Int, Int, Int)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone was found"
        case .inputMissing(let i): return "The sound card for input \(i) isn't connected. Plug it in, or choose another in Settings > Recording."
        case .noChannel(let i, let c, let n): return "Input \(i)'s sound card has \(n) channel\(n == 1 ? "" : "s"), so channel \(c) can't be recorded. Choose another in Settings > Recording."
        case .coreAudio(let what, let status): return "Couldn't \(what) (Core Audio error \(status))"
        }
    }
}
