// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cue",
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic: transcript assembly, question detection, prompts, SSE parsing. No audio/UI.
        .target(name: "CueCore"),
        // The app: audio capture, on-device transcription, LLM clients, SwiftUI.
        .executableTarget(name: "Cue", dependencies: ["CueCore"]),
        .testTarget(name: "CueCoreTests", dependencies: ["CueCore"]),
    ],
    swiftLanguageModes: [.v5]
)
