import CoreAudio
import Foundation

/// One audio device of the Mac: what Device Hub's Output and Input popups
/// list after None and System, and what `devicectl device settings audio
/// --output-device|--input-device` takes (the CoreAudio UID: on a Mac mini,
/// `BuiltInSpeakerDevice` for its speaker).
struct MacAudioDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    var id: String { uid }
}

enum MacAudioDevices {
    /// The devices with an output stream, in CoreAudio's order.
    static func outputs() -> [MacAudioDevice] { devices(scope: kAudioObjectPropertyScopeOutput) }
    /// The devices with an input stream.
    static func inputs() -> [MacAudioDevice] { devices(scope: kAudioObjectPropertyScopeInput) }

    private static func devices(scope: AudioObjectPropertyScope) -> [MacAudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &identifiers) == noErr else { return [] }
        return identifiers.compactMap { identifier in
            guard streamCount(identifier, scope: scope) > 0,
                  let uid = string(identifier, kAudioDevicePropertyDeviceUID),
                  let name = string(identifier, kAudioObjectPropertyName),
                  isListed(uid: uid, name: name, hidden: isHidden(identifier))
            else { return nil }
            return MacAudioDevice(uid: uid, name: name)
        }
    }

    /// Whether a device belongs in the popups: not one CoreAudio marks hidden,
    /// and not the private aggregate CoreAudio builds for the system default
    /// ("CADefaultDeviceAggregate-38792-0" shows in Output and Input beside
    /// the speaker; Sound settings never lists it).
    static func isListed(uid: String, name: String, hidden: Bool) -> Bool {
        if hidden { return false }
        return !uid.hasPrefix("CADefaultDeviceAggregate") && !name.hasPrefix("CADefaultDeviceAggregate")
    }

    private static func isHidden(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func streamCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        return value.takeRetainedValue() as String
    }
}
