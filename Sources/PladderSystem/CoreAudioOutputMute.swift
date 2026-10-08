import CoreAudio
import Foundation
import PladderCore

/// `OutputMuteControl` on top of CoreAudio's HAL.
///
/// Two properties do the whole job: `kAudioHardwarePropertyDefaultOutputDevice`
/// on the system object says which device to touch, and
/// `kAudioDevicePropertyMute` on that device in the output scope is the switch.
/// No `osascript`: shelling out to AppleScript to set the system volume takes
/// tens of milliseconds and changes the volume rather than the mute flag, so
/// it cannot be restored exactly.
///
/// The element is the wrinkle. Most devices carry a master mute on
/// `kAudioObjectPropertyElementMain`; some aggregate and USB devices carry one
/// per channel instead, on elements 1 and 2. Both are handled, each element
/// read and written on its own, and a device with no mute control at all
/// (plenty of them, including some HDMI outputs) reports nil so the
/// controller leaves it alone.
public struct CoreAudioOutputMute: OutputMuteControl {
    public init() {}

    /// Which elements of a device carry a mute control. Empty means the
    /// device has none.
    private static func muteElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &address) {
            return [kAudioObjectPropertyElementMain]
        }
        // Per-channel mute: stereo devices without a master control.
        return [1, 2].filter { element in
            var perChannel = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            return AudioObjectHasProperty(device, &perChannel)
        }
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

    /// Each element on its own, never one answer for the device: a stereo
    /// device with one channel muted by the user reads as partly muted, the
    /// controller mutes only the other channel, and the end turns only that
    /// one back off, so the user's channel stays as they left it. An element
    /// that cannot be read is left out, so it is never written either.
    public func muteState(of device: UInt32) -> MuteState? {
        var elements: [UInt32: Bool] = [:]
        for element in Self.muteElements(device) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
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
        // In element order, so a log of a half-applied state reads the same
        // every time.
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
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element)
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

    /// Named rather than bare OSStatus: these end up in the log, and the
    /// whole point of logging them is diagnosing a stuck mute.
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
