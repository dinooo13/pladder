import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PladderCore
import Synchronization
import os

/// Inserts text by putting it on the general pasteboard and synthesising Cmd+V,
/// then putting the user's clipboard back.
///
/// This is the only universally reliable way to get text into an arbitrary macOS
/// app: Accessibility text insertion is not implemented consistently, and typing
/// the string as synthetic key events is slow and mangles dead keys.
///
/// `insert` returns as soon as Cmd+V has been posted; the clipboard restore and
/// the Return of a send run on detached tasks afterwards. That keeps the
/// caller's `.inserting` state to a few milliseconds and makes both immune to
/// the caller being cancelled.
///
/// Three parts, each with its own seam: this type picks the key and decides
/// between pasting and copying, `ClipboardKeeper` owns the user's clipboard
/// and when it comes back, `KeyPoster` types the keys. The tests hand in a
/// named pasteboard, a recording poster, a manual clock and the grant, so no
/// test touches the general pasteboard or types into another app.
///
/// The transcript is written with the nspasteboard.org marker types, so clipboard
/// managers that honour them keep dictations out of their history — the whole
/// point of an app whose text never leaves the Mac.
public final class PasteboardOutput: TextOutput {
    /// How long after the target app's first read of the transcript the
    /// Return of a send is posted. The read is the paste arriving, but the
    /// app still has to insert the text on its run loop, and some Electron
    /// apps do that a turn later, so Return waits a little more. Off the
    /// critical path: `insert` has already returned by then.
    public let submitDelay: Duration

    /// kVK_ANSI_V, the fallback for when the current input source cannot be
    /// asked which key types "v" — a Chinese or Japanese input method carries
    /// no layout table at all.
    private static let virtualKeyV: CGKeyCode = 0x09

    /// kVK_Return. Layout-independent: Return is Return everywhere.
    static let virtualKeyReturn: CGKeyCode = 0x24

    let keeper: ClipboardKeeper
    private let poster: any KeyPoster
    private let isTrusted: @Sendable () -> Bool
    private let clock: PasteClock

    /// The key that types "v" under the layout that was selected at the last
    /// `prepare()`. `insert` only reads it, so resolving a layout never lands
    /// on the release-to-paste path. The last resolved value is kept when a
    /// later resolution fails, so a switch to an input method without a
    /// layout table pastes with whatever the previous layout said rather
    /// than guessing. A lock, not an actor: `insert` reads it without a hop.
    private let pasteKey = Mutex<CGKeyCode>(PasteboardOutput.virtualKeyV)

    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "paste")

    /// The Return the last send still owes, until it is posted.
    private let owedReturn = Mutex<OwedReturn?>(nil)

    /// Posted once, by whichever comes first: its own timer, or the next
    /// paste, which must not go out ahead of it.
    private final class OwedReturn: Sendable {}

    public convenience init() {
        self.init(pasteboard: .general, poster: HIDKeyPoster(), isTrusted: { AXIsProcessTrusted() }, clock: .continuous)
    }

    /// Everything injected, for the tests.
    init(
        submitDelay: Duration = .milliseconds(50),
        pasteboard: NSPasteboard.Name,
        poster: any KeyPoster,
        isTrusted: @escaping @Sendable () -> Bool,
        clock: PasteClock,
        snapshotLimit: Int = ClipboardSnapshot.maximumItemBytes
    ) {
        self.submitDelay = submitDelay
        self.poster = poster
        self.isTrusted = isTrusted
        self.clock = clock
        keeper = ClipboardKeeper(pasteboard: pasteboard, clock: clock, snapshotLimit: snapshotLimit)
    }

    /// Called at key-down, while the user is still speaking, and safe to call
    /// again at release, overlapping the engine pass: a second call with
    /// nothing changed reads no clipboard, only its change count, plus a warm
    /// layout lookup on the main thread (about a microsecond measured; the
    /// first lookup in a process is tens of milliseconds, paid at the first
    /// key-down). A clipboard the user changed while speaking is read here
    /// then, not inside `insert`.
    public func prepare() async {
        // Text Input Sources has to be asked on the main thread. Resolving here
        // rather than per paste keeps the path free and still follows a layout
        // switch: the next dictation picks the new one up.
        if let key = await MainActor.run(body: { KeyboardLayout.commandVKeyCode() }) {
            pasteKey.withLock { $0 = key }
        }
        await keeper.prepare()
    }

    @discardableResult
    public func insert(_ text: String, submit: Bool) async throws -> InsertResult {
        // Posting to the HID event tap is what needs Accessibility. Without it
        // the text is left on the clipboard and the caller tells the user to
        // press ⌘V; a standard account cannot grant Accessibility on its own.
        // No restore and no Return either: the transcript *is* the result, and
        // Return needs the same grant.
        guard isTrusted() else {
            await keeper.copy(text)
            return .copied
        }

        let key = pasteKey.withLock { $0 }
        // A send just before this one still waiting for its target to read:
        // its Return goes now, ahead of this Cmd+V. Waited out, it could land
        // after this paste and send both texts.
        if owedReturn.withLock({ $0.take() }) != nil {
            postReturn()
        }
        let paste = try await keeper.paste(text) { [poster] in
            try poster.post(key, flags: .maskCommand)
        }
        if submit { sendReturn(after: paste) }
        return .pasted
    }

    public func flush() async {
        await keeper.flush()
    }

    /// Posts Return once the paste has landed: `submitDelay` after the target
    /// app first reads the transcript, or at `restoreFloor` after Cmd+V if it
    /// has not read it by then, so a target that never reads still gets its
    /// Return. An app that reads late, busy when Cmd+V arrived, gets the text
    /// before the Return rather than after. Chromium sometimes reads once as
    /// Cmd+V arrives, before the page pastes; that read starts the delay too,
    /// so there the Return comes as early as it always did and relies on the
    /// page handling its input in order.
    ///
    /// The paste has been posted, so the Return follows it whatever happens
    /// to this insert from here on: detached, so cancelling the caller
    /// cannot skip it.
    private func sendReturn(after paste: ClipboardKeeper.Paste) {
        let cap = paste.posted + keeper.restoreFloor
        let owed = OwedReturn()
        owedReturn.withLock { $0 = owed }
        Task.detached(priority: .userInitiated) { [self, keeper, clock, submitDelay] in
            let read = await keeper.firstRead(of: paste.promise, by: cap)
            try? await clock.sleep(read.map { $0 + submitDelay } ?? cap)
            let mine = owedReturn.withLock { slot in
                guard slot === owed else { return false }
                slot = nil
                return true
            }
            guard mine else { return }
            postReturn()
        }
    }

    private func postReturn() {
        do {
            try poster.post(Self.virtualKeyReturn, flags: [])
        } catch {
            Self.log.error("Return not posted: \(String(describing: error), privacy: .public)")
        }
    }
}
