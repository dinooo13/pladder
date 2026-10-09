import AppKit
import Carbon.HIToolbox
import Observation
import PladderCore
import PladderSystem
import SwiftUI

// The chord is committed once every key is let go, so it can be built up in any
// order. Escape alone cancels; Delete alone clears, where that is allowed.
struct HotkeyRecorderField: View {
    @Binding var hotkey: Hotkey
    var setHotkeySuspended: (Bool) -> Void
    // Without Accessibility a chord goes to Carbon, which needs one regular key, so a
    // modifier-only chord is refused rather than stored to never fire.
    var requiresRegularKey = false
    var allowsEmpty = false
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
                        allowsEmpty: allowsEmpty,
                        systemShortcuts: systemShortcuts,
                        setHotkeySuspended: setHotkeySuspended
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
        .onDisappear { recorder.cancel() }
    }

    private var label: String {
        guard recorder.isRecording else { return hotkey.displayName }
        // Naming the modifiers that did arrive is the honest version of "Needs a regular
        // key": macOS may have eaten the key before Pladder saw it.
        if let refused = recorder.refusedModifiers {
            return String(localized: "Only \(refused.sideAgnosticDisplayName) arrived…")
        }
        return recorder.pending?.displayName ?? String(localized: "Press keys…")
    }

    // Whole sentences: a translation cannot be assembled from clauses.
    private var help: String {
        switch (recorder.isRecording, requiresRegularKey) {
        case (true, false):
            allowsEmpty
                ? String(localized: "Press the key or combination to use. Escape cancels, Delete clears.")
                : String(localized: "Press the key or combination to use. Escape cancels.")
        case (true, true):
            allowsEmpty
                ? String(localized: "Press the key or combination to use. Escape cancels, Delete clears. Without Accessibility the key must include a regular key, for example Control+Shift+D.")
                : String(localized: "Press the key or combination to use. Escape cancels. Without Accessibility the key must include a regular key, for example Control+Shift+D.")
        case (false, false):
            String(localized: "Click, then press the key or combination to use.")
        case (false, true):
            String(localized: "Click, then press the key or combination to use. Without Accessibility the key must include a regular key, for example Control+Shift+D.")
        }
    }
}

// A local monitor is enough, since the settings window is key while recording.
// Swallowing key-downs keeps Space from clicking the button and Cmd+Q from quitting.
@MainActor
@Observable
final class HotkeyRecorder {
    private(set) var isRecording = false
    // The keys held the last time one went down: releasing keys never shrinks it.
    private(set) var pending: Hotkey?
    private(set) var refusedModifiers: Hotkey?
    // A warning only: it never stops a chord being stored.
    private(set) var notice: String?

    private var heldModifiers: Set<UInt16> = []
    private var heldKeys: Set<UInt16> = []
    private var modifierState = ModifierKeyState()
    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?
    private var commit: ((Hotkey) -> Void)?
    private var requiresRegularKey = false
    private var allowsEmpty = false
    private var systemShortcuts: Set<Hotkey> = []
    private var secureInputNotice: String?

    func begin(
        requiresRegularKey: Bool = false,
        allowsEmpty: Bool = false,
        systemShortcuts: Set<Hotkey> = [],
        setHotkeySuspended: @escaping (Bool) -> Void,
        commit: @escaping (Hotkey) -> Void
    ) {
        // A restart keeps the session rather than resuming and suspending the hotkey between.
        tearDown()
        RecordingSlot.shared.claim(for: self, setHotkeySuspended: setHotkeySuspended)
        self.commit = commit
        self.requiresRegularKey = requiresRegularKey
        self.allowsEmpty = allowsEmpty
        self.systemShortcuts = systemShortcuts
        // A warning, not a refusal: secure input does not gate the window's own key events,
        // but the chord stored now will not fire until it is off, unless Carbon can take it.
        secureInputNotice = SecureInput.isEnabled
            ? String(localized: "Secure Keyboard Entry is on. A key combination recorded now may not reach Pladder, and one without a regular key will not fire until it is off.")
            : nil
        notice = secureInputNotice
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            // `NSEvent` is not Sendable, so the plain values are pulled out before hopping.
            let key = KeyTransition(
                type: event.type, keyCode: event.keyCode,
                flags: UInt64(event.modifierFlags.rawValue),
                isRepeat: event.type == .keyDown && event.isARepeat)
            let swallow = MainActor.assumeIsolated { self.handle(key) }
            return swallow ? nil : event
        }
        // Clicking elsewhere ends the recording rather than leaving a monitor that eats the
        // next key press.
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

    // True when the event must not reach the window.
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
            if allowsEmpty, Int(key.keyCode) == kVK_Delete, heldModifiers.isEmpty, pending == nil {
                end(committing: Hotkey(keyCodes: []))
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
                    // Carbon cannot register this, so keep recording. The regular key may well have been
                    // pressed: macOS dispatches an enabled shortcut such as Control+Space first.
                    self.pending = nil
                    refusedModifiers = pending
                    notice = String(localized: "Only \(pending.sideAgnosticDisplayName) reached Pladder. If you pressed a regular key too, macOS or another app owns that shortcut; try a different key, for example Control+Shift+D.")
                    return
                }
                end(committing: pending.canonical)
            }
        } else if !held.isSubset(of: pending?.keyCodes ?? []) {
            let chord = Hotkey(keyCodes: held)
            pending = chord
            refusedModifiers = nil
            // Warning only: the tap does see such a chord, but the macOS shortcut fires too.
            notice = chord.systemShortcutConflict(in: systemShortcuts).map {
                String(localized: "\($0.sideAgnosticDisplayName) is a macOS keyboard shortcut and will fire as well.")
            } ?? secureInputNotice
        }
    }

    // The chord is stored before the hotkey is given back, so the monitor restarts once,
    // with the new chord.
    private func end(committing chord: Hotkey? = nil) {
        let commit = self.commit
        tearDown()
        if let chord { commit?(chord) }
        RecordingSlot.shared.release(by: self)
    }

    private func tearDown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        commit = nil
        requiresRegularKey = false
        allowsEmpty = false
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

// Keeps the closure that suspended the hotkey: it is the one that resumes it.
@MainActor
private final class RecordingSlot {
    static let shared = RecordingSlot()

    private var session = HotkeyRecordingSession<ObjectIdentifier>()
    private weak var holder: HotkeyRecorder?
    private var setHotkeySuspended: ((Bool) -> Void)?

    func claim(for recorder: HotkeyRecorder, setHotkeySuspended: @escaping (Bool) -> Void) {
        let begin = session.begin(ObjectIdentifier(recorder))
        let displaced = holder
        holder = recorder
        self.setHotkeySuspended = setHotkeySuspended
        // After the session has moved on, so the displaced recorder's own release is a no-op.
        if begin.displaced != nil { displaced?.cancel() }
        if begin.suspends { setHotkeySuspended(true) }
    }

    func release(by recorder: HotkeyRecorder) {
        guard session.end(ObjectIdentifier(recorder)) else { return }
        holder = nil
        let resume = setHotkeySuspended
        setHotkeySuspended = nil
        resume?(false)
    }
}
