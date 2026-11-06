import AppKit
import Carbon.HIToolbox
import Observation
import PladderCore
import PladderSystem
import SwiftUI

// The chord is committed once every key is let go, so it can be built up in any
// order. Escape alone cancels; Delete alone clears, where that is allowed.
struct HotkeyRecorderField: View {
    let title: LocalizedStringKey
    @Binding var hotkey: Hotkey
    var setHotkeySuspended: (Bool) -> Void
    // Without Accessibility a chord goes to Carbon, which needs one regular key, so a
    // modifier-only chord is refused rather than stored to never fire.
    var requiresRegularKey = false
    var allowsEmpty = false
    var systemShortcuts: Set<Hotkey> = []

    @State private var recorder = HotkeyRecorder()

    // A shortcut field as System Settings draws one: the keys in a rounded field, a
    // placeholder when empty, a clear button, and the focus ring while recording.
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                // Balances the clear button, so the keys stay centred in the field.
                if showsClear {
                    Color.clear.frame(width: 14, height: 1)
                }
                Text(label)
                    .foregroundStyle(isEmpty && !recorder.isRecording ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                if showsClear {
                    Button {
                        hotkey = Hotkey(keyCodes: [])
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 136, height: 24)
            // The system fill, as a bordered control uses: a text-background well is a black
            // hole on the grouped form in dark mode.
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-2)
                    .opacity(recorder.isRecording ? 1 : 0)
            )
            .contentShape(Rectangle())
            .onTapGesture { toggleRecording() }
            // Full Keyboard Access: Tab reaches the field, Space starts recording.
            .focusable(!recorder.isRecording)
            .onKeyPress(keys: [.space, .return]) { _ in
                guard !recorder.isRecording else { return .ignored }
                toggleRecording()
                return .handled
            }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(recorder.isRecording ? String(localized: "Recording a shortcut") : hotkey.displayName)
            .accessibilityAction { toggleRecording() }
            if let notice = recorder.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .onDisappear { recorder.cancel() }
    }

    private var isEmpty: Bool { hotkey.keyCodes.isEmpty }
    private var showsClear: Bool { allowsEmpty && !isEmpty && !recorder.isRecording }

    private func toggleRecording() {
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
    }

    private var label: String {
        guard recorder.isRecording else {
            return isEmpty ? String(localized: "Record Shortcut") : hotkey.shortcutName
        }
        // Naming the modifiers that did arrive is the honest version of "Needs a regular
        // key": macOS may have eaten the key before Pladder saw it.
        if let refused = recorder.refusedModifiers {
            return String(localized: "Only \(refused.sideAgnosticDisplayName) arrived…")
        }
        return recorder.pending?.shortcutName ?? String(localized: "Type Shortcut")
    }

    private var help: String {
        recorder.isRecording
            ? String(localized: "Press the keys to use. Escape cancels.")
            : String(localized: "Click to record a new shortcut.")
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

    private static let slot = HotkeyRecordingSlot<HotkeyRecorder> { $0.cancel() }
    private let token: HotkeyRecordingSlot<HotkeyRecorder>.Token

    init() {
        token = Self.slot.makeToken()
    }

    // A field torn down mid-recording need not get `onDisappear`; the monitors hold this
    // weakly, so it is freed and gives the hotkey back here.
    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        Self.slot.release(token)
    }

    func begin(
        requiresRegularKey: Bool = false,
        allowsEmpty: Bool = false,
        systemShortcuts: Set<Hotkey> = [],
        setHotkeySuspended: @escaping (Bool) -> Void,
        commit: @escaping (Hotkey) -> Void
    ) {
        // A restart keeps the session rather than resuming and suspending the hotkey between.
        tearDown()
        Self.slot.claim(token, by: self, setHotkeySuspended: setHotkeySuspended)
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
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
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
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
        Self.slot.release(token)
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
