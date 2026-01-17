// swift-tools-version: 6.0
// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import PackageDescription

let package = Package(
    name: "Engram",
    platforms: [
        .macOS(.v15) // Sequoia - matches current OS, avoids Swift runtime compatibility issues
    ],
    products: [
        .executable(name: "Engram", targets: ["App"])
    ],
    dependencies: [
        // WhisperKit for local transcription
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.7.0"),
        // SQLite wrapper
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0"),
        // FluidAudio for speaker diarization (CoreML, local)
        // Using main branch for Swift 6 compatibility fixes
        .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main"),
        // VecturaKit for vector database and embeddings (RAG)
        .package(url: "https://github.com/rryam/VecturaKit.git", from: "2.3.1"),
        // MLX Swift LM for local LLM inference on Apple Silicon (official Apple library)
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
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
                // RAG dependencies
                .product(name: "VecturaKit", package: "VecturaKit"),
                .product(name: "VecturaNLKit", package: "VecturaKit"),
                // MLX for local LLM inference (Apple's official library)
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // Database access for RAG
                "Database",
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
            name: "EngramTests",
            dependencies: ["AudioEngine", "Intelligence", "Database"],
            path: "Tests/EngramTests"
        )
    ],
    // Use Swift 5 language mode for compatibility with FluidAudio dependency
    swiftLanguageModes: [.v5]
)
