// Additional types and extensions for Project Echo

import Foundation

// MARK: - App Constants

public enum EchoConstants {
    public static let appName = "Project Echo"
    public static let bundleIdentifier = "com.projectecho.app"
    public static let defaultSampleRate: Double = 48000.0
    public static let defaultChannels = 2
    public static let supportedApps = [
        "Zoom",
        "Microsoft Teams",
        "Google Chrome",
        "Safari",
        "Slack",
        "Discord",
        "FaceTime"
    ]
}

// MARK: - Error Types

public enum EchoError: LocalizedError {
    case permissionDenied
    case audioDeviceNotFound
    case recordingFailed(String)
    case transcriptionFailed(String)
    case databaseError(String)
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Required permissions not granted"
        case .audioDeviceNotFound:
            return "No audio input device found"
        case .recordingFailed(let reason):
            return "Recording failed: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .databaseError(let reason):
            return "Database error: \(reason)"
        }
    }
}

// MARK: - File Size Formatter

public extension Int64 {
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}

// MARK: - Duration Formatter

public extension TimeInterval {
    var formattedDuration: String {
        let hours = Int(self) / 3600
        let minutes = Int(self) / 60 % 60
        let seconds = Int(self) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Date Formatter

public extension Date {
    var meetingDateFormat: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}
