import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PladderCore
import os

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
/// The restore waits for the paste as well as for a clock. The transcript goes
/// on the pasteboard as a promise, so the target app's read comes back to us as
/// a call to `TranscriptPromise`. The old clipboard returns `restoreFloor` after
/// Cmd+V, as it always has, if the transcript has been read by then, and
/// otherwise `readSettle` after the read. An app that is busy when Cmd+V
/// arrives reads late, and the fixed delay alone handed it the user's old
/// clipboard instead of the transcript. If nothing reads it, `restoreCap` ends
/// the wait, which leaves the transcript on the clipboard a little longer and
/// never pastes stale text. Issue #40 has the measurements.
///
/// This is an actor because the pending restore is shared mutable state: a second
/// `insert` may start while the previous restore is still waiting.
///
/// The transcript is written with the nspasteboard.org marker types, so clipboard
/// managers that honour them keep dictations out of their history — the whole
/// point of an app whose text never leaves the Mac.
public actor PasteboardOutput: TextOutput {
    /// The earliest the previous clipboard comes back after Cmd+V, read or not.
    ///
    /// The paste is asynchronous from our point of view: the target app reads the
    /// pasteboard on its own run loop some time after it receives the key event,
    /// 0 to 25 ms later for every app measured, a second or more for a web page
    /// whose main thread is busy. Restoring before the read gives the app the
    /// *old* contents.
    ///
    /// A read is not always the paste: Chromium sometimes reads once as Cmd+V
    /// arrives and again when the page gets round to pasting, and the
    /// pasteboard keeps the data after the first read, so the second never
    /// reaches us. Nothing says which read is which, so a read never brings
    /// the clipboard back sooner than this. 400 ms is the fixed delay this
    /// replaced, which is enough for every app that is not busy.
    public let restoreFloor: Duration

    /// How long after the target app's last read the previous clipboard comes
    /// back, when that is later than `restoreFloor`: a busy app that read late.
    public let readSettle: Duration

    /// How long after Cmd+V the previous clipboard comes back when nothing has
    /// read the transcript: a paste into something that takes no text, or an
    /// app that never got the key event. The transcript stays on the clipboard
    /// until then, which is the safe way to be wrong.
    public let restoreCap: Duration

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
        /// The transcript on the pasteboard, which reports every read. Held
        /// here so it outlives the paste whatever the pasteboard item does.
        let promise: TranscriptPromise
        /// When Cmd+V was posted. Nil while it is still being posted; a read
        /// before then is not the paste and does not count.
        var posted: ContinuousClock.Instant?
        /// The last read of the transcript since Cmd+V.
        var lastRead: ContinuousClock.Instant?
        /// The detached task waiting for the restore to fall due. Nil while
        /// the paste is still being posted.
        var task: Task<Void, Never>?
    }

    private var pending: Pending?

    /// The clipboard as it was at key-down, ready for `insert` to carry
    /// forward. Nil when already used. Reading every representation can take
    /// tens of milliseconds, so `prepare()` does it at key-down instead of
    /// on the release-to-paste path.
    private var prepared: (snapshot: Snapshot, changeCount: Int)?

    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "paste")

    public init(
        restoreFloor: Duration = .milliseconds(400),
        readSettle: Duration = .milliseconds(200),
        restoreCap: Duration = .seconds(8),
        submitDelay: Duration = .milliseconds(50),
        propagationDelay: Duration = .zero
    ) {
        self.restoreFloor = restoreFloor
        self.readSettle = readSettle
        self.restoreCap = restoreCap
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
        // While our own transcript is still on the pasteboard the user's
        // clipboard is the pending snapshot, which `insert` carries forward.
        // Capturing would only read our own promise, from off the main
        // thread, which AppKit warns against.
        if let pending, pending.changeCount == NSPasteboard.general.changeCount {
            prepared = nil
            return
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

        let promise = TranscriptPromise(text) { [weak self] promise, instant in
            Task { await self?.transcriptRead(promise, at: instant) }
        }
        let ourChangeCount = Snapshot.publish(promise)
        pending = Pending(snapshot: snapshot, changeCount: ourChangeCount, promise: promise)

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
        guard pending?.promise === promise else { return .pasted }
        pending?.posted = .now
        scheduleRestore()
        return .pasted
    }

    /// When the pending restore falls due: `settle` after the last read since
    /// Cmd+V but no sooner than `floor` after Cmd+V, or `cap` after Cmd+V if
    /// nothing has read it, and never later than that.
    static func restoreDue(
        posted: ContinuousClock.Instant,
        lastRead: ContinuousClock.Instant?,
        floor: Duration,
        settle: Duration,
        cap: Duration
    ) -> ContinuousClock.Instant {
        let latest = posted + cap
        guard let lastRead else { return latest }
        return min(max(posted + floor, lastRead + settle), latest)
    }

    /// (Re)starts the pending restore's wait from what is known now.
    private func scheduleRestore() {
        guard let current = pending, let posted = current.posted else { return }
        current.task?.cancel()
        let due = Self.restoreDue(
            posted: posted, lastRead: current.lastRead, floor: restoreFloor, settle: readSettle, cap: restoreCap)
        pending?.task = restoreTask(for: current.promise, at: due)
    }

    /// The target app read the transcript. Called from the main thread, where
    /// AppKit serves promises, by way of a task.
    private func transcriptRead(_ promise: TranscriptPromise, at instant: ContinuousClock.Instant) {
        guard let current = pending, current.promise === promise, let posted = current.posted else { return }
        if current.lastRead == nil {
            let seconds = (instant - posted).timeInterval
            Self.log.notice("clipboard read \(seconds, format: .fixed(precision: 3)) s after Cmd+V")
        }
        pending?.lastRead = instant
        scheduleRestore()
    }

    /// Waits for the restore to fall due off the critical path, then hands back
    /// to the actor to do it. Detached so the caller's cancellation — a
    /// cancelled dictation — cannot make the restore fire early, which would give
    /// the target app the user's old clipboard instead of the transcript.
    private func restoreTask(for promise: TranscriptPromise, at due: ContinuousClock.Instant) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            try? await Task.sleep(until: due, clock: .continuous)
            // A read that moves the deadline, or a *newer* insert, cancels this
            // task; the newer insert takes ownership of the snapshot, so there
            // is nothing left to restore.
            guard !Task.isCancelled else { return }
            await self.completeRestore(promise)
        }
    }

    private func completeRestore(_ promise: TranscriptPromise) {
        guard let pending, pending.promise === promise else { return }
        self.pending = nil
        if pending.lastRead == nil {
            Self.log.notice("clipboard not read within \(self.restoreCap.components.seconds) s of Cmd+V; restoring")
        }
        pending.snapshot.restore(ifChangeCountIs: pending.changeCount)
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
        /// later whether anybody else has written since. For the clipboard-only
        /// path, where the transcript is the result and stays.
        ///
        /// One item carrying five types, so it is still a single write: the
        /// markers cost a few bytes of IPC, not a second round trip.
        static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Int {
            let item = markedItem()
            item.setString(text, forType: .string)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            return pasteboard.changeCount
        }

        /// `write`, with the text served by `promise` when an app reads it, so
        /// the read is reported. Still a single write.
        ///
        /// The markers matter twice here. Something in macOS reads every
        /// unmarked write about 15 ms after it lands, paste or no paste
        /// (Universal Clipboard, by the log); with the markers it does not.
        /// Without them that read would count as the paste and bring the old
        /// clipboard back before the target app had read the transcript.
        static func publish(_ promise: TranscriptPromise, to pasteboard: NSPasteboard = .general) -> Int {
            let item = markedItem()
            item.setDataProvider(promise, forTypes: [.string])
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            return pasteboard.changeCount
        }

        private static func markedItem() -> NSPasteboardItem {
            let item = NSPasteboardItem()
            for type in markerTypes { item.setData(Data(), forType: type) }
            // `Bundle.main.bundleIdentifier` is nil for the bare SwiftPM binary
            // and is the harness's id under `swift test`; the app's own id is
            // the fallback.
            item.setString(Bundle.main.bundleIdentifier ?? "de.dinooo13.pladder", forType: sourceType)
            return item
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

/// The transcript as a pasteboard promise: the text is handed over when an app
/// asks for it, and every ask is reported, which is how `PasteboardOutput`
/// knows the paste happened.
///
/// AppKit calls the provider on the main thread, so an app reading the
/// transcript waits for Pladder's main thread to be free. The time from Cmd+V
/// to the first read is logged for that reason.
final class TranscriptPromise: NSObject, NSPasteboardItemDataProvider, Sendable {
    let text: String
    private let onRead: @Sendable (TranscriptPromise, ContinuousClock.Instant) -> Void

    init(_ text: String, onRead: @escaping @Sendable (TranscriptPromise, ContinuousClock.Instant) -> Void) {
        self.text = text
        self.onRead = onRead
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setString(text, forType: type)
        onRead(self, .now)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
