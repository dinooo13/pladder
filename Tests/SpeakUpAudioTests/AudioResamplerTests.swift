import AVFoundation
import Testing

@testable import SpeakUpAudio

/// Conversion and metering tests. Everything is synthesised, so these run with no
/// microphone, no permission prompt and no audio hardware.
@Suite("AudioResampler")
struct AudioResamplerTests {

    // MARK: Helpers

    /// A deinterleaved Float32 buffer holding `duration` seconds of a sine, the same
    /// signal on every channel.
    static func sineBuffer(
        frequency: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        duration: Double,
        amplitude: Float = 1.0
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
        )
        let frames = AVAudioFrameCount(sampleRate * duration)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames

        let data = try #require(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<Int(channels) {
                data[channel][frame] = value
            }
        }
        return buffer
    }

    /// Number of sign changes in the signal. A pure `f` Hz tone lasting one second
    /// crosses zero `2 * f` times.
    static func zeroCrossings(_ samples: [Float]) -> Int {
        var count = 0
        var previous: Float = 0
        for sample in samples where sample != 0 {
            if previous != 0, (sample < 0) != (previous < 0) {
                count += 1
            }
            previous = sample
        }
        return count
    }

    // MARK: Conversion

    @Test("48 kHz stereo converts to 16 kHz mono with the right length")
    func downsampleLength() throws {
        let input = try Self.sineBuffer(frequency: 440, sampleRate: 48_000, channels: 2, duration: 1.0)
        let target = try AudioResampler.monoFloat32Format()

        let output = try AudioResampler.convert(input, to: target)

        #expect(abs(output.count - 16_000) <= 100, "got \(output.count) samples")
    }

    @Test("Peak amplitude survives the resample")
    func peakPreserved() throws {
        let input = try Self.sineBuffer(frequency: 440, sampleRate: 48_000, channels: 2, duration: 1.0)
        let target = try AudioResampler.monoFloat32Format()

        let output = try AudioResampler.convert(input, to: target)
        let peak = output.map(abs).max() ?? 0

        // The resampling filter can ring a hair above full scale on a unit sine, so
        // allow a 1% overshoot on the upper bound.
        #expect(peak >= 0.9 && peak <= 1.01, "peak was \(peak)")
    }

    @Test("The 440 Hz tone is still dominant after conversion")
    func toneSurvives() throws {
        let input = try Self.sineBuffer(frequency: 440, sampleRate: 48_000, channels: 2, duration: 1.0)
        let target = try AudioResampler.monoFloat32Format()

        let output = try AudioResampler.convert(input, to: target)
        let crossings = Self.zeroCrossings(output)

        #expect(abs(crossings - 880) <= 20, "counted \(crossings) zero crossings")
    }

    @Test("Mono input converts too")
    func monoInput() throws {
        let input = try Self.sineBuffer(frequency: 440, sampleRate: 44_100, channels: 1, duration: 0.5)
        let target = try AudioResampler.monoFloat32Format()

        let output = try AudioResampler.convert(input, to: target)

        #expect(abs(output.count - 8_000) <= 100, "got \(output.count) samples")
    }

    @Test("Streaming conversion of successive chunks totals the same length")
    func streamingChunks() throws {
        let target = try AudioResampler.monoFloat32Format()
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)
        )
        let converter = try AudioResampler.makeConverter(from: format, to: target)

        var total = 0
        // Ten 2048-frame buffers, the same shape the microphone tap delivers.
        for _ in 0..<10 {
            let buffer = try Self.sineBuffer(frequency: 440, sampleRate: 48_000, channels: 2, duration: 2048.0 / 48_000)
            total += try AudioResampler.convertChunk(buffer, using: converter, to: target).count
        }

        let expected = Int(10.0 * 2048.0 / 3.0)
        #expect(abs(total - expected) <= 100, "got \(total) samples, expected about \(expected)")
    }

    @Test("An empty buffer converts to nothing")
    func emptyBuffer() throws {
        let target = try AudioResampler.monoFloat32Format()
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 0

        #expect(try AudioResampler.convert(buffer, to: target).isEmpty)
    }

    // MARK: Level

    @Test("Silence meters as zero")
    func silenceLevel() {
        #expect(AudioResampler.rmsLevel([Float](repeating: 0, count: 1024)) == 0)
        #expect(AudioResampler.rmsLevel([]) == 0)
    }

    @Test("A full-scale square wave meters as one")
    func fullScaleLevel() {
        let square = (0..<1024).map { Float($0 % 2 == 0 ? 1.0 : -1.0) }
        #expect(AudioResampler.rmsLevel(square) == 1)
    }

    @Test("A -20 dBFS sine meters at about 0.6")
    func quietSineLevel() {
        // -20 dBFS means an RMS of 0.1, so a sine needs a peak of 0.1 * sqrt(2).
        let amplitude = Float(0.1 * 2.0.squareRoot())
        let sine = (0..<16_000).map { amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }

        let level = AudioResampler.rmsLevel(sine)

        #expect(abs(level - 0.6) < 0.02, "level was \(level)")
    }

    @Test("Levels below -50 dBFS clamp to zero")
    func floorClamps() {
        let veryQuiet = [Float](repeating: 0.0001, count: 1024)
        #expect(AudioResampler.rmsLevel(veryQuiet) == 0)
    }
}
