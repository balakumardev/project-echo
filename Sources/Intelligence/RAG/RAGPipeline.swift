import Foundation
import VecturaKit
import VecturaNLKit
import NaturalLanguage
import Accelerate
import os.log
import Database

/// Orchestrates the full RAG (Retrieval-Augmented Generation) flow for Engram.
/// Manages indexing of transcripts into the vector database and handles query processing
/// to generate context-aware responses about meeting content.
@available(macOS 14.0, *)
public actor RAGPipeline {

    // MARK: - Types

    /// Result from a semantic search operation
    public struct SearchResult: Sendable {
        /// The transcript segment that matched the query
        public let segment: DatabaseManager.TranscriptSegment
        /// The recording this segment belongs to
        public let recording: DatabaseManager.Recording
        /// Similarity score (higher is more relevant, 0.0 to 1.0)
        public let score: Float

        public init(segment: DatabaseManager.TranscriptSegment, recording: DatabaseManager.Recording, score: Float) {
            self.segment = segment
            self.recording = recording
            self.score = score
        }
    }

    /// Status of the indexing operation
    public struct IndexingProgress: Sendable {
        public let totalSegments: Int
        public let processedSegments: Int
        public let currentPhase: IndexingPhase

        public enum IndexingPhase: String, Sendable {
            case preparing = "Preparing"
            case embedding = "Generating embeddings"
            case storing = "Storing in vector database"
            case complete = "Complete"
        }

        public var progress: Double {
            guard totalSegments > 0 else { return 0.0 }
            return Double(processedSegments) / Double(totalSegments)
        }
    }

    /// Errors that can occur during RAG operations
    public enum RAGError: Error, LocalizedError {
        case notInitialized
        case embeddingFailed(String)
        case vectorDBError(String)
        case llmError(String)
        case indexingFailed(String)
        case searchFailed(String)
        case noContextFound

        public var errorDescription: String? {
            switch self {
            case .notInitialized:
                return "RAG pipeline is not initialized. Call initialize() first."
            case .embeddingFailed(let reason):
                return "Embedding generation failed: \(reason)"
            case .vectorDBError(let reason):
                return "Vector database error: \(reason)"
            case .llmError(let reason):
                return "LLM error: \(reason)"
            case .indexingFailed(let reason):
                return "Indexing failed: \(reason)"
            case .searchFailed(let reason):
                return "Search failed: \(reason)"
            case .noContextFound:
                return "No relevant context found for the query."
            }
        }
    }

    // MARK: - Constants

    /// Default number of results to return from search
    public static let defaultSearchLimit = 5

    // Note: Uses fileRagLog() from FileLoggerUtility.swift for logging

    /// Maximum number of segments to include in context
    private static let maxContextSegments = 10

    /// Minimum similarity score to include in results
    /// Lower = more inclusive, higher = stricter matching
    /// 0.1 is permissive to catch relevant content; LLM filters out noise
    private static let minimumSimilarityScore: Float = 0.1

    /// Batch size for indexing operations
    private static let indexingBatchSize = 32

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "RAGPipeline")

    /// Database manager for persistence
    private let databaseManager: DatabaseManager

    /// Embedding engine for standalone embedding operations
    private let embeddingEngine: EmbeddingEngine

    /// LLM engine for response generation
    private let llmEngine: LLMEngine

    /// Vector database for similarity search
    private var vectorDB: VecturaKit?

    /// Mapping from VecturaKit document UUIDs to segment info
    private var documentToSegment: [UUID: (recordingId: Int64, segmentId: Int64)] = [:]

    /// Reverse mapping from segment to VecturaKit document UUID
    private var segmentToDocument: [Int64: UUID] = [:]

    /// Tracks which recordings have been indexed
    private var indexedRecordings: Set<Int64> = []

    /// In-memory cache of recording-level embeddings for cross-recording search
    private var recordingEmbeddings: [Int64: [Float]] = [:]

    /// Whether the pipeline has been initialized
    private var isInitialized = false

    /// Whether initialization is in progress (prevents concurrent init)
    private var isInitializing = false

    /// System prompt for RAG-based chat
    private let systemPrompt = """
        You are an AI assistant helping analyze meeting transcripts from Engram.
        Answer questions based on the meeting context provided below.
        When referencing information, cite the speaker and timestamp.
        If the context doesn't contain relevant information, say so honestly.
        Be concise and focus on extracting actionable insights, key decisions, and important details.
        """

    /// System prompt for cross-recording search (multiple meetings)
    private let multiRecordingSystemPrompt = """
        You are an intelligent meeting assistant with access to transcripts from multiple recorded meetings.
        When answering, cite which recording your information comes from using the recording title.
        If information comes from multiple meetings, synthesize across them and note the source.
        Be concise and accurate. If the context doesn't contain enough information, say so.
        """

    // MARK: - Initialization

    /// Creates a new RAGPipeline with the required dependencies
    /// - Parameters:
    ///   - databaseManager: Database manager for storing recordings and transcripts
    ///   - embeddingEngine: Engine for generating vector embeddings (used for query embedding)
    ///   - llmEngine: Engine for LLM inference
    public init(
        databaseManager: DatabaseManager,
        embeddingEngine: EmbeddingEngine,
        llmEngine: LLMEngine
    ) {
        self.databaseManager = databaseManager
        self.embeddingEngine = embeddingEngine
        self.llmEngine = llmEngine
    }

    // MARK: - Initialization & Setup

    /// Initialize the RAG pipeline, setting up the vector database
    /// Call this before using any other methods
    public func initialize() async throws {
        // Already initialized
        guard !isInitialized else {
            logger.debug("RAG pipeline already initialized")
            return
        }

        // Already initializing - wait for it to complete
        if isInitializing {
            logger.debug("RAG pipeline initialization already in progress, waiting...")
            // Wait for initialization to complete (up to 30 seconds)
            for _ in 0..<60 {
                try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                if isInitialized {
                    logger.debug("RAG pipeline initialization completed while waiting")
                    return
                }
                if !isInitializing {
                    break  // Failed or completed
                }
            }
            return
        }

        isInitializing = true
        defer { isInitializing = false }

        logger.info("Initializing RAG pipeline...")
        let startTime = Date()

        do {
            // Note: EmbeddingEngine is loaded by AIService before RAGPipeline initialization

            // Create NLContextualEmbedder for VecturaKit (conforms to VecturaEmbedder)
            let nlEmbedder = try await NLContextualEmbedder(language: .english)

            // Initialize vector database configuration
            let vectorDBPath = getVectorDBPath()
            let config = try VecturaConfig(
                name: "transcripts",
                directoryURL: vectorDBPath,
                dimension: nil,  // Auto-detect from embedder
                searchOptions: .init(
                    defaultNumResults: Self.defaultSearchLimit,
                    minThreshold: Self.minimumSimilarityScore
                )
            )

            vectorDB = try await VecturaKit(config: config, embedder: nlEmbedder)

            // Load indexed recordings from the database
            await loadIndexedRecordingsFromDB()

            // Load recording-level embeddings into memory for cross-recording search
            await loadRecordingEmbeddings()

            isInitialized = true

            let initTime = Date().timeIntervalSince(startTime)
            logger.info("RAG pipeline initialized in \(String(format: "%.2f", initTime))s")

        } catch {
            logger.error("Failed to initialize RAG pipeline: \(error.localizedDescription)")
            throw RAGError.vectorDBError("Initialization failed: \(error.localizedDescription)")
        }
    }

    /// Shuts down the pipeline and releases resources
    public func shutdown() async {
        vectorDB = nil
        documentToSegment.removeAll()
        segmentToDocument.removeAll()
        indexedRecordings.removeAll()
        recordingEmbeddings.removeAll()
        isInitialized = false
        logger.info("RAG pipeline shut down")
    }

    // MARK: - Indexing Operations

    /// Index a recording's transcript for semantic search
    /// - Parameters:
    ///   - recording: The recording to index
    ///   - transcript: The transcript associated with the recording
    ///   - segments: The transcript segments to index
    /// - Throws: RAGError if indexing fails
    public func indexRecording(
        _ recording: DatabaseManager.Recording,
        transcript: DatabaseManager.Transcript,
        segments: [DatabaseManager.TranscriptSegment]
    ) async throws {
        guard isInitialized, let vectorDB = vectorDB else {
            throw RAGError.notInitialized
        }

        guard !segments.isEmpty else {
            logger.warning("No segments to index for recording \(recording.id)")
            return
        }

        // Skip if already indexed
        if indexedRecordings.contains(recording.id) {
            logger.debug("Recording \(recording.id) already indexed, skipping")
            return
        }

        logger.info("Indexing recording \(recording.id): \(segments.count) segments")
        let startTime = Date()

        do {
            // Process segments in batches to manage memory
            for batchStart in stride(from: 0, to: segments.count, by: Self.indexingBatchSize) {
                let batchEnd = min(batchStart + Self.indexingBatchSize, segments.count)
                let batch = Array(segments[batchStart..<batchEnd])

                // Prepare texts for embedding (include speaker context)
                let texts = batch.map { segment in
                    "[\(segment.speaker)] \(segment.text)"
                }

                // Generate deterministic UUIDs for consistency across app restarts
                let documentIds = batch.map { segment in
                    generateDocumentId(segmentId: segment.id, recordingId: recording.id, transcriptId: transcript.id)
                }

                // Add documents to VecturaKit (it handles embedding internally)
                _ = try await vectorDB.addDocuments(texts: texts, ids: documentIds)

                // Update mappings
                for (index, segment) in batch.enumerated() {
                    let docId = documentIds[index]
                    documentToSegment[docId] = (recordingId: recording.id, segmentId: segment.id)
                    segmentToDocument[segment.id] = docId

                    // Also persist embedding to database for durability
                    // Generate embedding using our EmbeddingEngine for database storage
                    let embedding = try await embeddingEngine.embed(texts[index])
                    _ = try await databaseManager.saveEmbedding(
                        segmentId: segment.id,
                        vector: embedding,
                        model: "NLContextualEmbedder"
                    )

                    // Populate FTS5 segment_search table for keyword search
                    try await databaseManager.insertSegmentSearchEntry(
                        segmentId: segment.id,
                        recordingId: recording.id,
                        text: segment.text
                    )
                }
            }

            // Mark as indexed
            indexedRecordings.insert(recording.id)

            let indexTime = Date().timeIntervalSince(startTime)
            logger.info("Indexed recording \(recording.id) in \(String(format: "%.2f", indexTime))s (\(segments.count) segments)")

        } catch {
            logger.error("Indexing failed for recording \(recording.id): \(error.localizedDescription)")
            throw RAGError.indexingFailed(error.localizedDescription)
        }
    }

    /// Remove a recording from the index
    /// - Parameter recordingId: ID of the recording to remove
    public func removeRecording(_ recordingId: Int64) async throws {
        guard isInitialized, let vectorDB = vectorDB else {
            throw RAGError.notInitialized
        }

        logger.info("Removing recording \(recordingId) from index")

        do {
            // Get all segment IDs for this recording's transcript
            if let transcript = try await databaseManager.getTranscript(forRecording: recordingId) {
                let segments = try await databaseManager.getSegments(forTranscriptId: transcript.id)

                // Collect document UUIDs to remove
                var documentIdsToRemove: [UUID] = []
                for segment in segments {
                    if let docId = segmentToDocument[segment.id] {
                        documentIdsToRemove.append(docId)
                        documentToSegment.removeValue(forKey: docId)
                        segmentToDocument.removeValue(forKey: segment.id)
                    }
                }

                // Remove from vector DB
                if !documentIdsToRemove.isEmpty {
                    try await vectorDB.deleteDocuments(ids: documentIdsToRemove)
                }

                // Delete embeddings from database
                try await databaseManager.deleteEmbeddings(forTranscriptId: transcript.id)
            }

            // Remove from indexed set
            indexedRecordings.remove(recordingId)

            // Remove recording-level embedding
            try await databaseManager.deleteRecordingEmbedding(recordingId: recordingId)
            recordingEmbeddings.removeValue(forKey: recordingId)

            // Remove FTS5 segment search entries
            try await databaseManager.deleteSegmentSearchEntries(recordingId: recordingId)

            logger.info("Removed recording \(recordingId) from index")

        } catch {
            logger.error("Failed to remove recording \(recordingId): \(error.localizedDescription)")
            throw RAGError.vectorDBError("Failed to remove recording: \(error.localizedDescription)")
        }
    }

    /// Rebuild the entire index from all transcribed recordings
    /// This is useful after database restoration or corruption
    public func rebuildIndex() async throws {
        guard isInitialized, let vectorDB = vectorDB else {
            throw RAGError.notInitialized
        }

        logger.info("Rebuilding RAG index...")
        let startTime = Date()

        do {
            // Clear existing index data
            indexedRecordings.removeAll()
            documentToSegment.removeAll()
            segmentToDocument.removeAll()

            // Clear vector DB
            try await vectorDB.reset()

            // Get all recordings with transcripts
            let recordings = try await databaseManager.getAllRecordings()
            let transcribedRecordings = recordings.filter { $0.hasTranscript }

            logger.info("Rebuilding index for \(transcribedRecordings.count) recordings")

            // Index each recording
            for recording in transcribedRecordings {
                if let transcript = try await databaseManager.getTranscript(forRecording: recording.id) {
                    let segments = try await databaseManager.getSegments(forTranscriptId: transcript.id)
                    try await indexRecording(recording, transcript: transcript, segments: segments)
                }
            }

            let rebuildTime = Date().timeIntervalSince(startTime)
            logger.info("Index rebuild complete in \(String(format: "%.2f", rebuildTime))s")

        } catch {
            logger.error("Index rebuild failed: \(error.localizedDescription)")
            throw RAGError.indexingFailed("Rebuild failed: \(error.localizedDescription)")
        }
    }

    /// Check if a recording has been indexed
    /// - Parameter recordingId: ID of the recording to check
    /// - Returns: True if the recording is indexed
    public func isRecordingIndexed(_ recordingId: Int64) async -> Bool {
        return indexedRecordings.contains(recordingId)
    }

    // MARK: - Search Operations

    /// Search for segments relevant to a query
    /// - Parameters:
    ///   - query: The search query
    ///   - limit: Maximum number of results to return
    ///   - recordingFilter: Optional recording ID to limit search scope
    /// - Returns: Array of search results sorted by relevance
    public func search(
        query: String,
        limit: Int = defaultSearchLimit,
        recordingFilter: Int64? = nil
    ) async throws -> [SearchResult] {
        fileRagLog("[Search] isInitialized: \(isInitialized), vectorDB: \(vectorDB != nil)")
        fileRagLog("[Search] documentToSegment count: \(documentToSegment.count)")
        fileRagLog("[Search] indexedRecordings: \(indexedRecordings.count)")

        guard isInitialized, let vectorDB = vectorDB else {
            fileRagLog("[Search] ERROR: Not initialized!")
            throw RAGError.notInitialized
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        fileRagLog("[Search] Query: '\(trimmedQuery)', limit: \(limit), filter: \(String(describing: recordingFilter))")
        logger.debug("Searching for: '\(trimmedQuery)' (limit: \(limit), filter: \(String(describing: recordingFilter)))")

        do {
            // Search using text query (VecturaKit handles embedding internally)
            // When filtering by recording, fetch many more results since VecturaKit returns
            // globally ranked results and we filter post-hoc (most will be from other recordings)
            let topK = recordingFilter != nil ? max(limit * 10, 100) : limit * 2
            fileRagLog("[Search] Calling vectorDB.search with topK=\(topK), threshold=\(Self.minimumSimilarityScore)")
            let vectorResults = try await vectorDB.search(
                query: .text(trimmedQuery),
                numResults: topK,
                threshold: Self.minimumSimilarityScore
            )
            fileRagLog("[Search] VectorDB returned \(vectorResults.count) results")
            for (i, r) in vectorResults.prefix(3).enumerated() {
                fileRagLog("[Search]   Result \(i): id=\(r.id), score=\(r.score)")
            }

            // Process results
            var searchResults: [SearchResult] = []
            var filteredOutCount = 0

            for vectorResult in vectorResults {
                // Get segment info from our mapping
                guard let segmentInfo = documentToSegment[vectorResult.id] else {
                    logger.warning("Unknown document ID: \(vectorResult.id)")
                    continue
                }

                // Apply recording filter if specified
                if let filterRecordingId = recordingFilter, segmentInfo.recordingId != filterRecordingId {
                    filteredOutCount += 1
                    continue
                }

                // Fetch segment and recording from database
                do {
                    let recording = try await databaseManager.getRecording(id: segmentInfo.recordingId)

                    if let transcript = try await databaseManager.getTranscript(forRecording: segmentInfo.recordingId) {
                        let segments = try await databaseManager.getSegments(forTranscriptId: transcript.id)

                        if let segment = segments.first(where: { $0.id == segmentInfo.segmentId }) {
                            let result = SearchResult(
                                segment: segment,
                                recording: recording,
                                score: vectorResult.score
                            )
                            searchResults.append(result)
                        }
                    }
                } catch {
                    logger.warning("Failed to fetch data for segment \(segmentInfo.segmentId): \(error.localizedDescription)")
                    continue
                }

                // Stop if we have enough results
                if searchResults.count >= limit {
                    break
                }
            }

            if filteredOutCount > 0 {
                fileRagLog("[Search] Filtered out \(filteredOutCount) results (wrong recording)")
            }
            fileRagLog("[Search] Final results: \(searchResults.count)")
            logger.debug("Search returned \(searchResults.count) results")
            return searchResults

        } catch {
            logger.error("Search failed: \(error.localizedDescription)")
            throw RAGError.searchFailed(error.localizedDescription)
        }
    }

    // MARK: - Chat (RAG) Operations

    /// Generate a streaming response to a query using RAG
    /// - Parameters:
    ///   - query: The user's question
    ///   - sessionId: Chat session identifier for history
    ///   - recordingFilter: Optional recording ID to limit context scope
    /// - Returns: AsyncThrowingStream of response tokens
    public func chat(
        query: String,
        sessionId: String,
        recordingFilter: Int64? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard self.isInitialized else {
                        throw RAGError.notInitialized
                    }

                    guard await self.llmEngine.isModelLoaded else {
                        throw RAGError.llmError("LLM model not loaded")
                    }

                    // Debug: Log indexing status
                    self.logger.info("[RAG Chat] Query: '\(query)', Filter: \(String(describing: recordingFilter)), Indexed recordings: \(self.indexedRecordings.count)")
                    fileRagLog("[Chat] Query: '\(query)', Filter: \(String(describing: recordingFilter)), Indexed: \(self.indexedRecordings.count)")

                    // Save user message to history
                    _ = try await self.databaseManager.saveChatMessage(
                        sessionId: sessionId,
                        recordingId: recordingFilter,
                        role: "user",
                        content: query,
                        citations: nil
                    )

                    // Search for relevant context
                    let searchResults = try await self.search(
                        query: query,
                        limit: Self.maxContextSegments,
                        recordingFilter: recordingFilter
                    )

                    // Debug: Log search results
                    self.logger.info("[RAG Chat] Search returned \(searchResults.count) results")
                    fileRagLog("[Chat] Search returned \(searchResults.count) results")
                    for (i, result) in searchResults.prefix(3).enumerated() {
                        fileRagLog("[Chat] Result \(i+1): \(result.recording.title) - \(result.segment.text.prefix(50))... (score: \(result.score))")
                    }

                    // Build context from search results
                    let context = self.buildContext(from: searchResults)
                    fileRagLog("[Chat] Context length: \(context.count) chars")
                    let citedSegmentIds = searchResults.map { $0.segment.id }

                    // Get conversation history
                    let history = try await self.databaseManager.getChatHistory(sessionId: sessionId)
                    let conversationMessages = self.convertToLLMMessages(history)

                    // Generate response
                    var fullResponse = ""

                    let stream = await self.llmEngine.generateStream(
                        prompt: query,
                        context: context,
                        systemPrompt: self.systemPrompt,
                        conversationHistory: conversationMessages
                    )

                    for try await token in stream {
                        fullResponse += token
                        continuation.yield(token)
                    }

                    // Save assistant response to history
                    _ = try await self.databaseManager.saveChatMessage(
                        sessionId: sessionId,
                        recordingId: recordingFilter,
                        role: "assistant",
                        content: fullResponse,
                        citations: citedSegmentIds
                    )

                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Generate a complete (non-streaming) response to a query
    /// - Parameters:
    ///   - query: The user's question
    ///   - sessionId: Chat session identifier
    ///   - recordingFilter: Optional recording ID to limit context scope
    /// - Returns: The complete response string
    public func chatComplete(
        query: String,
        sessionId: String,
        recordingFilter: Int64? = nil
    ) async throws -> String {
        var result = ""

        for try await token in chat(query: query, sessionId: sessionId, recordingFilter: recordingFilter) {
            result += token
        }

        return result
    }

    /// Agentic chat that intelligently routes queries based on intent
    /// - Parameters:
    ///   - query: The user's question
    ///   - sessionId: Chat session identifier
    ///   - recordingFilter: Optional recording ID to limit context scope
    /// - Returns: AsyncThrowingStream of response tokens
    public func agentChat(
        query: String,
        sessionId: String,
        recordingFilter: Int64? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    fileRagLog("[AgentChat] Query: '\(query)', Filter: \(String(describing: recordingFilter))")

                    // Save user message first
                    _ = try await self.databaseManager.saveChatMessage(
                        sessionId: sessionId,
                        recordingId: recordingFilter,
                        role: "user",
                        content: query,
                        citations: nil
                    )

                    // Get conversation history (last 10 messages)
                    let allHistory = try await self.databaseManager.getChatHistory(sessionId: sessionId)
                    let recentHistory = allHistory.suffix(10)
                    let conversationHistory = recentHistory.dropLast().compactMap { msg -> LLMEngine.Message? in
                        guard let role = LLMEngine.Message.Role(rawValue: msg.role) else { return nil }
                        return LLMEngine.Message(role: role, content: msg.content)
                    }

                    fileRagLog("[AgentChat] Creating TranscriptAgent...")

                    // Create agent and process query
                    let agent = TranscriptAgent(
                        databaseManager: self.databaseManager,
                        llmEngine: self.llmEngine
                    )

                    var fullResponse = ""
                    fileRagLog("[AgentChat] Calling agent.processQuery...")

                    let stream = await agent.processQuery(
                        query: query,
                        recordingId: recordingFilter,
                        ragPipeline: self,
                        sessionId: sessionId,
                        conversationHistory: Array(conversationHistory)
                    )

                    fileRagLog("[AgentChat] Starting to stream response...")

                    for try await token in stream {
                        fullResponse += token
                        continuation.yield(token)
                    }

                    fileRagLog("[AgentChat] Response complete, length: \(fullResponse.count) chars")

                    // Save assistant response
                    if !fullResponse.isEmpty {
                        _ = try await self.databaseManager.saveChatMessage(
                            sessionId: sessionId,
                            recordingId: recordingFilter,
                            role: "assistant",
                            content: fullResponse,
                            citations: nil
                        )
                    }

                    continuation.finish()

                } catch {
                    self.logger.error("Agent chat error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Recording-Level Indexing

    /// Index a recording's summary/metadata for cross-recording search
    /// Call this after summary or action items are generated
    public func indexRecordingSummary(recordingId: Int64) async throws {
        // Note: No isInitialized guard — this only needs the embedding engine,
        // which is loaded before RAGPipeline.initialize() completes.
        // This allows backfilling during init before isInitialized is set.

        let recording = try await databaseManager.getRecording(id: recordingId)

        // Build embedding text from available metadata
        var parts: [String] = [recording.title]

        if let summary = recording.summary, !summary.isEmpty, !summary.hasPrefix("[No summary") {
            parts.append(summary)
        } else {
            // Fallback: use first 500 chars of transcript
            if let transcript = try await databaseManager.getTranscript(forRecording: recordingId) {
                let prefix = String(transcript.fullText.prefix(500))
                if !prefix.isEmpty {
                    parts.append(prefix)
                }
            }
        }

        if let actionItems = recording.actionItems, !actionItems.isEmpty, !actionItems.hasPrefix("[No action") {
            parts.append(actionItems)
        }

        let embeddingText = parts.joined(separator: "\n")

        // Generate embedding
        let vector = try await embeddingEngine.embed(embeddingText)

        // Save to database
        try await databaseManager.saveRecordingEmbedding(
            recordingId: recordingId,
            text: embeddingText,
            vector: vector,
            model: "NLContextualEmbedder"
        )

        // Update in-memory cache
        recordingEmbeddings[recordingId] = vector

        fileRagLog("[CrossRecordingSearch] Indexed recording \(recordingId) summary (\(embeddingText.count) chars)")
    }

    /// Load all recording embeddings into memory on startup
    /// Also backfills FTS5 segment_search and recording embeddings for existing data
    private func loadRecordingEmbeddings() async {
        do {
            // Load existing recording embeddings
            let embeddings = try await databaseManager.getAllRecordingEmbeddings()
            for entry in embeddings {
                recordingEmbeddings[entry.recordingId] = entry.vector
            }
            fileRagLog("[Init] Loaded \(embeddings.count) recording-level embeddings into memory")

            let recordings = try await databaseManager.getAllRecordings()
            let transcribedRecordings = recordings.filter { $0.hasTranscript }

            // Backfill recording-level embeddings for recordings with summaries but no embedding
            var newlyIndexedEmbeddings = 0
            for recording in transcribedRecordings {
                if recordingEmbeddings[recording.id] == nil {
                    if recording.summary != nil || recording.actionItems != nil {
                        do {
                            try await indexRecordingSummary(recordingId: recording.id)
                            newlyIndexedEmbeddings += 1
                        } catch {
                            fileRagLog("[Init] Failed to index recording \(recording.id) summary: \(error.localizedDescription)")
                        }
                    }
                }
            }
            if newlyIndexedEmbeddings > 0 {
                fileRagLog("[Init] Indexed \(newlyIndexedEmbeddings) new recording-level embeddings")
            }

            // Backfill FTS5 segment_search if empty
            let ftsCount = try await databaseManager.segmentSearchCount()
            if ftsCount == 0 && !transcribedRecordings.isEmpty {
                fileRagLog("[Init] FTS5 segment_search is empty, backfilling all segments...")
                var totalFTS = 0
                for recording in transcribedRecordings {
                    if let transcript = try await databaseManager.getTranscript(forRecording: recording.id) {
                        let segments = try await databaseManager.getSegments(forTranscriptId: transcript.id)
                        for segment in segments {
                            try await databaseManager.insertSegmentSearchEntry(
                                segmentId: segment.id,
                                recordingId: recording.id,
                                text: segment.text
                            )
                            totalFTS += 1
                        }
                    }
                }
                fileRagLog("[Init] Backfilled \(totalFTS) segments into FTS5 segment_search")
            } else {
                fileRagLog("[Init] FTS5 segment_search has \(ftsCount) entries")
            }
        } catch {
            fileRagLog("[Init] Failed to load recording embeddings: \(error.localizedDescription)")
        }
    }

    // MARK: - Cross-Recording Search

    /// Two-stage cross-recording search: find relevant recordings, then extract rich context
    /// - Parameters:
    ///   - query: The user's question
    ///   - sessionId: Chat session identifier
    ///   - conversationHistory: Previous conversation messages
    /// - Returns: AsyncThrowingStream of response tokens and cited segment IDs
    public func crossRecordingSearch(
        query: String,
        sessionId: String,
        conversationHistory: [LLMEngine.Message]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard self.isInitialized else {
                        throw RAGError.notInitialized
                    }

                    guard await self.llmEngine.isModelLoaded else {
                        throw RAGError.llmError("LLM model not loaded")
                    }

                    fileRagLog("[CrossRecordingSearch] Query: '\(query)', Recording embeddings: \(self.recordingEmbeddings.count)")

                    // === Stage 1: Recording Discovery ===
                    let rankedRecordings = try await self.discoverRelevantRecordings(query: query)

                    if rankedRecordings.isEmpty {
                        fileRagLog("[CrossRecordingSearch] No relevant recordings found")
                        // Fall back to basic RAG search
                        let fallbackStream = self.chat(
                            query: query,
                            sessionId: sessionId,
                            recordingFilter: nil
                        )
                        for try await token in fallbackStream {
                            continuation.yield(token)
                        }
                        continuation.finish()
                        return
                    }

                    // === Stage 2: Context Extraction ===
                    // MLX has ~2K token context; cloud providers can handle ~40K
                    let isMLX = await self.llmEngine.isMLXBackend
                    let tokenBudget: Int
                    let searchRecordings: [RankedRecording]
                    if isMLX {
                        tokenBudget = 1500  // Leave room for system prompt + generation
                        searchRecordings = Array(rankedRecordings.prefix(2))
                        fileRagLog("[CrossRecordingSearch] MLX backend — compact context, \(searchRecordings.count) recordings, \(tokenBudget) token budget")
                    } else {
                        tokenBudget = 40000
                        searchRecordings = rankedRecordings
                    }
                    let context = try await self.buildMultiRecordingContext(
                        rankedRecordings: searchRecordings,
                        query: query,
                        tokenBudget: tokenBudget
                    )

                    fileRagLog("[CrossRecordingSearch] Built context: \(context.count) chars from \(searchRecordings.count) recordings")

                    // Collect segment IDs for citations
                    var citedSegmentIds: [Int64] = []
                    for rec in searchRecordings {
                        citedSegmentIds.append(contentsOf: rec.segmentIds)
                    }

                    // === Generate response ===
                    // Note: message persistence is handled by agentChat() caller

                    let stream = await self.llmEngine.generateStream(
                        prompt: query,
                        context: context,
                        systemPrompt: self.multiRecordingSystemPrompt,
                        conversationHistory: conversationHistory
                    )

                    for try await token in stream {
                        continuation.yield(token)
                    }

                    continuation.finish()

                } catch {
                    self.logger.error("Cross-recording search error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Stage 1: Discover relevant recordings using hybrid semantic + keyword search
    private struct RankedRecording {
        let recordingId: Int64
        let score: Float
        var segmentIds: [Int64] = []
    }

    private func discoverRelevantRecordings(query: String, limit: Int = 5) async throws -> [RankedRecording] {
        // Stage 1a: Semantic search against recording embeddings
        var semanticScores: [(recordingId: Int64, score: Float)] = []

        if !recordingEmbeddings.isEmpty {
            let queryVector = try await embeddingEngine.embed(query)

            for (recordingId, vector) in recordingEmbeddings {
                let score = cosineSimilarity(queryVector, vector)
                if score > 0.05 {  // Very permissive threshold
                    semanticScores.append((recordingId: recordingId, score: score))
                }
            }
            semanticScores.sort { $0.score > $1.score }
            semanticScores = Array(semanticScores.prefix(10))
        }

        fileRagLog("[CrossRecordingSearch] Stage 1a - Semantic: \(semanticScores.count) recordings")
        for (i, s) in semanticScores.prefix(3).enumerated() {
            fileRagLog("[CrossRecordingSearch]   \(i+1). Recording \(s.recordingId): score=\(String(format: "%.4f", s.score))")
        }

        // Stage 1b: Keyword search via FTS5
        let keywordResults = try await databaseManager.keywordSearchRecordings(query: query, limit: 10)

        fileRagLog("[CrossRecordingSearch] Stage 1b - Keyword: \(keywordResults.count) recordings")
        for (i, k) in keywordResults.prefix(3).enumerated() {
            fileRagLog("[CrossRecordingSearch]   \(i+1). Recording \(k.recordingId): matches=\(k.matchCount)")
        }

        // Merge: combine semantic (raw cosine, already 0-1) with normalized keyword
        // DON'T normalize semantic — raw cosine similarity is already 0-1,
        // normalizing would make a weak 0.25 look like a perfect 1.0
        let rawSemantic: [Int64: Float] = Dictionary(
            uniqueKeysWithValues: semanticScores.map {
                ($0.recordingId, $0.score)
            }
        )

        // Normalize keyword scores to [0,1] (counts vary widely)
        let maxKeyword = Float(keywordResults.first?.matchCount ?? 1)
        let normalizedKeyword: [Int64: Float] = Dictionary(
            uniqueKeysWithValues: keywordResults.map {
                ($0.recordingId, maxKeyword > 0 ? Float($0.matchCount) / maxKeyword : 0)
            }
        )

        // Combine all recording IDs
        var allRecordingIds = Set(rawSemantic.keys)
        allRecordingIds.formUnion(normalizedKeyword.keys)

        var mergedScores: [RankedRecording] = []
        for recId in allRecordingIds {
            let semScore = rawSemantic[recId] ?? 0
            let kwScore = normalizedKeyword[recId] ?? 0

            var combined = 0.7 * semScore + 0.3 * kwScore

            // Boost recordings found in both lists
            if semScore > 0 && kwScore > 0 {
                combined *= 1.3
            }

            mergedScores.append(RankedRecording(recordingId: recId, score: combined))
        }

        mergedScores.sort { $0.score > $1.score }
        let topRecordings = Array(mergedScores.prefix(limit))

        fileRagLog("[CrossRecordingSearch] Merged: \(topRecordings.count) recordings selected")
        for (i, r) in topRecordings.enumerated() {
            fileRagLog("[CrossRecordingSearch]   \(i+1). Recording \(r.recordingId): combined=\(String(format: "%.4f", r.score))")
        }

        return topRecordings
    }

    /// Stage 2: Build rich multi-recording context from ranked recordings
    private func buildMultiRecordingContext(
        rankedRecordings: [RankedRecording],
        query: String,
        tokenBudget: Int
    ) async throws -> String {
        guard !rankedRecordings.isEmpty else { return "No relevant meeting content found." }

        // Allocate token budget: top recording gets max(40%, proportional share)
        let totalScore = rankedRecordings.reduce(Float(0)) { $0 + $1.score }
        var budgets: [Int] = []

        for (i, rec) in rankedRecordings.enumerated() {
            let proportional = totalScore > 0 ? Double(rec.score) / Double(totalScore) : 1.0 / Double(rankedRecordings.count)
            let share: Double
            if i == 0 {
                share = max(0.4, proportional)
            } else {
                share = proportional
            }
            budgets.append(Int(Double(tokenBudget) * share))
        }

        // Normalize budgets to not exceed total
        let budgetSum = budgets.reduce(0, +)
        if budgetSum > tokenBudget {
            let scale = Double(tokenBudget) / Double(budgetSum)
            budgets = budgets.map { Int(Double($0) * scale) }
        }

        var contextParts: [String] = []
        var updatedRecordings = rankedRecordings

        for (i, rec) in rankedRecordings.enumerated() {
            let recording: DatabaseManager.Recording
            do {
                recording = try await databaseManager.getRecording(id: rec.recordingId)
            } catch {
                continue
            }

            let budgetTokens = budgets[i]
            // Rough approximation: 1 token ≈ 4 chars
            let budgetChars = budgetTokens * 4

            var recordingContext = ""

            // Header
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            let dateStr = dateFormatter.string(from: recording.date)
            let appStr = recording.appName ?? "Unknown"
            recordingContext += "=== Meeting: \"\(recording.title)\" (\(dateStr), \(appStr)) ===\n"

            // Include summary if available
            if let summary = recording.summary, !summary.isEmpty, !summary.hasPrefix("[No summary") {
                let truncatedSummary = String(summary.prefix(budgetChars / 3))
                recordingContext += "Summary: \(truncatedSummary)\n\n"
            }

            // Search for relevant segments within this recording
            let remainingBudget = budgetChars - recordingContext.count
            var segmentIds: [Int64] = []

            if remainingBudget > 100 {
                do {
                    let segmentResults = try await self.search(
                        query: query,
                        limit: 15,
                        recordingFilter: rec.recordingId
                    )

                    if !segmentResults.isEmpty {
                        recordingContext += "Key segments:\n"
                        var segmentChars = 0
                        for result in segmentResults {
                            let timestamp = formatTimestamp(result.segment.startTime)
                            let segmentLine = "[\(result.segment.speaker)] [\(timestamp)] \(result.segment.text)\n"
                            if segmentChars + segmentLine.count > remainingBudget {
                                break
                            }
                            recordingContext += segmentLine
                            segmentChars += segmentLine.count
                            segmentIds.append(result.segment.id)
                        }
                    }
                } catch {
                    fileRagLog("[CrossRecordingSearch] Segment search failed for recording \(rec.recordingId): \(error.localizedDescription)")
                }
            }

            updatedRecordings[i].segmentIds = segmentIds
            contextParts.append(recordingContext)
        }

        return contextParts.joined(separator: "\n\n")
    }

    /// Cosine similarity between two vectors using Accelerate framework (vDSP)
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0.0 }

        return dotProduct / denominator
    }

    // MARK: - Private Helpers

    /// Returns the path for the vector database storage
    private func getVectorDBPath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Engram")
            .appendingPathComponent("VectorDB")
    }

    /// Loads indexed recordings from persisted VecturaKit storage
    /// VecturaKit persists documents with embeddings to disk - we just need to rebuild mappings
    private func loadIndexedRecordingsFromDB() async {
        guard let vectorDB = vectorDB else { return }

        do {
            // Get existing documents from VecturaKit's persistent storage (instant - no re-embedding!)
            let existingDocs = try await vectorDB.getAllDocuments()
            let existingDocIds = Set(existingDocs.map { $0.id })
            fileRagLog("[Init] Found \(existingDocs.count) persisted documents in VecturaKit")

            let recordings = try await databaseManager.getAllRecordings()
            let recordingsWithTranscripts = recordings.filter { $0.hasTranscript }
            fileRagLog("[Init] Recordings with transcripts: \(recordingsWithTranscripts.count)")

            var newDocsToAdd: [(text: String, id: UUID, segmentId: Int64, recordingId: Int64)] = []

            for recording in recordingsWithTranscripts {
                guard let transcript = try await databaseManager.getTranscript(forRecording: recording.id) else {
                    continue
                }

                let segments = try await databaseManager.getSegments(forTranscriptId: transcript.id)
                guard !segments.isEmpty else { continue }

                var recordingHasAllDocs = true

                for segment in segments {
                    let docId = generateDocumentId(segmentId: segment.id, recordingId: recording.id, transcriptId: transcript.id)

                    if existingDocIds.contains(docId) {
                        // Document already persisted - just update mappings (instant!)
                        documentToSegment[docId] = (recordingId: recording.id, segmentId: segment.id)
                        segmentToDocument[segment.id] = docId
                    } else {
                        // New document - need to add it
                        let text = "[\(segment.speaker)] \(segment.text)"
                        newDocsToAdd.append((text: text, id: docId, segmentId: segment.id, recordingId: recording.id))
                        recordingHasAllDocs = false
                    }
                }

                if recordingHasAllDocs {
                    indexedRecordings.insert(recording.id)
                }
            }

            // Add any new documents that weren't persisted yet
            if !newDocsToAdd.isEmpty {
                fileRagLog("[Init] Adding \(newDocsToAdd.count) new documents to index...")
                for doc in newDocsToAdd {
                    do {
                        _ = try await vectorDB.addDocument(text: doc.text, id: doc.id)
                        documentToSegment[doc.id] = (recordingId: doc.recordingId, segmentId: doc.segmentId)
                        segmentToDocument[doc.segmentId] = doc.id

                        // Also save embedding to database
                        let embedding = try await embeddingEngine.embed(doc.text)
                        _ = try await databaseManager.saveEmbedding(
                            segmentId: doc.segmentId,
                            vector: embedding,
                            model: "NLContextualEmbedder"
                        )
                    } catch {
                        fileRagLog("[Init] Failed to add doc \(doc.id): \(error.localizedDescription)")
                    }
                }

                // Mark recordings as indexed after adding new docs
                for recording in recordingsWithTranscripts {
                    indexedRecordings.insert(recording.id)
                }
            }

            fileRagLog("[Init] Complete - \(self.indexedRecordings.count) recordings, \(self.documentToSegment.count) segments mapped")
            logger.info("Loaded \(self.indexedRecordings.count) recordings (\(existingDocs.count) from cache, \(newDocsToAdd.count) new)")

        } catch {
            logger.warning("Failed to load indexed recordings: \(error.localizedDescription)")
            fileRagLog("[Init] Error: \(error.localizedDescription)")
        }
    }

    /// Generates a deterministic document UUID based on segment, recording, and transcript IDs
    private func generateDocumentId(segmentId: Int64, recordingId: Int64, transcriptId: Int64) -> UUID {
        UUID(uuidString: String(format: "%08X-%04X-%04X-%04X-%012X",
                                UInt32(segmentId & 0xFFFFFFFF),
                                UInt16((segmentId >> 32) & 0xFFFF),
                                0x4000 | UInt16((segmentId >> 48) & 0x0FFF),
                                0x8000 | UInt16(recordingId & 0x3FFF),
                                UInt64(transcriptId))) ?? UUID()
    }

    /// Returns the number of indexed recordings
    public var indexedRecordingsCount: Int {
        indexedRecordings.count
    }

    /// Returns the total number of recordings with transcripts that could be indexed
    public func totalIndexableRecordings() async -> Int {
        do {
            let recordings = try await databaseManager.getAllRecordings()
            return recordings.filter { $0.hasTranscript }.count
        } catch {
            return 0
        }
    }

    /// Builds a context string from search results
    private func buildContext(from results: [SearchResult]) -> String {
        guard !results.isEmpty else {
            return "No relevant meeting content found."
        }

        var contextParts: [String] = []

        for result in results {
            let timestamp = formatTimestamp(result.segment.startTime)
            let recordingTitle = result.recording.title
            let speaker = result.segment.speaker
            let text = result.segment.text

            let contextEntry = """
                [Recording: \(recordingTitle)]
                [Speaker: \(speaker)] [Time: \(timestamp)]
                \(text)
                """
            contextParts.append(contextEntry)
        }

        return contextParts.joined(separator: "\n\n")
    }

    /// Formats a time interval as MM:SS or HH:MM:SS
    private func formatTimestamp(_ seconds: TimeInterval) -> String {
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

    /// Converts database chat messages to LLM message format
    private func convertToLLMMessages(_ history: [DatabaseManager.ChatMessage]) -> [LLMEngine.Message] {
        // Take only recent messages to avoid context overflow
        let recentHistory = history.suffix(10)

        return recentHistory.compactMap { message in
            guard let role = LLMEngine.Message.Role(rawValue: message.role) else {
                return nil
            }
            return LLMEngine.Message(role: role, content: message.content)
        }
    }
}
