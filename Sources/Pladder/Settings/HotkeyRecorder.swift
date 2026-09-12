import AppKit
import Carbon.HIToolbox
import Observation
import PladderCore
import PladderSystem
import SwiftUI

/// A button that shows the current push-to-talk chord and, when clicked,
/// records a new one from whatever the user presses next.
///
/// Any key or combination is allowed, lone modifiers included, and left and
/// right modifiers are distinct. The chord is committed once every key has
/// been let go, so a chord of several keys can be built up in any order.
/// Escape on its own cancels.
struct HotkeyRecorderField: View {
    @Binding var hotkey: Hotkey
    /// Called with `true` while recording. The caller suspends the global
    /// monitor so the keys used to define the new chord cannot fire the old one.
    var onRecordingChanged: (Bool) -> Void

    @State private var recorder = HotkeyRecorder()

    var body: some View {
        Button {
            if recorder.isRecording {
                recorder.cancel()
            } else {
                recorder.begin { hotkey = $0 }
            }
        } label: {
            Text(label)
                .frame(minWidth: 140)
                .contentTransition(.numericText())
        }
        .tint(recorder.isRecording ? .accentColor : nil)
        .help(recorder.isRecording
            ? "Press the key or combination to use. Escape cancels."
            : "Click, then press the key or combination to use.")
        .onChange(of: recorder.isRecording) { _, isRecording in onRecordingChanged(isRecording) }
        .onDisappear { recorder.cancel() }
    }

    private var label: String {
        guard recorder.isRecording else { return hotkey.displayName }
        return recorder.pending?.displayName ?? "Press keys…"
    }
}

/// Owns the local event monitor for one recording session.
///
/// A local `NSEvent` monitor is enough: the settings window is key while the
/// user records, and swallowing key-downs there keeps Space from clicking the
/// button and Cmd+Q from quitting the app mid-recording.
@MainActor
@Observable
final class HotkeyRecorder {
    private(set) var isRecording = false
    /// The chord that will be committed: the keys held at the last moment a
    /// key went down. Releasing keys never shrinks it.
    private(set) var pending: Hotkey?

    private var heldModifiers: Set<UInt16> = []
    private var heldKeys: Set<UInt16> = []
    private var modifierState = ModifierKeyState()
    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?
    private var commit: ((Hotkey) -> Void)?

    func begin(commit: @escaping (Hotkey) -> Void) {
        cancel()
        self.commit = commit
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            // Local monitors run on the main thread, but `NSEvent` is not
            // Sendable, so pull out the plain values before hopping.
            let key = KeyTransition(
                type: event.type, keyCode: event.keyCode,
                flags: UInt64(event.modifierFlags.rawValue),
                isRepeat: event.type == .keyDown && event.isARepeat)
            let swallow = MainActor.assumeIsolated { self.handle(key) }
            return swallow ? nil : event
        }
        // Clicking elsewhere ends the recording rather than leaving a monitor
        // behind that eats the next key press.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.cancel() }
        }
    }

    func cancel() {
        end()
    }

    private struct KeyTransition: Sendable {
        var type: NSEvent.EventType
        var keyCode: UInt16
        var flags: UInt64
        var isRepeat: Bool
    }

    /// Returns true when the event must not reach the window.
    private func handle(_ key: KeyTransition) -> Bool {
        switch key.type {
        case .flagsChanged:
            heldModifiers = modifierState.update(changedKey: key.keyCode, flags: key.flags)
            keysChanged()
            // Passed through so AppKit's idea of the modifier state stays right.
            return false
        case .keyDown:
            guard !key.isRepeat else { return true }
            heldModifiers = modifierState.held(flags: key.flags)
            if Int(key.keyCode) == kVK_Escape, heldModifiers.isEmpty, pending == nil {
                end()
                return true
            }
            heldKeys.insert(key.keyCode)
            keysChanged()
            return true
        case .keyUp:
            heldModifiers = modifierState.held(flags: key.flags)
            heldKeys.remove(key.keyCode)
            keysChanged()
            return true
        default:
            return false
        }
    }

    private func keysChanged() {
        let held = heldModifiers.union(heldKeys)
        if held.isEmpty {
            if let pending {
                let commit = self.commit
                end()
                commit?(pending)
            }
        } else if !held.isSubset(of: pending?.keyCodes ?? []) {
            // A key went down that is not part of the chord so far: the chord
            // is whatever is held now.
            pending = Hotkey(keyCodes: held)
        }
    }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        commit = nil
        pending = nil
        heldKeys = []
        heldModifiers = []
        modifierState = ModifierKeyState()
        isRecording = false
    }
}
