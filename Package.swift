// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpeakUp",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SpeakUp", targets: ["SpeakUp"]),
        .executable(name: "speakup-cli", targets: ["SpeakUpCLI"]),
        .library(name: "SpeakUpCore", targets: ["SpeakUpCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
    ],
    targets: [
        // Pure logic. Imports Foundation only, so tests stay fast and engines
        // remain swappable.
        .target(name: "SpeakUpCore"),

        // Microphone capture and resampling.
        .target(name: "SpeakUpAudio", dependencies: ["SpeakUpCore"]),

        // Hotkey, pasteboard output, permissions, optional Foundation Models
        // processor. AppKit lives here.
        .target(name: "SpeakUpSystem", dependencies: ["SpeakUpCore"]),

        // Concrete transcription engines.
        .target(
            name: "SpeakUpEngines",
            dependencies: [
                "SpeakUpCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        // The menu bar app.
        .executableTarget(
            name: "SpeakUp",
            dependencies: ["SpeakUpCore", "SpeakUpAudio", "SpeakUpSystem", "SpeakUpEngines"],
            // Info.plist is copied into the .app by scripts/bundle.sh; SwiftPM
            // refuses to treat it as a resource, so keep it out of the bundle.
            exclude: ["Resources/Info.plist"]
        ),

        // Benchmark helpers (word error rate). Only the CLI links this; the
        // app carries nothing benchmark-related.
        .target(name: "SpeakUpBench"),

        // Developer tool: transcribe a file from the terminal to verify
        // engines, or run the benchmark (see docs/BENCHMARKS.md).
        .executableTarget(
            name: "SpeakUpCLI",
            dependencies: ["SpeakUpCore", "SpeakUpEngines", "SpeakUpAudio", "SpeakUpBench"]
        ),

        .testTarget(name: "SpeakUpCoreTests", dependencies: ["SpeakUpCore"]),
        .testTarget(name: "SpeakUpAudioTests", dependencies: ["SpeakUpAudio"]),
        .testTarget(name: "SpeakUpBenchTests", dependencies: ["SpeakUpBench"]),
    ]
)
