import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SpeakUpCore

/// Inserts text by putting it on the general pasteboard and synthesising Cmd+V,
/// then putting the user's clipboard back.
///
/// This is the only universally reliable way to get text into an arbitrary macOS
/// app: Accessibility text insertion is not implemented consistently, and typing
/// the string as synthetic key events is slow and mangles dead keys.
public struct PasteboardOutput: TextOutput {
    /// How long to wait after Cmd+V before restoring the previous clipboard.
    ///
    /// The paste is asynchronous from our point of view: the target app reads the
    /// pasteboard on its own run loop some time after it receives the key event.
    /// Restoring too early gives the app the *old* contents. 400 ms is generous
    /// enough for slow Electron apps while still feeling instant to the user.
    public let restoreDelay: Duration

    /// Time between writing the pasteboard and posting Cmd+V, so the change has
    /// propagated through the pasteboard server before the target app looks.
    private static let propagationDelay: Duration = .milliseconds(50)

    /// kVK_ANSI_V. Hard-coded so this module does not need to import Carbon.
    private static let virtualKeyV: CGKeyCode = 0x09

    public init(restoreDelay: Duration = .milliseconds(400)) {
        self.restoreDelay = restoreDelay
    }

    public func insert(_ text: String) async throws {
        // Posting to the HID event tap is what needs Accessibility. Check first
        // so the user gets a real message instead of a silently dropped paste.
        guard AXIsProcessTrusted() else { throw OutputError.accessibilityDenied }

        let snapshot = Snapshot.capture()
        let ourChangeCount = Snapshot.write(text)

        do {
            try await Task.sleep(for: Self.propagationDelay)
            try Self.postPasteShortcut()
        } catch {
            // Never leave the user's clipboard holding our transcript.
            snapshot.restore(ifChangeCountIs: ourChangeCount)
            throw error
        }

        try? await Task.sleep(for: restoreDelay)
        snapshot.restore(ifChangeCountIs: ourChangeCount)
    }

    /// Sends Cmd+V down/up to the HID event tap, i.e. the same place a real
    /// keyboard would inject it, so every app sees it.
    private static func postPasteShortcut() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        else { throw OutputError.eventCreationFailed }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Every item on the pasteboard with every representation, so images, rich
    /// text and file promises survive the round trip. Data is value type only,
    /// which keeps the snapshot `Sendable` across the restore delay.
    private struct Snapshot: Sendable {
        var items: [[String: Data]]

        static func capture() -> Snapshot {
            let pasteboard = NSPasteboard.general
            let items = (pasteboard.pasteboardItems ?? []).map { item in
                var representations: [String: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        representations[type.rawValue] = data
                    }
                }
                return representations
            }
            return Snapshot(items: items)
        }

        /// Replaces the pasteboard with `text` and returns the resulting change
        /// count so we can tell later whether anybody else has written since.
        static func write(_ text: String) -> Int {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return pasteboard.changeCount
        }

        /// Puts the snapshot back, unless the user copied something else while we
        /// were pasting; their copy wins in that case.
        func restore(ifChangeCountIs expected: Int) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == expected else { return }
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            let restored = items.map { representations -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return item
            }
            pasteboard.writeObjects(restored)
        }
    }
}

public enum OutputError: LocalizedError {
    /// The app is not in System Settings > Privacy & Security > Accessibility,
    /// so synthetic key events are dropped.
    case accessibilityDenied
    /// `CGEvent` refused to create the key event, which normally means the event
    /// source could not be created.
    case eventCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Accessibility permission required to paste"
        case .eventCreationFailed:
            return "Could not create the paste keystroke. Try again, or restart SpeakUp."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .accessibilityDenied:
            return "Enable SpeakUp in System Settings > Privacy & Security > Accessibility."
        case .eventCreationFailed:
            return nil
        }
    }
}
