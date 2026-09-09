import AVFoundation
import SpeakUpCore

/// Microphone capture built on `AVAudioEngine`.
///
/// Lifetime: the engine is created once and kept running for the life of the app.
/// `warmUp()` starts it at launch so the first push-to-talk press has no hardware
/// start-up latency; the tap is the only thing installed and removed per recording,
/// and an idle running engine with no tap costs nothing measurable.
///
/// Threading: the tap block runs on a realtime audio thread. It must never touch
/// actor state, allocate unpredictably, or `await` anything. Everything it needs
/// lives in `TapProcessor`, a lock-protected class it owns outright, plus the
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
    private var processor: TapProcessor?
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var isRecording = false
    private var configurationObserver: NotificationObserver?
    /// Samples salvaged from a previous `TapProcessor` when the audio device changed
    /// mid-recording, so a device switch does not lose what was said before it.
    private var carriedSamples: [Float] = []

    public init() {}

    // MARK: AudioCapture

    /// Starts the engine ahead of time. Throws if the engine will not start, which on
    /// a first launch usually means microphone permission has not been granted yet;
    /// `start()` retries, so a throw here is not fatal.
    public func warmUp() async throws {
        observeConfigurationChanges()
        try startEngineIfNeeded()
    }

    public func start() async throws -> AsyncStream<Float> {
        if isRecording {
            _ = await stop()
        }
        observeConfigurationChanges()
        // warmUp() may have failed (no permission at launch); retry here.
        try startEngineIfNeeded()

        carriedSamples.removeAll(keepingCapacity: false)
        let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        levelContinuation = continuation
        do {
            try installTap(continuation: continuation)
        } catch {
            continuation.finish()
            levelContinuation = nil
            throw error
        }
        isRecording = true
        return stream
    }

    public func stop() async -> CapturedAudio {
        guard isRecording else { return CapturedAudio(samples: []) }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        // removeTap(onBus:) returns only once the tap block is no longer running, so
        // draining afterwards picks up every buffer the hardware delivered.
        var samples = carriedSamples
        carriedSamples.removeAll(keepingCapacity: false)
        if let processor {
            samples.append(contentsOf: processor.drain())
        }
        processor = nil

        levelContinuation?.finish()
        levelContinuation = nil

        // The engine keeps running so the next recording starts instantly.
        return CapturedAudio(samples: samples)
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

    private func installTap(continuation: AsyncStream<Float>.Continuation) throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        let targetFormat = try AudioResampler.monoFloat32Format(sampleRate: Self.targetSampleRate)
        // One converter per recording keeps the resampler's filter state continuous
        // across tap buffers.
        let converter = try AudioResampler.makeConverter(from: inputFormat, to: targetFormat)
        let processor = TapProcessor(converter: converter, targetFormat: targetFormat)
        self.processor = processor

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
    /// and stops, so restart it and — if a recording is in flight — reinstall the tap
    /// against the new input format, keeping what has been captured so far.
    private func handleConfigurationChange() {
        let wasRecording = isRecording
        if wasRecording, let processor {
            carriedSamples.append(contentsOf: processor.drain())
            engine.inputNode.removeTap(onBus: 0)
            self.processor = nil
        }

        do {
            try startEngineIfNeeded()
        } catch {
            // Nothing to do: the new device may not be usable. stop() still returns
            // whatever was captured before the change.
            return
        }

        guard wasRecording, isRecording, let continuation = levelContinuation else { return }
        try? installTap(continuation: continuation)
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

/// Everything the realtime tap block touches, behind one lock.
///
/// `@unchecked Sendable` because `AVAudioConverter` and `AVAudioPCMBuffer` are not
/// `Sendable`: the lock is what actually makes this safe. Taps are serialised by
/// CoreAudio, so in practice only the audio thread calls `process(_:)` and only the
/// actor calls `drain()`; the lock protects that hand-off.
private final class TapProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private var samples: [Float] = []

    init(converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        self.converter = converter
        self.targetFormat = targetFormat
        // A recording is usually a few seconds; reserve 10 s of 16 kHz mono up front so
        // the audio thread rarely has to grow the array.
        samples.reserveCapacity(160_000)
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
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()
        return level
    }

    /// Takes everything captured so far and resets the accumulator.
    func drain() -> [Float] {
        lock.lock()
        defer {
            samples.removeAll(keepingCapacity: false)
            lock.unlock()
        }
        return samples
    }
}
