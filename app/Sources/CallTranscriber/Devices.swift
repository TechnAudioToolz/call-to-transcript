import CoreAudio
import Foundation

/// A sound card (or microphone) that can be recorded from.
struct InputDevice: Identifiable, Hashable {
    /// Core Audio's UID: stays the same across restarts and replugging, unlike the device's number.
    let id: String
    let name: String
    let channels: Int
}

/// The Mac's sound devices, from Core Audio.
enum AudioDevices {
    /// Everything with at least one input channel, by name.
    static func inputs() -> [InputDevice] {
        allDevices().compactMap { device in
            let channels = channelCount(device, scope: kAudioObjectPropertyScopeInput)
            guard channels > 0, let uid = uid(device) else { return nil }
            return InputDevice(id: uid, name: name(device) ?? uid, channels: channels)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func device(uid: String) -> AudioDeviceID? {
        allDevices().first { self.uid($0) == uid }
    }

    static func defaultInput() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func inputChannels(_ device: AudioDeviceID) -> Int {
        channelCount(device, scope: kAudioObjectPropertyScopeInput)
    }

    static func hasOutput(_ device: AudioDeviceID) -> Bool {
        channelCount(device, scope: kAudioObjectPropertyScopeOutput) > 0
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(_ device: AudioDeviceID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
