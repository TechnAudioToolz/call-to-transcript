// swift-tools-version:5.9
// The Mac app. Build the .app with ./build.sh (no Xcode project needed).
import PackageDescription

let package = Package(
    name: "CallTranscriber",
    platforms: [.macOS(.v14)],  // Sonoma and newer
    dependencies: [
        // Speech recognition (Parakeet) and telling voices apart, on the Neural Engine.
        // A copy of FluidAudio 0.17.7 with a fix for macOS 14: see Vendor/FluidAudio/VENDORED.md
        .package(path: "Vendor/FluidAudio"),
    ],
    targets: [
        // Everything that turns a video or a recorded call into a transcript; shared by the app and the command-line tool.
        .target(
            name: "TranscriptCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/TranscriptCore"),
        .executableTarget(name: "CallTranscriber", dependencies: ["TranscriptCore"], path: "Sources/CallTranscriber"),
        // transcribe-cli video.mp4: the same engine from Terminal, for testing and scripting
        .executableTarget(name: "transcribe-cli", dependencies: ["TranscriptCore"], path: "Sources/TranscribeCLI"),
    ]
)
