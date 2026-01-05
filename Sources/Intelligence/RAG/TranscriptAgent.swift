import Foundation
import os.log
import Database

/// Strategy for handling a query
public enum AgentStrategy: Sendable {
    /// Use existing RAG vector search (no recording selected, or cross-recording query)
    case ragSearch

    /// Use full transcript directly (fits in context)
    case directFullText(transcript: String, recordingTitle: String)

    /// Chunk and use map-reduce (transcript too long)
    case mapReduce(chunks: [TranscriptChunk])
}

/// Errors from agent processing
public enum AgentError: Error, LocalizedError {
    case transcriptNotFound
    case noRecordingSpecified
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .transcriptNotFound:
            return "No transcript found for this recording"
        case .noRecordingSpecified:
            return "Please select a specific recording for this query"
        case .processingFailed(let reason):
            return "Processing failed: \(reason)"
        }
    }
}

/// Autonomous agent for handling transcript queries
///
/// This agent is truly autonomous - it doesn't use hardcoded intent classification.
/// Instead, it:
/// 1. When a recording is selected → loads the full transcript into context
/// 2. Lets the LLM naturally respond to whatever the user asks
/// 3. Uses map-reduce only when transcript is too long for context
/// 4. Falls back to RAG search only when no recording is selected
@available(macOS 14.0, *)
public actor TranscriptAgent {

    // MARK: - Dependencies

    private let databaseManager: DatabaseManager
    private let llmEngine: LLMEngine
    private let chunker: TranscriptChunker
    private let summarizer: MapReduceSummarizer

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "TranscriptAgent")

    /// Debug log file for agent operations
    private static let debugLogURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("engram_rag.log")
    }()

    /// Write to debug log file
    private func debugLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [Agent] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.debugLogURL.path) {
                if let handle = try? FileHandle(forWritingTo: Self.debugLogURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.debugLogURL)
            }
        }
    }

    // MARK: - Initialization

    public init(
        databaseManager: DatabaseManager,
        llmEngine: LLMEngine
    ) {
        self.databaseManager = databaseManager
        self.llmEngine = llmEngine
        self.chunker = TranscriptChunker()
        self.summarizer = MapReduceSummarizer(llmEngine: llmEngine)
    }

    // MARK: - Public Interface

    /// Process a query and stream the response
    ///
    /// This is the main entry point. The agent autonomously decides:
    /// - If recording is selected → load full transcript, let LLM answer naturally
    /// - If transcript too long → use map-reduce chunking
    /// - If no recording selected → use RAG search across all recordings
    public func processQuery(
        query: String,
        recordingId: Int64?,
        ragPipeline: RAGPipeline,
        sessionId: String,
        conversationHistory: [LLMEngine.Message]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    self.debugLog("processQuery: '\(query)', recordingId: \(String(describing: recordingId))")

                    // Determine strategy based on whether a recording is selected
                    // NO intent classification - let LLM decide what to do with the context
                    let strategy = try await self.determineStrategy(recordingId: recordingId)
                    self.debugLog("Strategy: \(strategy)")

                    // Execute strategy
                    switch strategy {
                    case .ragSearch:
                        self.debugLog("Executing RAG search (no recording selected)...")
                        try await self.executeRAGSearch(
                            query: query,
                            recordingId: recordingId,
                            ragPipeline: ragPipeline,
                            sessionId: sessionId,
                            continuation: continuation
                        )

                    case .directFullText(let transcript, let title):
                        self.debugLog("Executing with full transcript context...")
                        try await self.executeWithFullContext(
                            query: query,
                            transcript: transcript,
                            recordingTitle: title,
                            conversationHistory: conversationHistory,
                            continuation: continuation
                        )

                    case .mapReduce(let chunks):
                        self.debugLog("Executing map-reduce with \(chunks.count) chunks...")
                        try await self.executeMapReduce(
                            query: query,
                            chunks: chunks,
                            continuation: continuation
                        )
                    }

                    self.debugLog("Query processing complete")
                    continuation.finish()

                } catch {
                    self.debugLog("ERROR: \(error.localizedDescription)")
                    self.logger.error("Agent error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Strategy Determination

    /// Determine the best strategy based on recording selection and transcript size
    /// NO intent classification - we always give the LLM full context when possible
    private func determineStrategy(recordingId: Int64?) async throws -> AgentStrategy {
        // If no recording is selected, use RAG search across all recordings
        guard let recId = recordingId else {
            debugLog("No recording selected -> using RAG search across all recordings")
            return .ragSearch
        }

        // Recording is selected - try to load the full transcript
        debugLog("Recording \(recId) selected, loading transcript...")

        guard let transcript = try await databaseManager.getTranscript(forRecording: recId) else {
            debugLog("ERROR: No transcript found for recording \(recId)")
            throw AgentError.transcriptNotFound
        }

        // Get the recording title for context
        let recordingTitle: String
        do {
            let recording = try await databaseManager.getRecording(id: recId)
            recordingTitle = recording.title
        } catch {
            recordingTitle = "Unknown Recording"
        }

        let segments = try await databaseManager.getSegments(forTranscriptId: transcript.id)
        debugLog("Found \(segments.count) segments for transcript \(transcript.id)")

        // Format the transcript with timestamps and speakers
        let formattedTranscript = segments.map { segment in
            "[\(formatTime(segment.startTime))] \(segment.speaker): \(segment.text)"
        }.joined(separator: "\n")

        let totalTokens = chunker.estimateTokens(formattedTranscript)
        let config = await getChunkingConfig()

        debugLog("Transcript: '\(recordingTitle)', \(segments.count) segments, \(totalTokens) tokens (max: \(config.maxTokens))")
        logger.info("Transcript size: \(totalTokens) tokens, max: \(config.maxTokens)")

        // Check if transcript fits in context
        if !chunker.needsChunking(transcriptTokens: totalTokens, config: config) {
            debugLog("Transcript fits in context -> giving LLM full transcript")
            return .directFullText(transcript: formattedTranscript, recordingTitle: recordingTitle)
        } else {
            // Too long - need to chunk
            let chunks = chunker.chunk(segments: segments, recordingId: recId, config: config)
            debugLog("Transcript too large -> using mapReduce with \(chunks.count) chunks")
            logger.info("Created \(chunks.count) chunks for map-reduce")
            return .mapReduce(chunks: chunks)
        }
    }

    // MARK: - Strategy Execution

    private func executeRAGSearch(
        query: String,
        recordingId: Int64?,
        ragPipeline: RAGPipeline,
        sessionId: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let stream = await ragPipeline.chat(
            query: query,
            sessionId: sessionId,
            recordingFilter: recordingId
        )

        for try await token in stream {
            continuation.yield(token)
        }
    }

    /// Execute query with full transcript in context
    /// The LLM decides what to do - summarize, extract info, answer questions, etc.
    private func executeWithFullContext(
        query: String,
        transcript: String,
        recordingTitle: String,
        conversationHistory: [LLMEngine.Message],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        debugLog("Sending query to LLM with full transcript (\(transcript.count) chars)")

        // Guard against empty transcripts - don't let LLM hallucinate
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTranscript.isEmpty {
            debugLog("WARNING: Empty transcript - returning early to prevent hallucination")
            let emptyMessage = "This recording doesn't have a transcript yet. The transcription may still be in progress, or there was no speech detected in the audio."
            continuation.yield(emptyMessage)
            return
        }

        // Generic system prompt - let LLM decide what to do
        let systemPrompt = """
            You are an intelligent meeting assistant with access to the complete transcript of a recording.

            Recording: "\(recordingTitle)"

            You have the FULL transcript below. Use it to answer the user's question or request.
            You can:
            - Summarize the meeting (if asked)
            - Extract action items or tasks (if asked)
            - Identify topics discussed (if asked)
            - Answer specific questions about what was said
            - Quote specific speakers and timestamps when relevant
            - Provide any analysis the user requests

            Be helpful, accurate, and base your response on the transcript content.
            If something isn't in the transcript, say so.
            """

        let stream = await llmEngine.generateStream(
            prompt: query,
            context: transcript,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory
        )

        // Process stream through ResponseProcessor to handle think tags and formatting
        let processor = ResponseProcessor()

        for try await token in stream {
            let output = await processor.processToken(token)

            // Only emit the processed display token - don't emit thinking status as text
            // The UI handles thinking/loading states separately via isGenerating flags
            if !output.displayToken.isEmpty {
                continuation.yield(output.displayToken)
            }
        }

        // Flush any remaining content
        let finalOutput = await processor.flush()
        if !finalOutput.displayToken.isEmpty {
            continuation.yield(finalOutput.displayToken)
        }
    }

    /// Execute map-reduce for long transcripts
    private func executeMapReduce(
        query: String,
        chunks: [TranscriptChunk],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        logger.info("Executing map-reduce with \(chunks.count) chunks")

        // Don't emit status text - the UI handles loading states separately

        // For map-reduce, we need to tell each chunk what to extract
        // We'll use a generic approach that works for any query
        let chunkSummaries = try await summarizer.mapChunksGeneric(chunks, query: query)

        let finalResponse = try await summarizer.reduceGeneric(
            summaries: chunkSummaries,
            originalQuery: query
        )

        // Clean up the final response (removes any think tags, formats nicely)
        let cleanedResponse = ResponseProcessor.formatResponse(finalResponse)

        for char in cleanedResponse {
            continuation.yield(String(char))
        }
    }

    // MARK: - Helpers

    private func getChunkingConfig() async -> ChunkingConfig {
        if await llmEngine.isMLXBackend {
            return .localMLX
        } else {
            return .openAI
        }
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

