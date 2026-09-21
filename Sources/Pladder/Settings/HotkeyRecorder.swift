import AppKit
import Carbon.HIToolbox
import Observation
import PladderCore
import PladderSystem
import SwiftUI

/// A button that shows the current push-to-talk chord and, when clicked,
/// records a new one from whatever the user presses next.
///
/// Any key or combination is allowed, lone modifiers included. Left and right
/// modifiers are distinct in a modifier-only chord; with a regular key the
/// side is ignored and the left-hand key is stored. The chord is committed
/// once every key has been let go, so a chord of several keys can be built up
/// in any order.
/// Escape on its own cancels.
struct HotkeyRecorderField: View {
    @Binding var hotkey: Hotkey
    /// Called with `true` while recording. The caller suspends the global
    /// monitor so the keys used to define the new chord cannot fire the old one.
    var onRecordingChanged: (Bool) -> Void
    /// Set while Accessibility is missing: a chord is then registered with
    /// Carbon, which needs exactly one regular key, so modifier-only chords
    /// are refused instead of being stored and silently never firing.
    var requiresRegularKey = false
    /// The shortcuts macOS owns, so a chord that collides with one can be
    /// warned about while it is being pressed rather than after it is stored.
    var systemShortcuts: Set<Hotkey> = []

    @State private var recorder = HotkeyRecorder()

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                if recorder.isRecording {
                    recorder.cancel()
                } else {
                    recorder.begin(
                        requiresRegularKey: requiresRegularKey,
                        systemShortcuts: systemShortcuts
                    ) { hotkey = $0 }
                }
            } label: {
                Text(label)
                    .frame(minWidth: 140)
                    .contentTransition(.numericText())
            }
            .tint(recorder.isRecording ? .accentColor : nil)
            .help(help)
            if let notice = recorder.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .onChange(of: recorder.isRecording) { _, isRecording in onRecordingChanged(isRecording) }
        .onDisappear { recorder.cancel() }
    }

    private var label: String {
        guard recorder.isRecording else { return hotkey.displayName }
        // Naming the modifiers that did arrive is the honest version of
        // "Needs a regular key…": the user may well have pressed one and had
        // macOS eat it before Pladder saw it.
        if let refused = recorder.refusedModifiers {
            return "Only \(refused.sideAgnosticDisplayName) arrived…"
        }
        return recorder.pending?.displayName ?? "Press keys…"
    }

    private var help: String {
        let base = recorder.isRecording
            ? "Press the key or combination to use. Escape cancels."
            : "Click, then press the key or combination to use."
        guard requiresRegularKey else { return base }
        return base + " Without Accessibility the key must include a regular key, "
            + "for example Control+Shift+D."
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
    /// The modifiers the user let go of while a regular key was required.
    /// The recording stays open so they can simply try again.
    private(set) var refusedModifiers: Hotkey?
    /// What went wrong, or what will go wrong, with what is being pressed.
    /// A warning only: it never stops a chord being stored.
    private(set) var notice: String?

    private var heldModifiers: Set<UInt16> = []
    private var heldKeys: Set<UInt16> = []
    private var modifierState = ModifierKeyState()
    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?
    private var commit: ((Hotkey) -> Void)?
    private var requiresRegularKey = false
    private var systemShortcuts: Set<Hotkey> = []
    /// Shown for the whole session while Secure Event Input is on, and put
    /// back whenever a chord notice is cleared.
    private var secureInputNotice: String?

    func begin(
        requiresRegularKey: Bool = false,
        systemShortcuts: Set<Hotkey> = [],
        commit: @escaping (Hotkey) -> Void
    ) {
        cancel()
        self.commit = commit
        self.requiresRegularKey = requiresRegularKey
        self.systemShortcuts = systemShortcuts
        // A warning, not a refusal: the recorder reads the settings window's
        // own key events, which secure input does not gate, so recording
        // normally works. What it does mean is that the chord about to be
        // stored will not fire until Secure Keyboard Entry is off, unless
        // Carbon can register it.
        secureInputNotice = SecureInput.isEnabled
            ? "Secure Keyboard Entry is on. A key combination recorded now may not "
                + "reach Pladder, and one without a regular key will not fire until it is off."
            : nil
        notice = secureInputNotice
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
                guard !requiresRegularKey || pending.canBeRegisteredWithoutAccessibility else {
                    // Carbon cannot register this, so storing it would leave
                    // the user with a key that does nothing. Keep recording;
                    // Escape still cancels.
                    //
                    // The regular key may well have been pressed: macOS
                    // dispatches an enabled shortcut such as Control+Space
                    // before the front app sees the key, so the monitor is
                    // left with the modifiers alone. Say so rather than
                    // implying Pladder mis-read the keys.
                    self.pending = nil
                    refusedModifiers = pending
                    notice = "Only \(pending.sideAgnosticDisplayName) reached Pladder. "
                        + "If you pressed a regular key too, macOS or another app owns that "
                        + "shortcut; try a different key, for example Control+Shift+D."
                    return
                }
                let commit = self.commit
                end()
                commit?(pending.canonical)
            }
        } else if !held.isSubset(of: pending?.keyCodes ?? []) {
            // A key went down that is not part of the chord so far: the chord
            // is whatever is held now.
            let chord = Hotkey(keyCodes: held)
            pending = chord
            refusedModifiers = nil
            // Warning only, in both modes: the tap does see such a chord, but
            // the macOS shortcut fires alongside it.
            notice = chord.systemShortcutConflict(in: systemShortcuts).map {
                "\($0.sideAgnosticDisplayName) is a macOS keyboard shortcut and will fire as well."
            } ?? secureInputNotice
        }
    }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        commit = nil
        requiresRegularKey = false
        systemShortcuts = []
        secureInputNotice = nil
        refusedModifiers = nil
        notice = nil
        pending = nil
        heldKeys = []
        heldModifiers = []
        modifierState = ModifierKeyState()
        isRecording = false
    }
}
