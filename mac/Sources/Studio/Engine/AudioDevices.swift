// CoreAudio device list (microphones, headphone outputs), hot-plug notifications and the speaker/mic feedback check.
import Foundation
import CoreAudio

struct AudioDeviceInfo: Identifiable, Hashable {
    enum Transport: String { case builtIn = "Built-in", usb = "USB", bluetooth = "Bluetooth", aggregate = "Aggregate", virtual = "Virtual", hdmi = "HDMI/DisplayPort", other = "Other" }
    var id: AudioDeviceID
    var uid: String
    var name: String
    var hasInput: Bool
    var hasOutput: Bool
    var transport: Transport
    /// Built-in laptop speakers (as opposed to the headphone jack of the same device).
    var isBuiltInSpeaker: Bool
    var label: String { transport == .other ? name : "\(name) (\(transport.rawValue))" }
}

enum AudioDevices {
    static func all() -> [AudioDeviceInfo] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(info(for:))
    }

    static func info(for id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(id, kAudioObjectPropertyName) ?? uid
        let tr = UInt32Value(id, kAudioDevicePropertyTransportType) ?? 0
        let transport: AudioDeviceInfo.Transport
        switch tr {
        case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
        case kAudioDeviceTransportTypeUSB: transport = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
        case kAudioDeviceTransportTypeAggregate: transport = .aggregate
        case kAudioDeviceTransportTypeVirtual: transport = .virtual
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: transport = .hdmi
        default: transport = .other
        }
        let out = channels(id, kAudioDevicePropertyScopeOutput) > 0, inp = channels(id, kAudioDevicePropertyScopeInput) > 0
        var speaker = false
        if transport == .builtIn, out {
            // data source 'hdpn' = headphone jack, 'ispk' = internal speakers (absent on desktops: treat as speaker)
            let ds = UInt32Value(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
            speaker = ds != fourCC("hdpn")
        }
        return AudioDeviceInfo(id: id, uid: uid, name: name, hasInput: inp, hasOutput: out, transport: transport, isBuiltInSpeaker: speaker)
    }

    static func inputs() -> [AudioDeviceInfo] { all().filter { $0.hasInput } }
    static func outputs() -> [AudioDeviceInfo] { all().filter { $0.hasOutput } }
    static func device(uid: String) -> AudioDeviceInfo? { all().first { $0.uid == uid } }
    static func defaultDevice(input: Bool) -> AudioDeviceInfo? {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return info(for: id)
    }

    /// Calls `handler` (main queue) when devices appear/disappear or the default input/output changes. Keep the token alive.
    final class Token { fileprivate var blocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        deinit { for (var a, b) in blocks { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, b) } } }
    static func observe(_ handler: @escaping @Sendable () -> Void) -> Token {
        let t = Token()
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let b: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, b)
            t.blocks.append((a, b))
        }
        return t
    }

    // MARK: helpers
    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }
    private static func UInt32Value(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0, size = UInt32(4)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }
    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Feedback guard: sound from the Mac's own speakers re-entering a built-in (or any non-headset) microphone.
enum FeedbackCheck {
    /// nil = fine. Otherwise a human-readable warning.
    static func warning(mic: AudioDeviceInfo?, monitor: AudioDeviceInfo?) -> String? {
        guard let monitor else { return nil }
        let speaker = monitor.isBuiltInSpeaker || monitor.transport == .hdmi
        guard speaker else { return nil }
        if let mic, mic.transport == .builtIn || mic.uid == monitor.uid {
            return "Monitoring through \(monitor.name) while using the built-in microphone will feed back into the broadcast. Use headphones, or turn on Headphones only."
        }
        if mic == nil { return "Monitoring through speakers can leak into an open microphone. Use headphones." }
        return nil
    }
}
