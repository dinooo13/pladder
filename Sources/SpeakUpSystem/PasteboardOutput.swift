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
///
/// `insert` returns as soon as Cmd+V has been posted; the clipboard restore runs
/// on a detached task afterwards. That keeps the caller's `.inserting` state to a
/// few milliseconds and makes the restore immune to the caller being cancelled —
/// cancelling a dictation must never yank the pasteboard out from under an app
/// that has not read it yet.
///
/// This is an actor because the pending restore is shared mutable state: a second
/// `insert` may start while the previous restore is still waiting.
public actor PasteboardOutput: TextOutput {
    /// How long to wait after Cmd+V before restoring the previous clipboard.
    ///
    /// The paste is asynchronous from our point of view: the target app reads the
    /// pasteboard on its own run loop some time after it receives the key event.
    /// Restoring too early gives the app the *old* contents. 400 ms is generous
    /// enough for slow Electron apps while still feeling instant to the user.
    public let restoreDelay: Duration

    /// Time between writing the pasteboard and posting Cmd+V. `NSPasteboard`
    /// writes are synchronous with the pasteboard server, so this only needs to
    /// cover the target app noticing the change count; 10 ms is plenty and keeps
    /// the paste on the critical path short.
    private static let propagationDelay: Duration = .milliseconds(10)

    /// kVK_ANSI_V. Hard-coded so this module does not need to import Carbon.
    private static let virtualKeyV: CGKeyCode = 0x09

    /// A restore that has been scheduled but has not run yet.
    private struct Pending {
        /// The user's clipboard, as it was before *our first* uninterrupted
        /// paste. Carried forward across back-to-back inserts.
        let snapshot: Snapshot
        /// The change count our write produced, i.e. what the pasteboard must
        /// still be at for the restore to be safe.
        let changeCount: Int
        /// The detached task waiting out `restoreDelay`. Nil while the paste is
        /// still being posted.
        var task: Task<Void, Never>?
    }

    private var pending: Pending?

    public init(restoreDelay: Duration = .milliseconds(400)) {
        self.restoreDelay = restoreDelay
    }

    public func insert(_ text: String) async throws {
        // Posting to the HID event tap is what needs Accessibility. Check first
        // so the user gets a real message instead of a silently dropped paste.
        guard AXIsProcessTrusted() else { throw OutputError.accessibilityDenied }

        // If a restore is still outstanding, take it over: cancel its timer and
        // carry its snapshot forward. Snapshotting now would capture the previous
        // transcript, which is *our* text, not the user's clipboard.
        let carried = pending
        carried?.task?.cancel()
        let snapshot = carried?.snapshot ?? Snapshot.capture()

        let ourChangeCount = Snapshot.write(text)
        pending = Pending(snapshot: snapshot, changeCount: ourChangeCount, task: nil)

        do {
            try await Task.sleep(for: Self.propagationDelay)
            try Self.postPasteShortcut()
        } catch {
            // Never leave the user's clipboard holding our transcript.
            if pending?.changeCount == ourChangeCount { pending = nil }
            snapshot.restore(ifChangeCountIs: ourChangeCount)
            throw error
        }

        // A concurrent `insert` may have superseded us across the sleep above; it
        // owns the snapshot now and will schedule its own restore.
        guard pending?.changeCount == ourChangeCount else { return }
        pending?.task = restoreTask(for: ourChangeCount)
    }

    /// Waits out `restoreDelay` off the critical path, then hands back to the
    /// actor to do the restore. Detached so the caller's cancellation — a
    /// cancelled dictation — cannot make the restore fire early, which would give
    /// the target app the user's old clipboard instead of the transcript.
    private func restoreTask(for changeCount: Int) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [restoreDelay] in
            try? await Task.sleep(for: restoreDelay)
            // Only a *newer* insert cancels this task, and it takes ownership of
            // the snapshot when it does, so there is nothing left to restore.
            guard !Task.isCancelled else { return }
            await self.completeRestore(changeCount: changeCount)
        }
    }

    private func completeRestore(changeCount: Int) {
        guard let pending, pending.changeCount == changeCount else { return }
        self.pending = nil
        pending.snapshot.restore(ifChangeCountIs: changeCount)
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

        /// Items bigger than this are skipped: reading them out of the pasteboard
        /// server happens *before* the paste, so a 40 MB screenshot on the
        /// clipboard would delay the user's text by hundreds of milliseconds.
        ///
        /// Consequence, by design: very large clipboard contents are not
        /// restored. After such a paste the clipboard is left empty rather than
        /// holding the transcript.
        private static let maximumItemBytes = 4 * 1024 * 1024

        static func capture() -> Snapshot {
            let pasteboard = NSPasteboard.general
            let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> [String: Data]? in
                var representations: [String: Data] = [:]
                var total = 0
                for type in item.types {
                    guard let data = item.data(forType: type) else { continue }
                    total += data.count
                    guard total <= maximumItemBytes else { return nil }
                    representations[type.rawValue] = data
                }
                return representations.isEmpty ? nil : representations
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
