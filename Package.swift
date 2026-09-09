// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpeakUp",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SpeakUp", targets: ["SpeakUp"]),
        .library(name: "SpeakUpCore", targets: ["SpeakUpCore"]),
    ],
    dependencies: [
        // FluidAudio dependency is added by the engines module below.
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
        .target(name: "SpeakUpEngines", dependencies: ["SpeakUpCore"]),

        // The menu bar app.
        .executableTarget(
            name: "SpeakUp",
            dependencies: ["SpeakUpCore", "SpeakUpAudio", "SpeakUpSystem", "SpeakUpEngines"],
            resources: [.process("Resources")]
        ),

        .testTarget(name: "SpeakUpCoreTests", dependencies: ["SpeakUpCore"]),
    ]
)
