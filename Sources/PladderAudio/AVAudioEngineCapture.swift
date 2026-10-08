import AVFoundation
import PladderCore
import os

/// Microphone capture built on `AVAudioEngine`.
///
/// Lifetime: the engine is created once and lives for the life of the app, but it
/// only *runs* while a recording is in flight. A running input engine makes macOS
/// show the orange "microphone in use" indicator, which would otherwise be on
/// permanently. `warmUp()` attaches the input node and prepares the graph so the
/// first `start()` only pays for `AVAudioEngine.start()`, which is a few
/// milliseconds; `stop()` pauses the engine again once the tap is removed.
///
/// Threading: the tap block runs on a realtime audio thread. It must never touch
/// actor state, allocate unpredictably, or `await` anything. Everything it needs
/// lives in `TapProcessor`, which it owns outright, the recording's
/// `SampleAccumulator`, which is behind a lock, and the
/// `AsyncStream.Continuation` for the level meter, which is safe to yield from any
/// thread. Sample-rate conversion happens inside the tap block, which is the normal
/// arrangement: `AVAudioConverter` is fast, deterministic, and doing it there avoids
/// shipping raw 48 kHz buffers across an isolation boundary.
///
/// There is no `AVAudioSession` on macOS, so nothing here configures one.
public actor AVAudioEngineCapture: AudioCapture {
    /// Sample rate every buffer is converted to, matching `CapturedAudio.sampleRate`.
    public nonisolated static let targetSampleRate: Double = 16_000

    /// ~43 ms at 48 kHz: small enough for a lively level meter, large enough that the
    /// realtime thread is not woken excessively.
    private static let tapBufferSize: AVAudioFrameCount = 2048

    public enum CaptureError: Error, CustomStringConvertible, Sendable {
        case noInputDevice
        case engineStartFailed(String)

        public var description: String {
            switch self {
            case .noInputDevice:
                return "No microphone input is available. Check the input device and microphone permission."
            case .engineStartFailed(let message):
                return "Could not start the audio engine: \(message)"
            }
        }

        public var localizedDescription: String { description }
    }

    private let engine = AVAudioEngine()
    /// The current recording's samples. A device change mid-recording installs a
    /// new tap in front of the same accumulator, so the switch loses nothing.
    private var accumulator: SampleAccumulator?
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var isRecording = false
    private var configurationObserver: NotificationObserver?

    public init() {}

    // MARK: AudioCapture

    /// Prepares the engine ahead of time without running it. Throws if there is no
    /// usable input, which on a first launch usually means microphone permission has
    /// not been granted yet; `start()` retries, so a throw here is not fatal.
    public func warmUp() async throws {
        observeConfigurationChanges()
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        engine.prepare()
    }

    public func start() async throws -> AsyncStream<Float> {
        if isRecording {
            _ = await stop()
        }
        observeConfigurationChanges()
        // warmUp() may have failed (no permission at launch); retry here.
        try startEngineIfNeeded()

        let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        levelContinuation = continuation
        let accumulator = SampleAccumulator()
        do {
            try installTap(into: accumulator, continuation: continuation)
        } catch {
            continuation.finish()
            levelContinuation = nil
            throw error
        }
        self.accumulator = accumulator
        isRecording = true
        Self.startMarker()
        return stream
    }

    private static func startMarker() {
        log.log("capture started")
    }

    /// Takes everything captured so far and keeps recording. Only the samples
    /// since the last `drain()` or `start()` are returned; `stop()` then sees
    /// just the tail.
    public func drain() async -> [Float] {
        guard isRecording, let accumulator else { return [] }
        return accumulator.drain()
    }

    public func stop() async -> CapturedAudio {
        Self.log.log("capture stop called, isRecording=\(self.isRecording)")
        guard isRecording else { return CapturedAudio(samples: []) }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        // removeTap(onBus:) returns only once the tap block is no longer running, so
        // draining afterwards picks up every buffer the hardware delivered.
        let samples = accumulator?.drain() ?? []
        accumulator = nil

        levelContinuation?.finish()
        levelContinuation = nil

        // Off the release-to-paste path: the samples are complete, and the
        // pause blocks on the current hardware I/O cycle. The microphone
        // indicator going off a few milliseconds later is invisible; the
        // pause blocking here is not.
        Task { [weak self] in await self?.pauseIfIdle() }
        let logged = CapturedAudio(samples: samples)
        Self.log.log("capture stop: \(logged.samples.count) samples (\(logged.duration, format: .fixed(precision: 2)) s), pause deferred")
        return logged
    }

    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "capture")

    /// Pauses the engine unless a new recording started while the pause was
    /// queued. `startEngineIfNeeded` skips `start()` when the engine is still
    /// running, so a back-to-back recording stays live either way.
    private func pauseIfIdle() {
        guard !isRecording else {
            Self.log.log("pause skipped: a recording is active")
            return
        }
        engine.pause()
        Self.log.log("engine paused")
    }

    // MARK: Engine

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        // Touching inputNode attaches it and makes the engine adopt the current input
        // device's format. With no permission or no device this reports 0 Hz / 0 channels.
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    private func installTap(
        into accumulator: SampleAccumulator,
        continuation: AsyncStream<Float>.Continuation
    ) throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        let targetFormat = try AudioResampler.monoFloat32Format(sampleRate: Self.targetSampleRate)
        // One converter per recording keeps the resampler's filter state continuous
        // across tap buffers.
        let converter = try AudioResampler.makeConverter(from: inputFormat, to: targetFormat)
        let processor = TapProcessor(converter: converter, targetFormat: targetFormat, accumulator: accumulator)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) { buffer, _ in
            // Realtime audio thread. No actor hops, no locks held by anyone else.
            let level = processor.process(buffer)
            continuation.yield(level)
        }
    }

    // MARK: Device changes

    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleConfigurationChange() }
        }
        configurationObserver = NotificationObserver(token: token)
    }

    /// The default input or output device changed. AVAudioEngine tears down its graph
    /// and stops. With a recording in flight, restart it and reinstall the tap against
    /// the new input format, in front of the same accumulator so what has been
    /// captured so far is kept; otherwise the next `start()` restarts it.
    private func handleConfigurationChange() {
        guard isRecording, let accumulator, let continuation = levelContinuation else { return }
        engine.inputNode.removeTap(onBus: 0)
        // Either failure leaves the recording without a tap until stop(), which
        // still returns whatever was captured before the change; the new device
        // may simply not be usable.
        do {
            try startEngineIfNeeded()
            try installTap(into: accumulator, continuation: continuation)
        } catch {
            Self.log.error("device change: capture did not resume: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Unregisters a block-based notification observer when the owner goes away.
///
/// The actor cannot do this in its own `deinit` (a nonisolated deinit may not touch
/// non-`Sendable` isolated state), so the token's lifetime does the work instead.
private final class NotificationObserver: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

/// The converter one tap block runs its buffers through, in front of the
/// recording's accumulator.
///
/// `@unchecked Sendable` because `AVAudioConverter` is not `Sendable`. Only the tap
/// block calls `process(_:)`, and CoreAudio serialises tap blocks, so the converter
/// is never used from two threads; the samples it produces go into the
/// accumulator, which has a lock of its own.
private final class TapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let accumulator: SampleAccumulator

    init(converter: AVAudioConverter, targetFormat: AVAudioFormat, accumulator: SampleAccumulator) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.accumulator = accumulator
    }

    /// Called on the realtime audio thread. Converts to 16 kHz mono, accumulates, and
    /// returns the meter level for this buffer.
    func process(_ buffer: AVAudioPCMBuffer) -> Float {
        let converted: [Float]
        do {
            converted = try AudioResampler.convertChunk(buffer, using: converter, to: targetFormat)
        } catch {
            return 0
        }
        guard !converted.isEmpty else { return 0 }
        let level = AudioResampler.rmsLevel(converted)
        accumulator.append(converted)
        return level
    }
}
