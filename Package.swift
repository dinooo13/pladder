// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pladder",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Pladder", targets: ["Pladder"]),
        .executable(name: "pladder-cli", targets: ["PladderCLI"]),
        .library(name: "PladderCore", targets: ["PladderCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
    ],
    targets: [
        // Pure logic. Imports Foundation only, so tests stay fast and engines
        // remain swappable.
        .target(name: "PladderCore"),

        // Microphone capture and resampling.
        .target(name: "PladderAudio", dependencies: ["PladderCore"]),

        // Hotkey, pasteboard output, permissions, optional Foundation Models
        // processor. AppKit lives here.
        .target(name: "PladderSystem", dependencies: ["PladderCore"]),

        // Concrete transcription engines.
        .target(
            name: "PladderEngines",
            dependencies: [
                "PladderCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        // The menu bar app.
        .executableTarget(
            name: "Pladder",
            dependencies: ["PladderCore", "PladderAudio", "PladderSystem", "PladderEngines"],
            // Info.plist is copied into the .app by scripts/bundle.sh; SwiftPM
            // refuses to treat it as a resource, so keep it out of the bundle.
            exclude: ["Resources/Info.plist"]
        ),

        // Benchmark helpers (word error rate). Only the CLI links this; the
        // app carries nothing benchmark-related.
        .target(name: "PladderBench"),

        // Developer tool: transcribe a file from the terminal to verify
        // engines, or run the benchmark (see docs/BENCHMARKS.md).
        .executableTarget(
            name: "PladderCLI",
            dependencies: ["PladderCore", "PladderEngines", "PladderAudio", "PladderBench"]
        ),

        .testTarget(name: "PladderCoreTests", dependencies: ["PladderCore"]),
        .testTarget(name: "PladderAudioTests", dependencies: ["PladderAudio"]),
        .testTarget(name: "PladderBenchTests", dependencies: ["PladderBench"]),
    ]
)
