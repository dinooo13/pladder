import Foundation
import PladderCore

public actor FakeCapture: AudioCapture {
    public private(set) var samplesToReturn: [Float] = Array(repeating: 0.1, count: 16_000)
    public private(set) var drainSamples: [Float] = []
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var stopGate: Gate?

    public init() {}

    public func start() async throws -> AsyncStream<Float> {
        startCount += 1
        let (stream, cont) = AsyncStream<Float>.makeStream()
        levelContinuation = cont
        return stream
    }

    public func drain() async -> [Float] {
        drainSamples
    }

    public func stop() async -> CapturedAudio {
        stopCount += 1
        levelContinuation?.finish()
        await stopGate?.wait()
        return CapturedAudio(samples: samplesToReturn)
    }

    public func warmUp() async throws {}

    public func setSamples(_ s: [Float]) { samplesToReturn = s }
    public func setDrainSamples(_ s: [Float]) { drainSamples = s }
    public func setStopGate(_ gate: Gate) { stopGate = gate }
    public func emitLevel(_ l: Float) { levelContinuation?.yield(l) }
}

public final class FakeOutput: TextOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _inserted: [String] = []
    private var _submitted: [Bool] = []
    private var _prepareCount = 0
    private var _flushCount = 0
    private var _copied: [String] = []
    public var inserted: [String] { lock.withLock { _inserted } }
    public var flushCount: Int { lock.withLock { _flushCount } }
    public var copied: [String] { lock.withLock { _copied } }
    public var submitted: [Bool] { lock.withLock { _submitted } }
    public var prepareCount: Int { lock.withLock { _prepareCount } }
    public var shouldFail = false
    public var failure: any Error = NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "paste failed"])
    public var result: InsertResult = .pasted

    public init() {}

    @discardableResult
    public func insert(_ text: String, submit: Bool) async throws -> InsertResult {
        if shouldFail { throw failure }
        lock.withLock {
            _inserted.append(text)
            _submitted.append(submit)
        }
        return result
    }

    public func prepare() async {
        lock.withLock { _prepareCount += 1 }
    }

    public func flush() async {
        lock.withLock { _flushCount += 1 }
    }

    public func copy(_ text: String) async {
        lock.withLock { _copied.append(text) }
    }
}

public final class FakeHotkey: HotkeyMonitor, @unchecked Sendable {
    private var continuation: AsyncStream<HotkeyMonitorEvent>.Continuation?
    public private(set) var startCount = 0
    public private(set) var lastChords: [HotkeyRole: Hotkey] = [:]
    public var lastHotkey: Hotkey? { lastChords[.dictate] }
    public private(set) var startedHotkeys: [Hotkey?] = []

    public init() {}

    public func start(chords: [HotkeyRole: Hotkey], submitKey: Hotkey) -> AsyncStream<HotkeyMonitorEvent> {
        startCount += 1
        lastChords = chords
        startedHotkeys.append(chords[.dictate])
        let (stream, cont) = AsyncStream<HotkeyMonitorEvent>.makeStream()
        continuation = cont
        return stream
    }
    public private(set) var stopCount = 0
    public func stop() {
        stopCount += 1
        continuation?.finish()
    }
    public private(set) var time = ContinuousClock.now
    public var step: Duration = .milliseconds(100)
    private func stamp() -> ContinuousClock.Instant {
        time += step
        return time
    }
    public func press(_ role: HotkeyRole = .dictate) {
        continuation?.yield(HotkeyMonitorEvent(role: role, event: .pressed, instant: stamp()))
    }
    public func release(_ role: HotkeyRole = .dictate, submit: Bool = false) {
        continuation?.yield(HotkeyMonitorEvent(role: role, event: .released(submit: submit), instant: stamp()))
    }
    public func interrupt(_ role: HotkeyRole = .dictate) {
        continuation?.yield(HotkeyMonitorEvent(role: role, event: .interrupted, instant: stamp()))
    }
    public func send(_ event: HotkeyMonitorEvent) {
        if let instant = event.instant, instant > time { time = instant }
        continuation?.yield(event)
    }
    public private(set) var cancelKeyEnabled: [Bool] = []
    public func setCancelKeyEnabled(_ enabled: Bool) { cancelKeyEnabled.append(enabled) }
    public func escape() { continuation?.yield(HotkeyMonitorEvent(.escape)) }
}
