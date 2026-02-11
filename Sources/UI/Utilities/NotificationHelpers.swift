import Foundation

/// Convenience extensions for posting common app notifications
public extension NotificationCenter {

    /// Post a processing started notification
    func postProcessingStarted(recordingId: Int64, type: ProcessingType) {
        post(
            name: .processingDidStart,
            object: nil,
            userInfo: ["recordingId": recordingId, "type": type.rawValue]
        )
    }

    /// Post a processing completed notification
    func postProcessingCompleted(recordingId: Int64, type: ProcessingType) {
        post(
            name: .processingDidComplete,
            object: nil,
            userInfo: ["recordingId": recordingId, "type": type.rawValue]
        )
    }

    /// Post a recording content updated notification
    func postRecordingContentUpdated(recordingId: Int64, contentType: String) {
        post(
            name: .recordingContentDidUpdate,
            object: nil,
            userInfo: ["recordingId": recordingId, "type": contentType]
        )
    }

    /// Post a recording saved notification
    func postRecordingSaved(recordingId: Int64) {
        post(
            name: .recordingDidSave,
            object: nil,
            userInfo: ["recordingId": recordingId]
        )
    }

    /// Post a transcription requested notification
    func postTranscriptionRequested(recordingId: Int64, audioURL: URL) {
        post(
            name: .transcriptionRequested,
            object: nil,
            userInfo: [
                "recordingId": recordingId,
                "audioURL": audioURL
            ]
        )
    }

    /// Post a processing status requested notification
    func postProcessingStatusRequested(recordingId: Int64) {
        post(
            name: .processingStatusRequested,
            object: nil,
            userInfo: ["recordingId": recordingId]
        )
    }

    /// Post a processing status response notification
    func postProcessingStatusResponse(recordingId: Int64, isTranscribing: Bool) {
        post(
            name: .processingStatusResponse,
            object: nil,
            userInfo: [
                "recordingId": recordingId,
                "isTranscribing": isTranscribing
            ]
        )
    }

    /// Post a processing queue status changed notification
    func postProcessingQueueDidChange(transcriptionQueue: Int, aiGenerationQueue: Int) {
        post(
            name: .processingQueueDidChange,
            object: nil,
            userInfo: [
                "transcriptionQueue": transcriptionQueue,
                "aiGenerationQueue": aiGenerationQueue
            ]
        )
    }
}
