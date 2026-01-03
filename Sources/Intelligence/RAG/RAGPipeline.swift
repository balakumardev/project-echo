import Foundation
import VecturaKit
import VecturaNLKit
import NaturalLanguage
import os.log
import Database

/// Orchestrates the full RAG (Retrieval-Augmented Generation) flow for Project Echo.
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

    /// Debug log file for RAG operations
    private static let debugLogURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("projectecho_rag.log")
    }()

    /// Write to debug log file
    private func debugLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
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

    /// Maximum number of segments to include in context
    private static let maxContextSegments = 10

    /// Minimum similarity score to include in results
    /// Lower = more inclusive, higher = stricter matching
    /// 0.1 is permissive to catch relevant content; LLM filters out noise
    private static let minimumSimilarityScore: Float = 0.1

    /// Batch size for indexing operations
    private static let indexingBatchSize = 32

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.projectecho.app", category: "RAGPipeline")

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

    /// Whether the pipeline has been initialized
    private var isInitialized = false

    /// Whether initialization is in progress (prevents concurrent init)
    private var isInitializing = false

    /// System prompt for RAG-based chat
    private let systemPrompt = """
        You are an AI assistant helping analyze meeting transcripts from Project Echo.
        Answer questions based on the meeting context provided below.
        When referencing information, cite the speaker and timestamp.
        If the context doesn't contain relevant information, say so honestly.
        Be concise and focus on extracting actionable insights, key decisions, and important details.
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
        debugLog("[Search] isInitialized: \(isInitialized), vectorDB: \(vectorDB != nil)")
        debugLog("[Search] documentToSegment count: \(documentToSegment.count)")
        debugLog("[Search] indexedRecordings: \(indexedRecordings.count)")

        guard isInitialized, let vectorDB = vectorDB else {
            debugLog("[Search] ERROR: Not initialized!")
            throw RAGError.notInitialized
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        debugLog("[Search] Query: '\(trimmedQuery)', limit: \(limit), filter: \(String(describing: recordingFilter))")
        logger.debug("Searching for: '\(trimmedQuery)' (limit: \(limit), filter: \(String(describing: recordingFilter)))")

        do {
            // Search using text query (VecturaKit handles embedding internally)
            let topK = recordingFilter == nil ? limit * 2 : limit  // Get more results if filtering
            debugLog("[Search] Calling vectorDB.search with topK=\(topK), threshold=\(Self.minimumSimilarityScore)")
            let vectorResults = try await vectorDB.search(
                query: .text(trimmedQuery),
                numResults: topK,
                threshold: Self.minimumSimilarityScore
            )
            debugLog("[Search] VectorDB returned \(vectorResults.count) results")
            for (i, r) in vectorResults.prefix(3).enumerated() {
                debugLog("[Search]   Result \(i): id=\(r.id), score=\(r.score)")
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
                debugLog("[Search] Filtered out \(filteredOutCount) results (wrong recording)")
            }
            debugLog("[Search] Final results: \(searchResults.count)")
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
                    self.debugLog("[Chat] Query: '\(query)', Filter: \(String(describing: recordingFilter)), Indexed: \(self.indexedRecordings.count)")

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
                    self.debugLog("[Chat] Search returned \(searchResults.count) results")
                    for (i, result) in searchResults.prefix(3).enumerated() {
                        self.debugLog("[Chat] Result \(i+1): \(result.recording.title) - \(result.segment.text.prefix(50))... (score: \(result.score))")
                    }

                    // Build context from search results
                    let context = self.buildContext(from: searchResults)
                    self.debugLog("[Chat] Context length: \(context.count) chars")
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

    // MARK: - Private Helpers

    /// Returns the path for the vector database storage
    private func getVectorDBPath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("ProjectEcho")
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
            debugLog("[Init] Found \(existingDocs.count) persisted documents in VecturaKit")

            let recordings = try await databaseManager.getAllRecordings()
            let recordingsWithTranscripts = recordings.filter { $0.hasTranscript }
            debugLog("[Init] Recordings with transcripts: \(recordingsWithTranscripts.count)")

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
                debugLog("[Init] Adding \(newDocsToAdd.count) new documents to index...")
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
                        debugLog("[Init] Failed to add doc \(doc.id): \(error.localizedDescription)")
                    }
                }

                // Mark recordings as indexed after adding new docs
                for recording in recordingsWithTranscripts {
                    indexedRecordings.insert(recording.id)
                }
            }

            debugLog("[Init] Complete - \(self.indexedRecordings.count) recordings, \(self.documentToSegment.count) segments mapped")
            logger.info("Loaded \(self.indexedRecordings.count) recordings (\(existingDocs.count) from cache, \(newDocsToAdd.count) new)")

        } catch {
            logger.warning("Failed to load indexed recordings: \(error.localizedDescription)")
            debugLog("[Init] Error: \(error.localizedDescription)")
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
