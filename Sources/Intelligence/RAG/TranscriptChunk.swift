import Foundation

/// A chunk of transcript suitable for LLM context
public struct TranscriptChunk: Sendable, Identifiable {
    public let id: UUID
    public let recordingId: Int64
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let segmentIds: [Int64]
    public let estimatedTokens: Int

    public init(
        id: UUID = UUID(),
        recordingId: Int64,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        segmentIds: [Int64],
        estimatedTokens: Int
    ) {
        self.id = id
        self.recordingId = recordingId
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.segmentIds = segmentIds
        self.estimatedTokens = estimatedTokens
    }

    /// Formatted time window (e.g., "0:00 - 5:30")
    public var timeWindow: String {
        "\(formatTime(startTime)) - \(formatTime(endTime))"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

/// Configuration for chunking transcripts
public struct ChunkingConfig: Sendable {
    /// Maximum tokens per chunk
    public let maxTokens: Int

    /// Overlap tokens between chunks (for context continuity)
    public let overlapTokens: Int

    public init(maxTokens: Int, overlapTokens: Int) {
        self.maxTokens = maxTokens
        self.overlapTokens = overlapTokens
    }

    /// Preset for local MLX models (~4K context, leave room for prompt/response)
    public static let localMLX = ChunkingConfig(
        maxTokens: 2000,
        overlapTokens: 200
    )

    /// Preset for OpenAI models (128K context, can fit much more)
    public static let openAI = ChunkingConfig(
        maxTokens: 50000,
        overlapTokens: 500
    )
}

