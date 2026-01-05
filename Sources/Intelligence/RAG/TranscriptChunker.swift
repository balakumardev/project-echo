import Foundation
import Database

/// Chunks transcripts based on context limits
public struct TranscriptChunker: Sendable {

    public init() {}

    // MARK: - Token Estimation

    /// Estimate token count for text (rough: 1 token ≈ 4 characters)
    public func estimateTokens(_ text: String) -> Int {
        return (text.count + 3) / 4
    }

    /// Check if transcript needs chunking
    public func needsChunking(transcriptTokens: Int, config: ChunkingConfig) -> Bool {
        // Leave room for system prompt (~200 tokens) and response (~500 tokens)
        let availableTokens = config.maxTokens - 700
        return transcriptTokens > availableTokens
    }

    // MARK: - Chunking

    /// Chunk segments into context-appropriate pieces
    /// - Parameters:
    ///   - segments: Transcript segments to chunk
    ///   - recordingId: ID of the recording
    ///   - config: Chunking configuration (token limits)
    /// - Returns: Array of chunks
    public func chunk(
        segments: [DatabaseManager.TranscriptSegment],
        recordingId: Int64,
        config: ChunkingConfig
    ) -> [TranscriptChunk] {
        guard !segments.isEmpty else { return [] }

        var chunks: [TranscriptChunk] = []
        var currentSegments: [DatabaseManager.TranscriptSegment] = []
        var currentText = ""
        var currentTokens = 0

        // Leave room for prompt overhead
        let effectiveMaxTokens = config.maxTokens - 500

        for segment in segments {
            let segmentText = "[\(formatTime(segment.startTime))] \(segment.speaker): \(segment.text)\n"
            let segmentTokens = estimateTokens(segmentText)

            // Check if adding this segment would exceed limit
            if currentTokens + segmentTokens > effectiveMaxTokens && !currentSegments.isEmpty {
                // Finalize current chunk
                let chunk = TranscriptChunk(
                    recordingId: recordingId,
                    startTime: currentSegments.first!.startTime,
                    endTime: currentSegments.last!.endTime,
                    text: currentText,
                    segmentIds: currentSegments.map { $0.id },
                    estimatedTokens: currentTokens
                )
                chunks.append(chunk)

                // Start new chunk with overlap
                let overlapSegments = getOverlapSegments(
                    from: currentSegments,
                    maxTokens: config.overlapTokens
                )
                currentSegments = overlapSegments
                currentText = overlapSegments.map { seg in
                    "[\(formatTime(seg.startTime))] \(seg.speaker): \(seg.text)\n"
                }.joined()
                currentTokens = estimateTokens(currentText)
            }

            // Add segment to current chunk
            currentSegments.append(segment)
            currentText += segmentText
            currentTokens += segmentTokens
        }

        // Add final chunk if there's content
        if !currentSegments.isEmpty {
            let chunk = TranscriptChunk(
                recordingId: recordingId,
                startTime: currentSegments.first!.startTime,
                endTime: currentSegments.last!.endTime,
                text: currentText,
                segmentIds: currentSegments.map { $0.id },
                estimatedTokens: currentTokens
            )
            chunks.append(chunk)
        }

        return chunks
    }

    // MARK: - Helpers

    /// Get overlap segments from the end of a chunk
    private func getOverlapSegments(
        from segments: [DatabaseManager.TranscriptSegment],
        maxTokens: Int
    ) -> [DatabaseManager.TranscriptSegment] {
        var overlapSegments: [DatabaseManager.TranscriptSegment] = []
        var tokenCount = 0

        // Take segments from end until we hit token limit
        for segment in segments.reversed() {
            let segmentText = "[\(formatTime(segment.startTime))] \(segment.speaker): \(segment.text)\n"
            let segmentTokens = estimateTokens(segmentText)

            if tokenCount + segmentTokens > maxTokens {
                break
            }

            overlapSegments.insert(segment, at: 0)
            tokenCount += segmentTokens
        }

        return overlapSegments
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

