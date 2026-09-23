import AppKit
import ApplicationServices
import Foundation
import PladderCore
import os

/// Watches the field a dictation was just pasted into, through Accessibility,
/// so the learner can see which words the user corrects by hand.
///
/// Strictly after the paste: the app calls this once the coordinator has
/// emitted `inserted`, and nothing here can reach back into that path.
///
/// Every AX call is synchronous IPC to the target app and blocks until it
/// answers, so all of them run on one dedicated thread with its own run loop,
/// never on the main thread and never on a cooperative-pool thread. Each call
/// is capped by the messaging timeout. The shape of one watch:
///
/// 1. No grant → nil at once.
/// 2. The focused element of the focused app must be a text area, text field
///    or combo box, and never a secure field. Chromium and Electron build
///    their tree only for an assistive technology, so once per app
///    `AXManualAccessibility` is switched on and the focus read again.
/// 3. The paste is found just before the caret, with and without the
///    trailing space the output may have added. The target app reads the
///    pasteboard on its own run loop, so this is retried a few times.
/// 4. From then on only a window is read: the paste plus a margin either
///    side, never the whole field.
/// 5. Every value change reads the window, undebounced: a chat field empties
///    the instant Return is pressed, and a debounced read would see only
///    that. Focus leaving the element, the app deactivating, the element
///    going away, or `observationWindow` passing ends the watch with one
///    last read.
///
/// One watch at a time: a second paste finishes the first early with what
/// it has, then starts its own.
///
/// `@unchecked Sendable`: every mutable property is touched only on the AX
/// thread.
public final class AXPasteObserver: PastedTextObserver, @unchecked Sendable {
    public let observationWindow: TimeInterval
    public let anchorRetries: Int
    public let anchorRetryInterval: TimeInterval
    public let messagingTimeout: Float
    private let isTrusted: @Sendable () -> Bool

    private let thread = AXThread()
    /// AX thread only.
    private var current: Session?
    /// Apps `AXManualAccessibility` was already set on. AX thread only.
    private var manualAccessibility: Set<pid_t> = []

    static let log = Logger(subsystem: "de.dinooo13.pladder", category: "learning")

    /// `isTrusted` is for the tests, which must never touch another app.
    public init(
        observationWindow: TimeInterval = 60,
        anchorRetries: Int = 8,
        anchorRetryInterval: TimeInterval = 0.125,
        messagingTimeout: Float = 1,
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.observationWindow = observationWindow
        self.anchorRetries = anchorRetries
        self.anchorRetryInterval = anchorRetryInterval
        self.messagingTimeout = messagingTimeout
        self.isTrusted = isTrusted
        thread.start()
    }

    deinit {
        thread.finish()
    }

    public func observe(pasted: String) async -> PasteObservation? {
        guard !pasted.isEmpty, isTrusted() else { return nil }
        return await withCheckedContinuation { continuation in
            thread.perform { [self] in
                begin(pasted: pasted, continuation: continuation)
            }
        }
    }

    // MARK: Starting a watch (AX thread)

    private func begin(pasted: String, continuation: CheckedContinuation<PasteObservation?, Never>) {
        // A second dictation must not lose the first one's correction.
        current?.finish(finalRead: true)

        guard let target = focusedTextElement() else {
            continuation.resume(returning: nil)
            return
        }
        guard let anchor = anchor(pasted, in: target.element) else {
            Self.log.info("paste not found at the caret")
            continuation.resume(returning: nil)
            return
        }
        guard let initial = Reader.string(target.element, in: anchor.window.anchorRange),
              let split = anchor.window.split(initial),
              split.pasted == anchor.pasted else {
            Self.log.info("window around the paste could not be read")
            continuation.resume(returning: nil)
            return
        }

        let session = Session(
            element: target.element, app: target.app, window: anchor.window, split: split,
            continuation: continuation)
        session.onFinish = { [weak self, weak session] in
            if let self, self.current === session { self.current = nil }
        }
        current = session
        session.watch(pid: target.pid, for: observationWindow)
    }

    private struct Target {
        let app: AXUIElement
        let element: AXUIElement
        let pid: pid_t
    }

    private func focusedTextElement() -> Target? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        // The system-wide focused application comes back empty now and
        // then, seen live with Safari frontmost; the workspace's frontmost
        // app is the same answer by another route.
        guard let app = Reader.element(system, "AXFocusedApplication")
            ?? NSWorkspace.shared.frontmostApplication.map({ AXUIElementCreateApplication($0.processIdentifier) })
        else {
            Self.log.info("no focused application")
            return nil
        }
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        var element = Reader.element(app, "AXFocusedUIElement")
        if !Self.isTextField(element), manualAccessibility.insert(pid).inserted {
            // Chromium and Electron switch their tree on for this; it is
            // their convention, not declared in the SDK. Not
            // AXEnhancedUserInterface, which is VoiceOver's and changes how
            // some apps move their windows.
            let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            Self.log.info("manual accessibility: \(result.rawValue, privacy: .public)")
            Thread.sleep(forTimeInterval: 0.2)
            element = Reader.element(app, "AXFocusedUIElement")
        }
        guard let element, Self.isTextField(element) else {
            let role = element.flatMap { Reader.string($0, "AXRole") } ?? "none"
            Self.log.info("focused element is not a text field: \(role, privacy: .public)")
            return nil
        }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return Target(app: app, element: element, pid: pid)
    }

    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    private static func isTextField(_ element: AXUIElement?) -> Bool {
        guard let element, let role = Reader.string(element, "AXRole"), textRoles.contains(role) else {
            return false
        }
        return Reader.string(element, "AXSubrole") != "AXSecureTextField"
    }

    private struct Anchor {
        let pasted: String
        let window: PasteWindow
    }

    /// Finds the paste right before the caret. The target app pastes on its
    /// own run loop, some a turn late, so a miss is retried.
    private func anchor(_ text: String, in element: AXUIElement) -> Anchor? {
        let variants = text.last?.isWhitespace == true ? [text] : [text + " ", text]
        for attempt in 0...anchorRetries {
            if attempt > 0 { Thread.sleep(forTimeInterval: anchorRetryInterval) }
            guard let selection = Reader.range(element, "AXSelectedTextRange"),
                  let count = Reader.characterCount(element) else { continue }
            let caret = selection.location + selection.length
            for variant in variants {
                let length = variant.utf16.count
                let start = caret - length
                guard start >= 0,
                      Reader.string(element, in: CFRange(location: start, length: length)) == variant
                else { continue }
                return Anchor(
                    pasted: variant,
                    window: PasteWindow(start: start, length: length, characterCount: count))
            }
        }
        return nil
    }

    // MARK: One watch

    /// One watch on the AX thread: the element, its observer and timer, and
    /// what was read. Retained by `current` until it finishes, which is what
    /// keeps the unretained `refcon` in the AX callback valid.
    private final class Session {
        let element: AXUIElement
        let app: AXUIElement
        let window: PasteWindow
        let split: PasteWindow.Split
        var readings: [String]
        var continuation: CheckedContinuation<PasteObservation?, Never>?
        var observer: AXObserver?
        var timer: CFRunLoopTimer?
        var onFinish: (() -> Void)?

        static let maximumReadings = 32

        init(
            element: AXUIElement, app: AXUIElement, window: PasteWindow, split: PasteWindow.Split,
            continuation: CheckedContinuation<PasteObservation?, Never>
        ) {
            self.element = element
            self.app = app
            self.window = window
            self.split = split
            self.readings = [split.before + split.pasted + split.after]
            self.continuation = continuation
        }

        func watch(pid: pid_t, for seconds: TimeInterval) {
            let loop = CFRunLoopGetCurrent()
            // The timer alone still gives a final read when notifications fail.
            let timer = CFRunLoopTimerCreateWithHandler(
                nil, CFAbsoluteTimeGetCurrent() + seconds, 0, 0, 0
            ) { [weak self] _ in self?.finish(finalRead: true) }
            self.timer = timer
            CFRunLoopAddTimer(loop, timer, .defaultMode)

            var created: AXObserver?
            let result = AXObserverCreate(pid, { _, element, notification, refcon in
                guard let refcon else { return }
                let session = Unmanaged<Session>.fromOpaque(refcon).takeUnretainedValue()
                session.handle(notification as String, element: element)
            }, &created)
            guard result == .success, let created else {
                AXPasteObserver.log.info("observer: \(result.rawValue, privacy: .public)")
                return
            }
            observer = created
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for (target, name) in Self.notifications(element: element, app: app) {
                let added = AXObserverAddNotification(created, target, name as CFString, refcon)
                if added != .success {
                    AXPasteObserver.log.info(
                        "notification \(name, privacy: .public): \(added.rawValue, privacy: .public)")
                }
            }
            CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(created), .defaultMode)
        }

        private static func notifications(element: AXUIElement, app: AXUIElement) -> [(AXUIElement, String)] {
            [
                (element, "AXValueChanged"),
                (element, "AXUIElementDestroyed"),
                (app, "AXFocusedUIElementChanged"),
                (app, "AXApplicationDeactivated"),
            ]
        }

        func handle(_ notification: String, element changed: AXUIElement) {
            if notification != "AXValueChanged" {
                AXPasteObserver.log.info("watch sees \(notification, privacy: .public)")
            }
            switch notification {
            case "AXValueChanged":
                read()
            case "AXFocusedUIElementChanged":
                // Some apps re-announce the element that already has focus,
                // and WebKit does so right after a paste with a new object for
                // the same textarea, so identity is not enough: the watch ends
                // only once the element itself says it lost focus.
                if CFEqual(changed, element) { return }
                if Reader.value(element, "AXFocused") as? Bool == true { return }
                finish(finalRead: true)
            case "AXUIElementDestroyed":
                finish(finalRead: false)
            default:
                finish(finalRead: true)
            }
        }

        private func read() {
            guard let count = Reader.characterCount(element),
                  let text = Reader.string(element, in: window.readRange(characterCount: count)),
                  text != readings.last else { return }
            readings.append(text)
            if readings.count > Self.maximumReadings { readings.removeFirst() }
        }

        func finish(finalRead: Bool) {
            guard let continuation else { return }
            if finalRead { read() }
            if let observer {
                for (target, name) in Self.notifications(element: element, app: app) {
                    AXObserverRemoveNotification(observer, target, name as CFString)
                }
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
            if let timer { CFRunLoopTimerInvalidate(timer) }
            timer = nil
            self.continuation = nil
            AXPasteObserver.log.info("watch ended with \(self.readings.count, privacy: .public) readings")
            continuation.resume(returning: PasteObservation(
                before: split.before, pasted: split.pasted, after: split.after, readings: readings))
            onFinish?()
            onFinish = nil
        }
    }
}

/// Where the paste sits in the field and which part of the field to read,
/// in UTF-16 units, the unit AX ranges count in. Pure, so it is tested.
struct PasteWindow: Equatable {
    /// The paste's range when it was found.
    let start: Int
    let length: Int
    /// The field's length when the paste was found.
    let characterCount: Int
    let windowStart: Int
    let windowEnd: Int

    init(start: Int, length: Int, characterCount: Int) {
        self.start = start
        self.length = length
        self.characterCount = characterCount
        let margin = max(64, length / 4)
        windowStart = max(0, start - margin)
        windowEnd = min(characterCount, start + length + margin)
    }

    var anchorRange: CFRange {
        CFRange(location: windowStart, length: windowEnd - windowStart)
    }

    /// The window now. Its end moves with the field's length, on the
    /// assumption that the edits are the user's corrections inside it, and
    /// grows by at most twice the window, so typing on after the paste never
    /// turns into reading a whole document.
    func readRange(characterCount count: Int) -> CFRange {
        let size = windowEnd - windowStart
        let end = min(count, windowEnd + (count - characterCount), windowStart + 2 * size + 1024)
        return CFRange(location: windowStart, length: max(0, end - windowStart))
    }

    struct Split: Equatable {
        let before: String
        let pasted: String
        let after: String
    }

    /// Cuts the anchor-time window into margin, paste, margin.
    func split(_ text: String) -> Split? {
        let ns = text as NSString
        let head = start - windowStart
        guard ns.length == windowEnd - windowStart, head >= 0, head + length <= ns.length else { return nil }
        return Split(
            before: ns.substring(to: head),
            pasted: ns.substring(with: NSRange(location: head, length: length)),
            after: ns.substring(from: head + length))
    }
}

/// Thin typed reads over the AX C API. Called on the AX thread only.
private enum Reader {
    /// Past this a field without `AXStringForRange` is not read at all.
    static let wholeValueLimit = 20_000

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func characterCount(_ element: AXUIElement) -> Int? {
        if let count = value(element, "AXNumberOfCharacters") as? Int { return count }
        guard let whole = string(element, "AXValue") else { return nil }
        let count = (whole as NSString).length
        return count <= wholeValueLimit ? count : nil
    }

    /// `AXStringForRange`, or a slice of the whole value for a field that
    /// lacks it and is short enough to read whole.
    static func string(_ element: AXUIElement, in range: CFRange) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        var cfRange = range
        if let parameter = AXValueCreate(.cfRange, &cfRange) {
            var value: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(
                element, "AXStringForRange" as CFString, parameter, &value)
            if result == .success { return value as? String }
            guard result == .parameterizedAttributeUnsupported || result == .attributeUnsupported else {
                return nil
            }
        }
        guard let whole = string(element, "AXValue") else { return nil }
        let ns = whole as NSString
        guard ns.length <= wholeValueLimit, range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: range.location, length: range.length))
    }
}

/// A thread that only runs a run loop, for the AX observer and its timer.
/// Work arrives as blocks. The same shape as the hotkey tap's thread.
private final class AXThread: Thread, @unchecked Sendable {
    private let condition = NSCondition()
    private var loop: CFRunLoop?

    override init() {
        super.init()
        name = "Pladder.CorrectionObserver"
        qualityOfService = .utility
    }

    override func main() {
        condition.lock()
        loop = CFRunLoopGetCurrent()
        condition.broadcast()
        condition.unlock()
        // Nothing to watch between dictations; the port keeps the loop alive.
        RunLoop.current.add(NSMachPort(), forMode: .common)
        while !isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    func perform(_ block: @escaping @Sendable () -> Void) {
        condition.lock()
        while loop == nil { condition.wait() }
        let loop = loop!
        condition.unlock()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    /// Does not wait for the loop the way `perform` does: a thread cancelled
    /// before it got going never runs `main`, and would never publish one.
    func finish() {
        cancel()
        condition.lock()
        let loop = loop
        condition.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
        CFRunLoopWakeUp(loop)
    }
}
