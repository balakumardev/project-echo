import Foundation

/// Centralized constants for the Engram app
public enum AppConstants {

    /// UserDefaults keys used throughout the app
    public enum UserDefaultsKeys {
        // MARK: - General Settings
        public static let autoRecord = "autoRecord"
        public static let autoTranscribe = "autoTranscribe"
        public static let autoRecordOnWake = "autoRecordOnWake"
        public static let recordVideoEnabled = "recordVideoEnabled"
        public static let windowSelectionMode = "windowSelectionMode"
        public static let storageLocation = "storageLocation"
        public static let sampleRate = "sampleRate"
        public static let audioQuality = "audioQuality"

        // MARK: - Meeting Apps
        public static let enabledMeetingApps = "enabledMeetingApps"
        public static let monitoredApps = "monitoredApps"
        public static let customMeetingApps = "customMeetingApps"

        // MARK: - AI Settings
        public static let aiEnabled = "aiEnabled"
        public static let autoIndexTranscripts = "autoIndexTranscripts"
        public static let autoGenerateSummary = "autoGenerateSummary"
        public static let autoGenerateActionItems = "autoGenerateActionItems"
        public static let aiServiceConfig = "AIService.config"

        // MARK: - UI State
        public static let showChatPanel = "showChatPanel_v2"

        // MARK: - Transcription Provider
        public static let transcriptionProvider = "transcriptionProvider"
        public static let whisperModel = "whisperModel"
        public static let geminiAPIKey = "geminiAPIKey"
        public static let geminiModel = "geminiModel"
    }

    /// Window identifiers for SwiftUI
    public enum WindowIDs {
        public static let library = "library"
    }

    /// Logger subsystem for OSLog
    public static let loggerSubsystem = "dev.balakumar.engram"
}
