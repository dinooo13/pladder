import AppKit
import ApplicationServices
import Foundation
import PladderCore
import os

// Every AX call is synchronous IPC that blocks until the target app answers, so all
// of them run on a thread of their own. The stages of a watch: docs/ARCHITECTURE.md,
// "Learned corrections". `@unchecked Sendable`: mutable state is AX-thread only.
public final class AXPasteObserver: PastedTextObserver, @unchecked Sendable {
    public let observationWindow: TimeInterval
    public let anchorRetries: Int
    public let anchorRetryInterval: TimeInterval
    public let messagingTimeout: Float
    private let isTrusted: @Sendable () -> Bool

    private let thread = RunLoopThread(name: "Pladder.CorrectionObserver", qualityOfService: .utility)
    private var current: Session?
    private var manualAccessibility: Set<pid_t> = []

    static let log = Logger(subsystem: "de.dinooo13.pladder", category: "learning")

    // `isTrusted` is injected because the tests must never touch another app.
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
        // `current` belongs to the AX thread, but nothing can reach it now: every block sent
        // there holds `self` strongly, and `onFinish` holds it weakly. So it is read here and
        // ended there, and its caller gets nil instead of waiting for ever.
        nonisolated(unsafe) let session = current
        if session != nil {
            thread.perform { session?.abandon() }
        }
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
        // The system-wide focused application comes back empty now and then, seen live with
        // Safari frontmost; the workspace's frontmost app is the same answer by another route.
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
        if Self.wantsManualAccessibility(
               hasFocus: element != nil, focusedRole: element.flatMap { Reader.string($0, "AXRole") }),
           manualAccessibility.insert(pid).inserted {
            // Chromium's and Electron's convention for switching their tree on, not in the SDK.
            // Not AXEnhancedUserInterface, which is VoiceOver's and changes how windows move.
            let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            Self.log.info("manual accessibility: \(result.rawValue, privacy: .public)")
            Thread.sleep(forTimeInterval: Self.manualAccessibilitySettle)
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

    // Paid once per app, on the AX thread, long after the paste.
    static let manualAccessibilitySettle: TimeInterval = 0.2

    // Never for an app that already exposes a focus of another kind: the flag stays on
    // for the app's lifetime, and keeping its whole tree up to date costs it on every change.
    static func wantsManualAccessibility(hasFocus: Bool, focusedRole: String?) -> Bool {
        !hasFocus || focusedRole == "AXWebArea"
    }

    private static func isTextField(_ element: AXUIElement?) -> Bool {
        guard let element, let role = Reader.string(element, "AXRole"), textRoles.contains(role) else {
            return false
        }
        // Never a password field.
        return Reader.string(element, "AXSubrole") != "AXSecureTextField"
    }

    private struct Anchor {
        let pasted: String
        let window: PasteWindow
    }

    // The target app pastes on its own run loop, some a turn late, so a miss is retried.
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
                    window: PasteWindow(pasteStart: start, pasteLength: length, fieldLength: count))
            }
        }
        return nil
    }

    // MARK: One watch

    // Retained by `current` until it finishes, which is what keeps the unretained
    // `refcon` in the AX callback valid.
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
                // Undebounced on purpose; see docs/ARCHITECTURE.md, "Learned corrections".
                read()
            case "AXFocusedUIElementChanged":
                // WebKit re-announces the focused textarea right after a paste, as a new object, so
                // identity is not enough: the watch ends once the element says it lost focus.
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
                  let text = Reader.string(element, in: window.readRange(fieldLength: count)),
                  text != readings.last else { return }
            readings.append(text)
            if readings.count > Self.maximumReadings { readings.removeFirst() }
        }

        func finish(finalRead: Bool) {
            guard continuation != nil else { return }
            if finalRead { read() }
            AXPasteObserver.log.info("watch ended with \(self.readings.count, privacy: .public) readings")
            end(with: PasteObservation(
                before: split.before, pasted: split.pasted, after: split.after, readings: readings))
        }

        func abandon() {
            end(with: nil)
        }

        private func end(with observation: PasteObservation?) {
            guard let continuation else { return }
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
            continuation.resume(returning: observation)
            onFinish?()
            onFinish = nil
        }
    }
}

// In UTF-16 units, which AX ranges count in.
struct PasteWindow: Equatable {
    let pasteStart: Int
    let pasteLength: Int
    let fieldLengthAtPaste: Int
    let windowStart: Int
    let windowEnd: Int

    static let minimumMargin = 64
    static let marginDivisor = 4
    static let growthAllowance = 1_024

    init(pasteStart: Int, pasteLength: Int, fieldLength: Int) {
        self.pasteStart = pasteStart
        self.pasteLength = pasteLength
        fieldLengthAtPaste = fieldLength
        let margin = max(Self.minimumMargin, pasteLength / Self.marginDivisor)
        windowStart = max(0, pasteStart - margin)
        windowEnd = min(fieldLength, pasteStart + pasteLength + margin)
    }

    var anchorRange: CFRange {
        CFRange(location: windowStart, length: windowEnd - windowStart)
    }

    // The end follows the field's length, taking edits to be corrections inside the
    // window, up to twice its size plus `growthAllowance`: never a whole document.
    func readRange(fieldLength: Int) -> CFRange {
        let size = windowEnd - windowStart
        let end = min(fieldLength, windowEnd + (fieldLength - fieldLengthAtPaste), windowStart + 2 * size + Self.growthAllowance)
        return CFRange(location: windowStart, length: max(0, end - windowStart))
    }

    struct Split: Equatable {
        let before: String
        let pasted: String
        let after: String
    }

    func split(_ text: String) -> Split? {
        let ns = text as NSString
        let head = pasteStart - windowStart
        guard ns.length == windowEnd - windowStart, head >= 0, head + pasteLength <= ns.length else { return nil }
        return Split(
            before: ns.substring(to: head),
            pasted: ns.substring(with: NSRange(location: head, length: pasteLength)),
            after: ns.substring(from: head + pasteLength))
    }
}

private enum Reader {
    // Past this a field without `AXStringForRange` is not read at all.
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
