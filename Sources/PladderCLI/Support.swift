@preconcurrency import AVFoundation
import Darwin
import Foundation
import PladderAudio
import PladderCore
import PladderEngines

/// Writes to stderr, so nothing but results ever reaches stdout: a script
/// reading a transcript from `pladder-cli <file>` sees the transcript alone.
func eprint(_ message: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((message + terminator).utf8))
}

/// The engine the app runs by default, built from the catalog the app builds
/// its registry from.
func makeEngine() -> any TranscriptionEngine {
    StandardEngines.defaultEntry.make()
}

func loadSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw NSError(domain: "cli", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported audio format"]) }
    try file.read(into: input)
    let target = try AudioResampler.monoFloat32Format()
    return try AudioResampler.convert(input, to: target)
}

/// Loads the engine, printing download progress, and returns the wall-clock
/// load time. In a fresh process this is the cold start the app pays at launch.
func loadEngine(_ engine: any TranscriptionEngine) async throws -> Duration {
    let clock = ContinuousClock()
    let started = clock.now
    var lastPrinted = -1
    let statusTask = Task {
        while !Task.isCancelled {
            if case .downloading(let p) = await engine.status, let p {
                let pct = Int(p * 100)
                // stderr, so a first run's download never lands in a transcript.
                if pct != lastPrinted {
                    eprint("downloading \(pct)%")
                    lastPrinted = pct
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
    defer { statusTask.cancel() }
    do {
        try await engine.load()
    } catch {
        // The engine's own wording for the failure — the line the menu shows —
        // rather than a top-level trap printing the raw error, so a download
        // that never finished can be diagnosed from the terminal.
        if case .failed(let failure) = await engine.status {
            // A developer tool: the enum's own shape is the diagnosis, and
            // the wording that reaches users lives in the app.
            eprint("model failed: \(failure)")
            exit(1)
        }
        throw error
    }
    return clock.now - started
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    // The value ends in a NUL, which is not part of the string.
    return String(decoding: buffer.prefix(size).prefix { $0 != 0 }, as: UTF8.self)
}

/// Physical memory footprint of this process, the number Activity Monitor
/// shows in its Memory column.
func physicalFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}

/// One-minute load average, so the conditions of a run are on the record.
func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) > 0 ? loads[0] : 0
}

/// Empty when the chip is at its normal thermal state, else a tag for the
/// run line, because a throttled run is not comparable.
func thermalTag() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return ""
    case .fair: return " [thermal: fair]"
    case .serious: return " [thermal: serious]"
    case .critical: return " [thermal: critical]"
    @unknown default: return " [thermal: unknown]"
    }
}
