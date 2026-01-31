// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import Foundation

/// Transcription provider selection
public enum TranscriptionProvider: String, Sendable, CaseIterable, Codable {
    case local = "whisperkit"
    case gemini = "gemini-cloud"

    public var displayName: String {
        switch self {
        case .local:
            return "Local (WhisperKit)"
        case .gemini:
            return "Gemini Cloud"
        }
    }

    public var description: String {
        switch self {
        case .local:
            return "On-device transcription using WhisperKit. Private and offline-capable."
        case .gemini:
            return "Cloud transcription using Google's Gemini. Requires API key."
        }
    }
}

/// Available Gemini models for transcription
public enum GeminiModel: String, Sendable, CaseIterable, Codable {
    case gemini3Pro = "gemini-3-pro-preview"
    case gemini3Flash = "gemini-3-flash-preview"
    case gemini25FlashLite = "gemini-2.5-flash-lite"
    case gemini20Flash = "gemini-2.0-flash"

    public var displayName: String {
        switch self {
        case .gemini3Pro:
            return "Gemini 3 Pro (Best quality)"
        case .gemini3Flash:
            return "Gemini 3 Flash (Recommended)"
        case .gemini25FlashLite:
            return "Gemini 2.5 Flash Lite (Fastest/Cheapest)"
        case .gemini20Flash:
            return "Gemini 2.0 Flash (Stable)"
        }
    }

    public var description: String {
        switch self {
        case .gemini3Pro:
            return "Highest accuracy, advanced reasoning. Best for complex meetings."
        case .gemini3Flash:
            return "Good balance of speed and quality. Recommended for most use cases."
        case .gemini25FlashLite:
            return "Fastest and lowest cost. Good for simple conversations."
        case .gemini20Flash:
            return "Stable release. Reliable fallback option."
        }
    }
}

/// Configuration for transcription providers
public struct TranscriptionConfig: Codable, Sendable, Equatable {
    public var provider: TranscriptionProvider
    public var whisperModel: String
    public var geminiAPIKey: String
    public var geminiModel: GeminiModel

    public init(
        provider: TranscriptionProvider = .local,
        whisperModel: String = "small.en",
        geminiAPIKey: String = "",
        geminiModel: GeminiModel = .gemini3Flash
    ) {
        self.provider = provider
        self.whisperModel = whisperModel
        self.geminiAPIKey = geminiAPIKey
        self.geminiModel = geminiModel
    }

    /// Load config from UserDefaults
    public static func load() -> TranscriptionConfig {
        let defaults = UserDefaults.standard
        return TranscriptionConfig(
            provider: TranscriptionProvider(rawValue: defaults.string(forKey: "transcriptionProvider") ?? "whisperkit") ?? .local,
            whisperModel: defaults.string(forKey: "whisperModel") ?? "small.en",
            geminiAPIKey: defaults.string(forKey: "geminiAPIKey") ?? "",
            geminiModel: GeminiModel(rawValue: defaults.string(forKey: "geminiModel") ?? "gemini-3-flash-preview") ?? .gemini3Flash
        )
    }

    /// Save config to UserDefaults
    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: "transcriptionProvider")
        defaults.set(whisperModel, forKey: "whisperModel")
        defaults.set(geminiAPIKey, forKey: "geminiAPIKey")
        defaults.set(geminiModel.rawValue, forKey: "geminiModel")
    }
}
