import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PladderCore

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
///
/// The transcript is written with the nspasteboard.org marker types, so clipboard
/// managers that honour them keep dictations out of their history — the whole
/// point of an app whose text never leaves the Mac.
public actor PasteboardOutput: TextOutput {
    /// How long to wait after Cmd+V before restoring the previous clipboard.
    ///
    /// The paste is asynchronous from our point of view: the target app reads the
    /// pasteboard on its own run loop some time after it receives the key event.
    /// Restoring too early gives the app the *old* contents. 400 ms is generous
    /// enough for slow Electron apps while still feeling instant to the user.
    public let restoreDelay: Duration

    /// How long to wait between Cmd+V and the Return keystroke when the caller
    /// asked for submit. The target app handles the paste on its own run loop
    /// and some Electron apps read the pasteboard a turn later, so Return waits
    /// a little. It is off the critical path: `insert` has already returned by
    /// the time this elapses.
    public let submitDelay: Duration

    /// Time between writing the pasteboard and posting Cmd+V. The write is a
    /// synchronous call to the pasteboard server, so it has landed when the
    /// call returns, and the key event still has to travel through the window
    /// server afterwards; zero is therefore the default and adds no sleep to
    /// the release-to-paste path. If an app with an unusual pasteboard user
    /// ever pastes stale content, raise this in the app's wiring (keep the
    /// smallest value that never fails).
    public let propagationDelay: Duration

    /// kVK_ANSI_V, the fallback for when the current input source cannot be
    /// asked which key types "v" — a Chinese or Japanese input method carries
    /// no layout table at all.
    private static let virtualKeyV: CGKeyCode = 0x09

    /// kVK_Return. Layout-independent: Return is Return everywhere.
    private static let virtualKeyReturn: CGKeyCode = 0x24

    /// The key that types "v" under the layout that was selected at the last
    /// key-down. `insert` only reads it, so resolving a layout never lands on
    /// the release-to-paste path. The last resolved value is kept when a later
    /// resolution fails, so a switch to an input method without a layout table
    /// pastes with whatever the previous layout said rather than guessing.
    private var pasteKey: CGKeyCode = PasteboardOutput.virtualKeyV

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

    /// The clipboard as it was at key-down, ready for `insert` to carry
    /// forward. Nil when already used. Reading every representation can take
    /// tens of milliseconds, so `prepare()` does it at key-down instead of
    /// on the release-to-paste path.
    private var prepared: (snapshot: Snapshot, changeCount: Int)?

    public init(
        restoreDelay: Duration = .milliseconds(400),
        submitDelay: Duration = .milliseconds(50),
        propagationDelay: Duration = .zero
    ) {
        self.restoreDelay = restoreDelay
        self.submitDelay = submitDelay
        self.propagationDelay = propagationDelay
    }

    /// Called at key-down, while the user is still speaking. The recording lasts
    /// at least a few hundred milliseconds, so everything here is long finished
    /// by the time `insert` runs.
    public func prepare() async {
        // Text Input Sources has to be asked on the main thread. Resolving here
        // rather than per paste keeps the path free and still follows a layout
        // switch: the next dictation picks the new one up.
        if let key = await MainActor.run(body: { KeyboardLayout.commandVKeyCode() }) {
            pasteKey = key
        }
        prepared = (Snapshot.capture(), NSPasteboard.general.changeCount)
    }

    @discardableResult
    public func insert(_ text: String, submit: Bool) async throws -> InsertResult {
        // Posting to the HID event tap is what needs Accessibility. Without it
        // the text is left on the clipboard and the caller tells the user to
        // press ⌘V; a standard account cannot grant Accessibility on its own.
        guard AXIsProcessTrusted() else {
            // A restore still pending from an earlier trusted paste would put
            // the old clipboard back over the transcript, so drop it. No
            // restore of our own either: the transcript *is* the result. And
            // no Return, which needs the same grant.
            pending?.task?.cancel()
            pending = nil
            prepared = nil
            _ = Snapshot.write(text)
            return .copied
        }

        // If a restore is still outstanding, take it over: cancel its timer and
        // carry its snapshot forward. Snapshotting now would capture the previous
        // transcript, which is *our* text, not the user's clipboard.
        let carried = pending
        carried?.task?.cancel()
        let snapshot: Snapshot
        if let carried {
            snapshot = carried.snapshot
        } else {
            // The snapshot from key-down is only valid if nobody touched the
            // pasteboard in between; anything the user copied since wins.
            let prep = prepared
            prepared = nil
            if let prep, prep.changeCount == NSPasteboard.general.changeCount {
                snapshot = prep.snapshot
            } else {
                snapshot = Snapshot.capture()
            }
        }

        let ourChangeCount = Snapshot.write(text)
        pending = Pending(snapshot: snapshot, changeCount: ourChangeCount, task: nil)

        do {
            if propagationDelay > .zero {
                try await Task.sleep(for: propagationDelay)
            }
            try Self.postKey(pasteKey, flags: .maskCommand)
        } catch {
            // Never leave the user's clipboard holding our transcript.
            if pending?.changeCount == ourChangeCount { pending = nil }
            snapshot.restore(ifChangeCountIs: ourChangeCount)
            throw error
        }

        if submit {
            // The paste has been posted, so the Return follows it whatever
            // happens to this insert from here on. Detached so cancelling the
            // caller cannot skip it.
            let submitDelay = self.submitDelay
            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: submitDelay)
                try? Self.postKey(Self.virtualKeyReturn, flags: [])
            }
        }

        // A concurrent `insert` may have superseded us across the sleep above; it
        // owns the snapshot now and will schedule its own restore.
        guard pending?.changeCount == ourChangeCount else { return .pasted }
        pending?.task = restoreTask(for: ourChangeCount)
        return .pasted
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

    /// Sends one key down/up to the HID event tap, i.e. the same place a real
    /// keyboard would inject it, so every app sees it. `flags` carries the
    /// modifiers; an empty set types the bare key.
    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { throw OutputError.eventCreationFailed }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Every item on the pasteboard with every representation, so images, rich
    /// text and file promises survive the round trip. Data is value type only,
    /// which keeps the snapshot `Sendable` across the restore delay.
    struct Snapshot: Sendable {
        var items: [[String: Data]]

        /// The nspasteboard.org marker types. Maccy, Paste, Raycast and the rest
        /// skip an item carrying these instead of recording it: transient means
        /// "do not keep", concealed means "this is secret-ish", auto-generated
        /// means "no human copied this". All three go on every transcript,
        /// including the clipboard-only path without Accessibility, where the
        /// user presses ⌘V themselves — a manager that recorded it there would
        /// be just as much of a leak.
        static let markerTypes: [NSPasteboard.PasteboardType] = [
            .init("org.nspasteboard.TransientType"),
            .init("org.nspasteboard.ConcealedType"),
            .init("org.nspasteboard.AutoGeneratedType"),
        ]

        /// Who wrote it, for managers that show or filter by source.
        static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

        /// Items up to this size are kept. `prepare()` reads this at key-down,
        /// off the release-to-paste path, so the cap no longer bounds the
        /// paste; it only bounds the memory a snapshot can hold, so large
        /// clipboards are still restored instead of dropped.
        private static let maximumItemBytes = 64 * 1024 * 1024

        static func capture(from pasteboard: NSPasteboard = .general) -> Snapshot {
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

        /// Replaces the pasteboard with `text`, marked as a transcript nobody
        /// should archive, and returns the resulting change count so we can tell
        /// later whether anybody else has written since.
        ///
        /// One item carrying five types, so it is still a single write: the
        /// markers cost a few bytes of IPC, not a second round trip.
        static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Int {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            for type in markerTypes { item.setData(Data(), forType: type) }
            // `Bundle.main.bundleIdentifier` is nil for the bare SwiftPM binary
            // and is the harness's id under `swift test`; the app's own id is
            // the fallback.
            item.setString(Bundle.main.bundleIdentifier ?? "de.dinooo13.pladder", forType: sourceType)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            return pasteboard.changeCount
        }

        /// Puts the snapshot back, unless the user copied something else while we
        /// were pasting; their copy wins in that case.
        func restore(ifChangeCountIs expected: Int, on pasteboard: NSPasteboard = .general) {
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
    /// `CGEvent` refused to create the key event, which normally means the event
    /// source could not be created.
    case eventCreationFailed

    public var errorDescription: String? {
        switch self {
        case .eventCreationFailed:
            return "Could not create the paste keystroke. Try again, or restart Pladder."
        }
    }
}
