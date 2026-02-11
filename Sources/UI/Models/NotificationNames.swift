import Foundation

// MARK: - Recording Notifications

/// Notification names for reactive UI updates
public extension Notification.Name {
    /// Posted when a new recording is saved to the database
    /// userInfo: ["recordingId": Int64]
    static let recordingDidSave = Notification.Name("Engram.recordingDidSave")

    /// Posted when a recording is deleted
    /// userInfo: ["recordingId": Int64]
    static let recordingDidDelete = Notification.Name("Engram.recordingDidDelete")

    /// Posted when recording content is updated (transcript, summary, action items)
    /// userInfo: ["recordingId": Int64, "type": String] where type is "transcript", "summary", or "actionItems"
    static let recordingContentDidUpdate = Notification.Name("Engram.recordingContentDidUpdate")

    /// Posted when background processing starts
    /// userInfo: ["recordingId": Int64, "type": String] where type is "transcription", "summary", or "actionItems"
    static let processingDidStart = Notification.Name("Engram.processingDidStart")

    /// Posted when background processing completes
    /// userInfo: ["recordingId": Int64, "type": String]
    static let processingDidComplete = Notification.Name("Engram.processingDidComplete")

    /// Posted when the processing queue status changes
    /// userInfo: ["transcriptionQueue": Int, "aiGenerationQueue": Int]
    static let processingQueueDidChange = Notification.Name("Engram.processingQueueDidChange")

    /// Posted to request opening a recording at a specific timestamp (e.g., from citation tap)
    /// userInfo: ["recordingId": Int64, "timestamp": TimeInterval]
    static let openRecordingAtTimestamp = Notification.Name("Engram.openRecordingAtTimestamp")

    /// Posted by UI to request transcription through ProcessingQueue
    /// userInfo: ["recordingId": Int64, "audioURL": URL]
    static let transcriptionRequested = Notification.Name("Engram.transcriptionRequested")

    /// Posted by UI to request current processing status for a recording
    /// userInfo: ["recordingId": Int64]
    static let processingStatusRequested = Notification.Name("Engram.processingStatusRequested")

    /// Posted by ProcessingQueue in response to status request
    /// userInfo: ["recordingId": Int64, "isTranscribing": Bool]
    static let processingStatusResponse = Notification.Name("Engram.processingStatusResponse")
}
