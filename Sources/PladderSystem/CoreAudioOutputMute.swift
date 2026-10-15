import CoreAudio
import Foundation
import PladderCore

// Not `osascript`: setting the volume through AppleScript takes tens of milliseconds
// and changes the volume, not the mute flag, so it cannot be restored exactly. Some
// aggregate and USB devices mute per channel; some, HDMI ones among them, not at all.
public struct CoreAudioOutputMute: OutputMuteControl {
    public init() {}

    private static func muteElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        var address = muteAddress(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &address) {
            return [kAudioObjectPropertyElementMain]
        }
        return [1, 2].filter { element in
            var perChannel = muteAddress(element)
            return AudioObjectHasProperty(device, &perChannel)
        }
    }

    private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    public func defaultOutputDevice() -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    // An element that cannot be read is left out, so it is never written either.
    public func muteState(of device: UInt32) -> MuteState? {
        var elements: [UInt32: Bool] = [:]
        for element in Self.muteElements(device) {
            var address = Self.muteAddress(element)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
            guard status == noErr else { continue }
            elements[element] = value != 0
        }
        return elements.isEmpty ? nil : MuteState(elements)
    }

    public func apply(_ state: MuteState, to device: UInt32) throws {
        var firstFailure: MuteError?
        // In element order, so the log of a half-applied state reads the same every time.
        for (element, muted) in state.elements.sorted(by: { $0.key < $1.key }) {
            do {
                try Self.set(muted, element: element, on: device)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private static func set(_ muted: Bool, element: AudioObjectPropertyElement, on device: AudioObjectID) throws(MuteError) {
        var address = muteAddress(element)
        var settable: DarwinBoolean = false
        let check = AudioObjectIsPropertySettable(device, &address, &settable)
        guard check == noErr, settable.boolValue else {
            throw .notSettable(device: device, element: element, status: check)
        }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            throw .setFailed(device: device, element: element, status: status)
        }
    }

    public enum MuteError: LocalizedError {
        case notSettable(device: UInt32, element: UInt32, status: OSStatus)
        case setFailed(device: UInt32, element: UInt32, status: OSStatus)

        public var errorDescription: String? {
            switch self {
            case .notSettable(let device, let element, let status):
                return "mute on output device \(device) element \(element) is read-only (status \(status))"
            case .setFailed(let device, let element, let status):
                return "setting mute on output device \(device) element \(element) failed with status \(status)"
            }
        }
    }
}
