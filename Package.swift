// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vantage",
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic: transcript assembly, question detection, prompts, SSE parsing. No audio/UI.
        .target(name: "VantageCore"),
        // The app: audio capture, on-device transcription, LLM clients, SwiftUI.
        .executableTarget(name: "Vantage", dependencies: ["VantageCore"]),
        .testTarget(name: "VantageCoreTests", dependencies: ["VantageCore"]),
    ],
    swiftLanguageModes: [.v5]
)
