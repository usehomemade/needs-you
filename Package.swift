// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NeedsYou",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Local speech: Parakeet (speech to text) and Kokoro (voice) on the Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
        // Whisper large-v3-turbo for the command and wake check (better in game noise).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // In-app updates (signed appcast, "Check for Updates…").
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .target(name: "NeedsYouShared"),
        .executableTarget(name: "NeedsYou", dependencies: ["NeedsYouShared", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "WhisperKit", package: "WhisperKit"), .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "needs-you", dependencies: ["NeedsYouShared"]),
        .testTarget(name: "NeedsYouSharedTests", dependencies: ["NeedsYouShared"], path: "Tests/NeedsYouSharedTests"),
    ],
    swiftLanguageVersions: [.v5]
)
