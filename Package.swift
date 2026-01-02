// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectEcho",
    platforms: [
        .macOS(.v14) // Sonoma minimum
    ],
    products: [
        .executable(name: "ProjectEcho", targets: ["App"])
    ],
    dependencies: [
        // WhisperKit for local transcription
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.7.0"),
        // SQLite wrapper
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0"),
        // FluidAudio for speaker diarization (CoreML, local)
        // Using main branch for Swift 6 compatibility fixes
        .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main"),
    ],
    targets: [
        // Core Audio Engine
        .target(
            name: "AudioEngine",
            dependencies: [],
            path: "Sources/AudioEngine"
        ),
        
        // Intelligence Layer (Transcription & AI)
        .target(
            name: "Intelligence",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Intelligence"
        ),
        
        // Database Layer
        .target(
            name: "Database",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "Sources/Database"
        ),
        
        // UI Components
        .target(
            name: "UI",
            dependencies: ["AudioEngine", "Intelligence", "Database"],
            path: "Sources/UI"
        ),
        
        // Main App
        .executableTarget(
            name: "App",
            dependencies: ["AudioEngine", "Intelligence", "Database", "UI"],
            path: "Sources/App"
        ),
        
        // Tests
        .testTarget(
            name: "ProjectEchoTests",
            dependencies: ["AudioEngine", "Intelligence", "Database"]
        )
    ],
    // Use Swift 5 language mode for compatibility with FluidAudio dependency
    swiftLanguageModes: [.v5]
)
