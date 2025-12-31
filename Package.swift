// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectEcho",
    platforms: [
        .macOS(.v14) // Sonoma minimum
    ],
    products: [
        .executable(name: "ProjectEcho", targets: ["ProjectEcho"])
    ],
    dependencies: [
        // WhisperKit for local transcription
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.7.0"),
        // SQLite wrapper
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0"),
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
                .product(name: "WhisperKit", package: "WhisperKit")
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
            name: "ProjectEcho",
            dependencies: ["AudioEngine", "Intelligence", "Database", "UI"],
            path: "Sources/App"
        ),
        
        // Tests
        .testTarget(
            name: "ProjectEchoTests",
            dependencies: ["AudioEngine", "Intelligence", "Database"]
        )
    ]
)
