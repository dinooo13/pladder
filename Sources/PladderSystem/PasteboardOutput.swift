import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PladderCore
import Synchronization
import os

// The only reliable way into any app: Accessibility text insertion is inconsistent,
// and synthetic typing is slow and mangles dead keys. See docs/ARCHITECTURE.md,
// "Paste and clipboard".
public final class PasteboardOutput: TextOutput {
    // After the target's first read: some Electron apps insert the text a run-loop
    // turn after reading it.
    public let submitDelay: Duration

    // The fallback when the input source has no layout table (Chinese, Japanese).
    private static let virtualKeyV: CGKeyCode = 0x09
    static let virtualKeyReturn: CGKeyCode = 0x24

    let keeper: ClipboardKeeper
    private let poster: any KeyPoster
    private let isTrusted: @Sendable () -> Bool
    private let clock: PasteClock

    // Resolved in `prepare()`, so `insert` only reads it; kept when a later lookup
    // fails. A lock, not an actor: `insert` reads it without a hop.
    private let pasteKey = Mutex<CGKeyCode>(PasteboardOutput.virtualKeyV)

    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "paste")
    private let owedReturn = Mutex<OwedReturn?>(nil)

    // Posted once, by its own timer or by the next paste, which must not go out ahead.
    private final class OwedReturn: Sendable {}

    public convenience init() {
        self.init(pasteboard: .general, poster: HIDKeyPoster(), isTrusted: { AXIsProcessTrusted() }, clock: .continuous)
    }

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

    // A warm layout lookup is about a microsecond; the first in a process is tens of
    // milliseconds, paid at the first key-down.
    public func prepare() async {
        // Text Input Sources has to be asked on the main thread.
        if let key = await MainActor.run(body: { KeyboardLayout.commandVKeyCode() }) {
            pasteKey.withLock { $0 = key }
        }
        await keeper.prepare()
    }

    @discardableResult
    public func insert(_ text: String, submit: Bool) async throws -> InsertResult {
        // Posting to the HID event tap needs Accessibility. Without it the transcript stays
        // on the clipboard: no restore, and no Return, which needs the same grant.
        guard isTrusted() else {
            await keeper.copy(text)
            return .copied
        }

        let key = pasteKey.withLock { $0 }
        // A send just before this one still waiting for its target to read: its Return goes
        // now, ahead of this Cmd+V, or it could land after this paste and send both texts.
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

    // Chromium's early read starts the delay too, so there the Return is as early as a
    // fixed delay and relies on the page handling input in order. Detached: cancelling
    // the caller cannot skip a Return owed to a posted paste.
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
