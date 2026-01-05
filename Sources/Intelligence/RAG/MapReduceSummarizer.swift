import Foundation
import os.log

/// Intermediate result from map phase
public struct ChunkSummary: Sendable {
    public let chunkId: UUID
    public let timeWindow: String
    public let summary: String

    public init(chunkId: UUID, timeWindow: String, summary: String) {
        self.chunkId = chunkId
        self.timeWindow = timeWindow
        self.summary = summary
    }
}

/// Implements map-reduce summarization for long transcripts
@available(macOS 14.0, *)
public actor MapReduceSummarizer {

    private let llmEngine: LLMEngine
    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "MapReduceSummarizer")

    public init(llmEngine: LLMEngine) {
        self.llmEngine = llmEngine
    }

    // MARK: - Map Phase

    /// Summarize a single chunk
    public func summarizeChunk(
        _ chunk: TranscriptChunk,
        intent: QueryIntent
    ) async throws -> ChunkSummary {
        let prompt = buildChunkPrompt(for: intent, timeWindow: chunk.timeWindow)

        var fullResponse = ""
        let stream = await llmEngine.generateStream(
            prompt: prompt,
            context: chunk.text,
            systemPrompt: nil,
            conversationHistory: []
        )

        for try await token in stream {
            fullResponse += token
        }

        return ChunkSummary(
            chunkId: chunk.id,
            timeWindow: chunk.timeWindow,
            summary: fullResponse
        )
    }

    /// Process all chunks and return summaries
    public func mapChunks(
        _ chunks: [TranscriptChunk],
        intent: QueryIntent
    ) async throws -> [ChunkSummary] {
        var summaries: [ChunkSummary] = []

        for chunk in chunks {
            let summary = try await summarizeChunk(chunk, intent: intent)
            summaries.append(summary)
            logger.debug("Summarized chunk \(chunk.timeWindow)")
        }

        return summaries
    }

    // MARK: - Reduce Phase

    /// Combine chunk summaries into final response
    public func reduce(
        summaries: [ChunkSummary],
        originalQuery: String,
        intent: QueryIntent
    ) async throws -> String {
        // If only one chunk, return its summary directly
        if summaries.count == 1 {
            return summaries[0].summary
        }

        // Combine summaries for final synthesis
        let combinedContext = summaries.enumerated().map { index, summary in
            """
            === Section \(index + 1) (\(summary.timeWindow)) ===
            \(summary.summary)
            """
        }.joined(separator: "\n\n")

        let reducePrompt = buildReducePrompt(for: intent, originalQuery: originalQuery)

        var fullResponse = ""
        let stream = await llmEngine.generateStream(
            prompt: reducePrompt,
            context: combinedContext,
            systemPrompt: nil,
            conversationHistory: []
        )

        for try await token in stream {
            fullResponse += token
        }

        return fullResponse
    }

    // MARK: - Generic Map-Reduce (No Intent Classification)

    /// Map chunks with a generic query-based approach
    /// Let the LLM decide what to extract based on the user's query
    public func mapChunksGeneric(
        _ chunks: [TranscriptChunk],
        query: String
    ) async throws -> [ChunkSummary] {
        var summaries: [ChunkSummary] = []

        for chunk in chunks {
            let prompt = """
                You are analyzing a portion of a meeting transcript (\(chunk.timeWindow)).

                The user asked: "\(query)"

                Extract the relevant information from this section that would help answer their request.
                Be thorough but concise. Include speaker names and key details.
                """

            var fullResponse = ""
            let stream = await llmEngine.generateStream(
                prompt: prompt,
                context: chunk.text,
                systemPrompt: nil,
                conversationHistory: []
            )

            for try await token in stream {
                fullResponse += token
            }

            let summary = ChunkSummary(
                chunkId: chunk.id,
                timeWindow: chunk.timeWindow,
                summary: fullResponse
            )
            summaries.append(summary)
            logger.debug("Processed chunk \(chunk.timeWindow)")
        }

        return summaries
    }

    /// Reduce with a generic query-based approach
    public func reduceGeneric(
        summaries: [ChunkSummary],
        originalQuery: String
    ) async throws -> String {
        // If only one chunk, return its content directly
        if summaries.count == 1 {
            return summaries[0].summary
        }

        // Combine summaries for final synthesis
        let combinedContext = summaries.enumerated().map { index, summary in
            """
            === Section \(index + 1) (\(summary.timeWindow)) ===
            \(summary.summary)
            """
        }.joined(separator: "\n\n")

        let reducePrompt = """
            You analyzed a long meeting transcript in sections. Here are the results from each section.

            The user's original request was: "\(originalQuery)"

            Now combine these section analyses into a single, coherent response that fully addresses the user's request.
            - Don't just list sections - synthesize the information
            - Remove redundancy
            - Be comprehensive but well-organized
            - Use clear markdown formatting

            Respond directly without <think> tags or internal reasoning.
            """

        var fullResponse = ""
        let stream = await llmEngine.generateStream(
            prompt: reducePrompt,
            context: combinedContext,
            systemPrompt: nil,
            conversationHistory: []
        )

        for try await token in stream {
            fullResponse += token
        }

        return fullResponse
    }

    // MARK: - Prompt Building (Legacy - kept for backward compatibility)

    private func buildChunkPrompt(for intent: QueryIntent, timeWindow: String) -> String {
        switch intent {
        case .summary:
            return """
                Summarize this portion of the meeting (\(timeWindow)).
                Focus on: decisions made, key discussion points, and important information.
                Be concise but capture all important details.
                """
        case .actionItems:
            return """
                Extract all action items from this portion of the meeting (\(timeWindow)).
                For each action item, include:
                - What needs to be done
                - Who is responsible (if mentioned)
                - Deadline (if mentioned)
                Format as a bulleted list.
                """
        case .topicExtraction:
            return """
                List the main topics discussed in this portion (\(timeWindow)).
                Format as bullet points with brief descriptions.
                """
        case .specificQuestion:
            return "Summarize this portion of the meeting (\(timeWindow))."
        }
    }

    private func buildReducePrompt(for intent: QueryIntent, originalQuery: String) -> String {
        switch intent {
        case .summary:
            return """
                Combine these section summaries into one cohesive meeting summary.
                Original request: \(originalQuery)

                Create a well-structured summary that:
                - Flows naturally (don't just list sections)
                - Highlights the most important points
                - Includes key decisions and outcomes
                - Is comprehensive but not repetitive
                """
        case .actionItems:
            return """
                Consolidate these action items from different parts of the meeting.
                Original request: \(originalQuery)

                - Remove any duplicates
                - Group by owner if possible
                - Sort by priority or deadline if apparent
                Format as a clean numbered list.
                """
        case .topicExtraction:
            return """
                Combine and organize these topic lists.
                Original request: \(originalQuery)

                - Merge related topics
                - Remove duplicates
                - Order by importance or time discussed
                """
        case .specificQuestion:
            return "Combine these summaries to answer: \(originalQuery)"
        }
    }
}

