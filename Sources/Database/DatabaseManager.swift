import Foundation
import SQLite
import os.log

/// Database manager for meeting recordings and transcripts using SQLite with FTS5
public actor DatabaseManager {

    // MARK: - Singleton

    /// Shared database manager instance. Use this instead of creating new instances
    /// to prevent concurrent access issues with SQLite.
    private static var _shared: DatabaseManager?
    private static let initLock = NSLock()

    /// Get the shared DatabaseManager instance, initializing if needed
    public static func shared() async throws -> DatabaseManager {
        // Fast path: already initialized
        if let existing = _shared {
            return existing
        }

        // Thread-safe initialization
        initLock.lock()
        defer { initLock.unlock() }

        // Double-check after acquiring lock
        if let existing = _shared {
            return existing
        }

        let manager = try await DatabaseManager()
        _shared = manager
        return manager
    }

    // MARK: - Types
    
    public struct Recording: Identifiable, Hashable, Sendable {
        public let id: Int64
        public let title: String
        public let date: Date
        public let duration: TimeInterval
        public let fileURL: URL
        public let fileSize: Int64
        public let appName: String?
        public let hasTranscript: Bool
        public let isFavorite: Bool
        public let summary: String?
        public let actionItems: String?

        public init(id: Int64, title: String, date: Date, duration: TimeInterval, fileURL: URL, fileSize: Int64, appName: String?, hasTranscript: Bool, isFavorite: Bool = false, summary: String? = nil, actionItems: String? = nil) {
            self.id = id
            self.title = title
            self.date = date
            self.duration = duration
            self.fileURL = fileURL
            self.fileSize = fileSize
            self.appName = appName
            self.hasTranscript = hasTranscript
            self.isFavorite = isFavorite
            self.summary = summary
            self.actionItems = actionItems
        }
    }
    
    public struct Transcript: Identifiable, Sendable {
        public let id: Int64
        public let recordingId: Int64
        public let fullText: String
        public let language: String?
        public let processingTime: TimeInterval
        public let createdAt: Date
        
        public init(id: Int64, recordingId: Int64, fullText: String, language: String?, processingTime: TimeInterval, createdAt: Date) {
            self.id = id
            self.recordingId = recordingId
            self.fullText = fullText
            self.language = language
            self.processingTime = processingTime
            self.createdAt = createdAt
        }
    }
    
    public struct TranscriptSegment: Sendable {
        public let id: Int64
        public let transcriptId: Int64
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        public let text: String
        public let speaker: String
        public let confidence: Float

        public init(id: Int64, transcriptId: Int64, startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String, confidence: Float) {
            self.id = id
            self.transcriptId = transcriptId
            self.startTime = startTime
            self.endTime = endTime
            self.text = text
            self.speaker = speaker
            self.confidence = confidence
        }
    }

    public struct Embedding: Sendable {
        public let id: Int64
        public let segmentId: Int64
        public let vector: [Float]
        public let model: String
        public let createdAt: Date

        public init(id: Int64, segmentId: Int64, vector: [Float], model: String, createdAt: Date) {
            self.id = id
            self.segmentId = segmentId
            self.vector = vector
            self.model = model
            self.createdAt = createdAt
        }
    }

    public struct ChatMessage: Identifiable, Sendable {
        public let id: Int64
        public let sessionId: String
        public let recordingId: Int64?
        public let role: String  // "user" or "assistant"
        public let content: String
        public let citations: [Int64]?  // segment IDs
        public let timestamp: Date

        public init(id: Int64, sessionId: String, recordingId: Int64?, role: String, content: String, citations: [Int64]?, timestamp: Date) {
            self.id = id
            self.sessionId = sessionId
            self.recordingId = recordingId
            self.role = role
            self.content = content
            self.citations = citations
            self.timestamp = timestamp
        }
    }

    public enum DatabaseError: Error {
        case initializationFailed
        case insertFailed
        case queryFailed
        case notFound
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "Database")
    private var db: Connection?
    
    // Table definitions
    private let recordings = Table("recordings")
    private let transcripts = Table("transcripts")
    private let segments = Table("transcript_segments")
    private let searchIndex = Table("transcript_search")
    private let embeddings = Table("embeddings")
    private let chatHistory = Table("chat_history")
    
    // Column definitions - Recordings
    private let id = Expression<Int64>("id")
    private let title = Expression<String>("title")
    private let date = Expression<Date>("date")
    private let duration = Expression<Double>("duration")
    private let fileURL = Expression<String>("file_url")
    private let fileSize = Expression<Int64>("file_size")
    private let appName = Expression<String?>("app_name")
    private let hasTranscript = Expression<Bool>("has_transcript")
    private let isFavorite = Expression<Bool>("is_favorite")
    private let summaryColumn = Expression<String?>("summary")
    private let actionItemsColumn = Expression<String?>("action_items")
    
    // Column definitions - Transcripts
    private let recordingId = Expression<Int64>("recording_id")
    private let fullText = Expression<String>("full_text")
    private let language = Expression<String?>("language")
    private let processingTime = Expression<Double>("processing_time")
    private let createdAt = Expression<Date>("created_at")
    
    // Column definitions - Segments
    private let transcriptId = Expression<Int64>("transcript_id")
    private let startTime = Expression<Double>("start_time")
    private let endTime = Expression<Double>("end_time")
    private let text = Expression<String>("text")
    private let speaker = Expression<String>("speaker")
    private let confidence = Expression<Double>("confidence")

    // Column definitions - Embeddings
    private let segmentId = Expression<Int64>("segment_id")
    private let embeddingVector = Expression<Data>("embedding_vector")
    private let embeddingModel = Expression<String>("embedding_model")

    // Column definitions - Chat History
    private let chatSessionId = Expression<String>("chat_session_id")
    private let chatRecordingId = Expression<Int64?>("recording_id")
    private let role = Expression<String>("role")
    private let content = Expression<String>("content")
    private let citations = Expression<String?>("citations")
    private let timestamp = Expression<Date>("timestamp")

    // Column definitions - Recording Embeddings
    private let recEmbRecordingId = Expression<Int64>("recording_id")
    private let recEmbText = Expression<String>("embedding_text")
    private let recEmbVector = Expression<Data>("embedding_vector")
    private let recEmbModel = Expression<String>("embedding_model")
    
    // MARK: - Initialization
    
    public init(databasePath: String? = nil) async throws {
        let dbPath = databasePath ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Engram")
            .appendingPathComponent("echo.db")
            .path
        
        // Ensure directory exists
        let directory = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        logger.info("Initializing database at: \(dbPath)")
        
        do {
            db = try Connection(dbPath)
            try createTables()
            try migrateSchema()
        } catch {
            logger.error("Database initialization failed: \(error.localizedDescription)")
            throw DatabaseError.initializationFailed
        }
    }
    
    // MARK: - Schema Creation
    
    private func createTables() throws {
        guard let db = db else { throw DatabaseError.initializationFailed }
        
        // Recordings table
        try db.run(recordings.create(ifNotExists: true) { t in
            t.column(id, primaryKey: .autoincrement)
            t.column(title)
            t.column(date)
            t.column(duration)
            t.column(fileURL)
            t.column(fileSize)
            t.column(appName)
            t.column(hasTranscript, defaultValue: false)
            t.column(isFavorite, defaultValue: false)
        })
        
        // Transcripts table
        try db.run(transcripts.create(ifNotExists: true) { t in
            t.column(id, primaryKey: .autoincrement)
            t.column(recordingId)
            t.column(fullText)
            t.column(language)
            t.column(processingTime)
            t.column(createdAt)
            t.foreignKey(recordingId, references: recordings, id, delete: .cascade)
        })
        
        // Segments table
        try db.run(segments.create(ifNotExists: true) { t in
            t.column(id, primaryKey: .autoincrement)
            t.column(transcriptId)
            t.column(startTime)
            t.column(endTime)
            t.column(text)
            t.column(speaker)
            t.column(confidence)
            t.foreignKey(transcriptId, references: transcripts, id, delete: .cascade)
        })
        
        // FTS5 search index - Using raw SQL for FTS5
        try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_search
            USING fts5(text, title, content='transcript_segments', content_rowid='id')
        """)

        // Embeddings table - stores vector embeddings linked to transcript segments
        try db.run(embeddings.create(ifNotExists: true) { t in
            t.column(id, primaryKey: .autoincrement)
            t.column(segmentId)
            t.column(embeddingVector)
            t.column(embeddingModel)
            t.column(createdAt, defaultValue: Date())
            t.foreignKey(segmentId, references: segments, id, delete: .cascade)
        })

        // Index for fast segment lookups
        try db.execute("CREATE INDEX IF NOT EXISTS idx_embeddings_segment ON embeddings(segment_id)")

        // Chat history table - stores chat messages per session
        try db.run(chatHistory.create(ifNotExists: true) { t in
            t.column(id, primaryKey: .autoincrement)
            t.column(chatSessionId)
            t.column(chatRecordingId)
            t.column(role)
            t.column(content)
            t.column(citations)
            t.column(timestamp, defaultValue: Date())
            t.foreignKey(chatRecordingId, references: recordings, id, delete: .setNull)
        })

        // Index for fast session lookups
        try db.execute("CREATE INDEX IF NOT EXISTS idx_chat_session ON chat_history(chat_session_id)")

        // Recording-level embeddings table - stores summary embeddings for cross-recording search
        try db.execute("""
            CREATE TABLE IF NOT EXISTS recording_embeddings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                recording_id INTEGER NOT NULL UNIQUE REFERENCES recordings(id) ON DELETE CASCADE,
                embedding_text TEXT NOT NULL,
                embedding_vector BLOB NOT NULL,
                embedding_model TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)

        // Segment-level FTS5 search index for keyword search across recordings
        try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS segment_search
            USING fts5(text, recording_id UNINDEXED, segment_id UNINDEXED)
        """)

        logger.info("Database schema created successfully")
    }

    private func migrateSchema() throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        // Check which columns exist in recordings table
        let tableInfo = try db.prepare("PRAGMA table_info(recordings)")
        var hasFavoriteColumn = false
        var hasSummaryColumn = false
        var hasActionItemsColumn = false

        for row in tableInfo {
            if let columnName = row[1] as? String {
                switch columnName {
                case "is_favorite":
                    hasFavoriteColumn = true
                case "summary":
                    hasSummaryColumn = true
                case "action_items":
                    hasActionItemsColumn = true
                default:
                    break
                }
            }
        }

        // Add is_favorite column if missing
        if !hasFavoriteColumn {
            try db.execute("ALTER TABLE recordings ADD COLUMN is_favorite INTEGER DEFAULT 0")
            logger.info("Migration: Added is_favorite column to recordings table")
        }

        // Add summary column if missing
        if !hasSummaryColumn {
            try db.execute("ALTER TABLE recordings ADD COLUMN summary TEXT")
            logger.info("Migration: Added summary column to recordings table")
        }

        // Add action_items column if missing
        if !hasActionItemsColumn {
            try db.execute("ALTER TABLE recordings ADD COLUMN action_items TEXT")
            logger.info("Migration: Added action_items column to recordings table")
        }

        // Migrate: Create recording_embeddings table if missing
        let hasRecordingEmbeddings = try db.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='recording_embeddings'"
        ) as! Int64 > 0
        if !hasRecordingEmbeddings {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS recording_embeddings (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    recording_id INTEGER NOT NULL UNIQUE REFERENCES recordings(id) ON DELETE CASCADE,
                    embedding_text TEXT NOT NULL,
                    embedding_vector BLOB NOT NULL,
                    embedding_model TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            logger.info("Migration: Created recording_embeddings table")
        }

        // Migrate: Create segment_search FTS5 table if missing
        let hasSegmentSearch = try db.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='segment_search'"
        ) as! Int64 > 0
        if !hasSegmentSearch {
            try db.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS segment_search
                USING fts5(text, recording_id UNINDEXED, segment_id UNINDEXED)
            """)
            logger.info("Migration: Created segment_search FTS5 table")
        }
    }

    // MARK: - Recording Operations
    
    public func saveRecording(title: String, date: Date, duration: TimeInterval, fileURL: URL, fileSize: Int64, appName: String?) async throws -> Int64 {
        guard let db = db else { throw DatabaseError.initializationFailed }
        
        do {
            let insert = recordings.insert(
                self.title <- title,
                self.date <- date,
                self.duration <- duration,
                self.fileURL <- fileURL.path,
                self.fileSize <- fileSize,
                self.appName <- appName,
                self.hasTranscript <- false
            )
            
            let rowId = try db.run(insert)
            logger.info("Recording saved: \(title) (ID: \(rowId))")
            return rowId
        } catch {
            logger.error("Failed to save recording: \(error.localizedDescription)")
            throw DatabaseError.insertFailed
        }
    }
    
    public func getAllRecordings() async throws -> [Recording] {
        guard let db = db else { throw DatabaseError.initializationFailed }

        var results: [Recording] = []

        for row in try db.prepare(recordings.order(date.desc)) {
            let recording = Recording(
                id: row[id],
                title: row[title],
                date: row[date],
                duration: row[duration],
                fileURL: URL(fileURLWithPath: row[fileURL]),
                fileSize: row[fileSize],
                appName: row[appName],
                hasTranscript: row[hasTranscript],
                isFavorite: row[isFavorite],
                summary: row[summaryColumn],
                actionItems: row[actionItemsColumn]
            )
            results.append(recording)
        }

        return results
    }

    /// Get recordings that need transcription (have audio file but no transcript)
    /// Results are ordered by date ascending (oldest first) for FIFO processing
    public func getRecordingsNeedingTranscription() async throws -> [Recording] {
        guard let db = db else { throw DatabaseError.initializationFailed }

        var results: [Recording] = []

        // Find recordings where hasTranscript == false, ordered by date (oldest first)
        let query = recordings
            .filter(hasTranscript == false)
            .order(date.asc)

        for row in try db.prepare(query) {
            let fileURLValue = URL(fileURLWithPath: row[fileURL])

            // Skip if audio file no longer exists
            guard FileManager.default.fileExists(atPath: fileURLValue.path) else {
                logger.warning("Skipping recording \(row[self.id]) - audio file missing: \(fileURLValue.path)")
                continue
            }

            let recording = Recording(
                id: row[id],
                title: row[title],
                date: row[date],
                duration: row[duration],
                fileURL: fileURLValue,
                fileSize: row[fileSize],
                appName: row[appName],
                hasTranscript: row[hasTranscript],
                isFavorite: row[isFavorite],
                summary: row[summaryColumn],
                actionItems: row[actionItemsColumn]
            )
            results.append(recording)
        }

        return results
    }

    /// Get recordings that need AI generation (have transcript but missing summary and/or action items)
    /// - Parameters:
    ///   - needsSummary: If true, include recordings missing summaries
    ///   - needsActionItems: If true, include recordings missing action items
    /// - Returns: Recordings needing AI processing, ordered by date ascending (oldest first)
    public func getRecordingsNeedingAIGeneration(
        needsSummary: Bool,
        needsActionItems: Bool
    ) async throws -> [Recording] {
        guard let db = db else { throw DatabaseError.initializationFailed }
        guard needsSummary || needsActionItems else { return [] }

        var results: [Recording] = []

        // Fetch recordings with transcripts, then filter in Swift for NULL summary/actionItems
        let query = recordings
            .filter(hasTranscript == true)
            .order(date.asc)

        for row in try db.prepare(query) {
            let summaryValue = row[summaryColumn]
            let actionItemsValue = row[actionItemsColumn]

            // Check if this recording needs processing based on what's requested
            let needsThisSummary = needsSummary && summaryValue == nil
            let needsTheseActionItems = needsActionItems && actionItemsValue == nil

            guard needsThisSummary || needsTheseActionItems else {
                continue
            }

            let recording = Recording(
                id: row[id],
                title: row[title],
                date: row[date],
                duration: row[duration],
                fileURL: URL(fileURLWithPath: row[fileURL]),
                fileSize: row[fileSize],
                appName: row[appName],
                hasTranscript: row[hasTranscript],
                isFavorite: row[isFavorite],
                summary: summaryValue,
                actionItems: actionItemsValue
            )
            results.append(recording)
        }

        return results
    }

    public func getRecording(id recordingId: Int64) async throws -> Recording {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = recordings.filter(id == recordingId)

        guard let row = try db.pluck(query) else {
            throw DatabaseError.notFound
        }

        return Recording(
            id: row[id],
            title: row[title],
            date: row[date],
            duration: row[duration],
            fileURL: URL(fileURLWithPath: row[fileURL]),
            fileSize: row[fileSize],
            appName: row[appName],
            hasTranscript: row[hasTranscript],
            isFavorite: row[isFavorite],
            summary: row[summaryColumn],
            actionItems: row[actionItemsColumn]
        )
    }
    
    public func deleteRecording(id recordingId: Int64) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let recording = recordings.filter(id == recordingId)
        try db.run(recording.delete())

        logger.info("Recording deleted: ID \(recordingId)")
    }

    public func toggleFavorite(id recordingId: Int64) async throws -> Bool {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = recordings.filter(id == recordingId)

        guard let row = try db.pluck(query) else {
            throw DatabaseError.notFound
        }

        let currentValue = row[isFavorite]
        let newValue = !currentValue

        try db.run(query.update(isFavorite <- newValue))

        logger.info("Recording \(recordingId) favorite toggled to: \(newValue)")
        return newValue
    }

    /// Save or update the AI-generated summary for a recording
    public func saveSummary(recordingId: Int64, summary: String) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = recordings.filter(id == recordingId)
        try db.run(query.update(summaryColumn <- summary))

        logger.info("Summary saved for recording \(recordingId)")
    }

    /// Save or update the AI-generated action items for a recording
    public func saveActionItems(recordingId: Int64, actionItems: String) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = recordings.filter(id == recordingId)
        try db.run(query.update(actionItemsColumn <- actionItems))

        logger.info("Action items saved for recording \(recordingId)")
    }

    /// Update the title of a recording (e.g., with AI-generated title)
    /// Also renames the file on disk if it exists (fails gracefully if file is missing/moved)
    /// Handles both audio (.mov) and video (_video.mov) files
    public func updateTitle(recordingId: Int64, newTitle: String) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = recordings.filter(id == recordingId)

        // Get the current file URL
        guard let row = try db.pluck(query) else {
            throw DatabaseError.notFound
        }

        let currentFileURL = URL(fileURLWithPath: row[fileURL])
        var newFileURL = currentFileURL

        // Try to rename the file on disk (fail gracefully if file doesn't exist)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: currentFileURL.path) {
            // Sanitize the new title for use as a filename
            let sanitizedTitle = sanitizeForFilename(newTitle)
            let fileExtension = currentFileURL.pathExtension
            let directory = currentFileURL.deletingLastPathComponent()
            newFileURL = directory.appendingPathComponent(sanitizedTitle).appendingPathExtension(fileExtension)

            // Only rename if the new path is different and doesn't already exist
            if newFileURL != currentFileURL {
                if fileManager.fileExists(atPath: newFileURL.path) {
                    // File with new name already exists - add timestamp to make unique
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let uniqueName = "\(sanitizedTitle)_\(timestamp)"
                    newFileURL = directory.appendingPathComponent(uniqueName).appendingPathExtension(fileExtension)
                }

                do {
                    try fileManager.moveItem(at: currentFileURL, to: newFileURL)
                    logger.info("File renamed from \(currentFileURL.lastPathComponent) to \(newFileURL.lastPathComponent)")

                    // Also rename the video file if it exists (video files have _video suffix before extension)
                    let currentBaseName = currentFileURL.deletingPathExtension().lastPathComponent
                    let videoFileName = "\(currentBaseName)_video.\(fileExtension)"
                    let currentVideoURL = directory.appendingPathComponent(videoFileName)

                    if fileManager.fileExists(atPath: currentVideoURL.path) {
                        let newVideoFileName = "\(sanitizedTitle)_video.\(fileExtension)"
                        let newVideoURL = directory.appendingPathComponent(newVideoFileName)

                        do {
                            try fileManager.moveItem(at: currentVideoURL, to: newVideoURL)
                            logger.info("Video file renamed from \(currentVideoURL.lastPathComponent) to \(newVideoURL.lastPathComponent)")
                        } catch {
                            logger.warning("Could not rename video file: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    // Log but don't fail - file might be in use or have permission issues
                    logger.warning("Could not rename file: \(error.localizedDescription). Updating title only.")
                    newFileURL = currentFileURL // Keep original URL if rename failed
                }
            }
        } else {
            logger.info("File not found at \(currentFileURL.path) - updating title in database only")
        }

        // Update database with new title and potentially new file URL
        try db.run(query.update(
            title <- newTitle,
            fileURL <- newFileURL.path
        ))

        logger.info("Title updated for recording \(recordingId): \(newTitle)")
    }

    /// Sanitize a string for use as a filename
    private func sanitizeForFilename(_ name: String) -> String {
        var sanitized = name

        // Replace invalid filesystem characters with underscores
        let invalidChars = CharacterSet(charactersIn: ":/\\?*<>|\"'\n\r\t")
        sanitized = sanitized.unicodeScalars
            .map { invalidChars.contains($0) ? "_" : String($0) }
            .joined()

        // Replace multiple spaces/underscores with single underscore
        while sanitized.contains("  ") {
            sanitized = sanitized.replacingOccurrences(of: "  ", with: " ")
        }
        while sanitized.contains("__") {
            sanitized = sanitized.replacingOccurrences(of: "__", with: "_")
        }

        // Trim whitespace and underscores from ends
        sanitized = sanitized.trimmingCharacters(in: .whitespaces)
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        // Limit length to avoid filesystem issues (keep under 200 chars)
        if sanitized.count > 200 {
            sanitized = String(sanitized.prefix(200))
        }

        // Fallback if completely empty
        if sanitized.isEmpty {
            sanitized = "Recording"
        }

        return sanitized
    }

    // MARK: - Transcript Operations
    
    public func saveTranscript(recordingId: Int64, fullText: String, language: String?, processingTime: TimeInterval, segments: [TranscriptSegment]) async throws -> Int64 {
        guard let db = db else { throw DatabaseError.initializationFailed }
        
        do {
            // Insert transcript
            let transcriptInsert = transcripts.insert(
                self.recordingId <- recordingId,
                self.fullText <- fullText,
                self.language <- language,
                self.processingTime <- processingTime,
                self.createdAt <- Date()
            )
            
            let transcriptId = try db.run(transcriptInsert)
            
            // Insert segments
            for segment in segments {
                let segmentInsert = self.segments.insert(
                    self.transcriptId <- transcriptId,
                    self.startTime <- segment.startTime,
                    self.endTime <- segment.endTime,
                    self.text <- segment.text,
                    self.speaker <- segment.speaker,
                    self.confidence <- Double(segment.confidence)
                )
                try db.run(segmentInsert)
            }
            
            // Update recording flag
            let recording = recordings.filter(id == recordingId)
            try db.run(recording.update(hasTranscript <- true))
            
            // Add to search index
            try db.run(searchIndex.insert(self.text <- fullText, title <- ""))
            
            logger.info("Transcript saved: \(segments.count) segments for recording \(recordingId)")
            return transcriptId
        } catch {
            logger.error("Failed to save transcript: \(error.localizedDescription)")
            throw DatabaseError.insertFailed
        }
    }
    
    public func getTranscript(forRecording recordingId: Int64) async throws -> Transcript? {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = transcripts.filter(self.recordingId == recordingId)

        guard let row = try db.pluck(query) else {
            return nil
        }

        return Transcript(
            id: row[id],
            recordingId: row[self.recordingId],
            fullText: row[fullText],
            language: row[language],
            processingTime: row[processingTime],
            createdAt: row[createdAt]
        )
    }

    public func getSegments(forTranscriptId transcriptId: Int64) async throws -> [TranscriptSegment] {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = segments
            .filter(self.transcriptId == transcriptId)
            .order(startTime.asc)

        var results: [TranscriptSegment] = []
        for row in try db.prepare(query) {
            let segment = TranscriptSegment(
                id: row[id],
                transcriptId: row[self.transcriptId],
                startTime: row[startTime],
                endTime: row[endTime],
                text: row[text],
                speaker: row[speaker],
                confidence: Float(row[confidence])
            )
            results.append(segment)
        }

        return results
    }

    /// Get segments with pagination support for large transcripts
    /// - Parameters:
    ///   - transcriptId: The transcript ID to get segments for
    ///   - limit: Maximum number of segments to return
    ///   - offset: Number of segments to skip (for pagination)
    /// - Returns: Array of transcript segments
    public func getSegmentsPaginated(forTranscriptId transcriptId: Int64, limit: Int, offset: Int) async throws -> [TranscriptSegment] {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = segments
            .filter(self.transcriptId == transcriptId)
            .order(startTime.asc)
            .limit(limit, offset: offset)

        var results: [TranscriptSegment] = []
        for row in try db.prepare(query) {
            let segment = TranscriptSegment(
                id: row[id],
                transcriptId: row[self.transcriptId],
                startTime: row[startTime],
                endTime: row[endTime],
                text: row[text],
                speaker: row[speaker],
                confidence: Float(row[confidence])
            )
            results.append(segment)
        }

        return results
    }

    /// Get total count of segments for a transcript (for pagination)
    public func getSegmentCount(forTranscriptId transcriptId: Int64) async throws -> Int {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = segments.filter(self.transcriptId == transcriptId)
        return try db.scalar(query.count)
    }
    
    public func searchTranscripts(query: String) async throws -> [Recording] {
        guard let db = db else { throw DatabaseError.initializationFailed }

        // Simple LIKE-based search (FTS5 match() requires more setup)
        var matchedRecordingIds: Set<Int64> = []

        // Find matching segments using LIKE
        for segmentRow in try db.prepare(segments.filter(text.like("%\(query)%"))) {
            let tId = segmentRow[transcriptId]

            // Find parent transcript
            if let transcriptRow = try db.pluck(transcripts.filter(id == tId)) {
                matchedRecordingIds.insert(transcriptRow[recordingId])
            }
        }

        // Also search in recording titles
        for recordingRow in try db.prepare(recordings.filter(title.like("%\(query)%"))) {
            matchedRecordingIds.insert(recordingRow[id])
        }

        // Fetch recordings
        var results: [Recording] = []
        for recId in matchedRecordingIds {
            if let recording = try? await getRecording(id: recId) {
                results.append(recording)
            }
        }

        return results
    }

    // MARK: - Embedding Operations

    /// Saves an embedding vector for a transcript segment
    public func saveEmbedding(segmentId: Int64, vector: [Float], model: String) async throws -> Int64 {
        guard let db = db else { throw DatabaseError.initializationFailed }

        // Convert [Float] to Data for storage
        let vectorData = vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }

        do {
            let insert = embeddings.insert(
                self.segmentId <- segmentId,
                self.embeddingVector <- vectorData,
                self.embeddingModel <- model,
                self.createdAt <- Date()
            )

            let rowId = try db.run(insert)
            logger.info("Embedding saved for segment \(segmentId) (ID: \(rowId))")
            return rowId
        } catch {
            logger.error("Failed to save embedding: \(error.localizedDescription)")
            throw DatabaseError.insertFailed
        }
    }

    /// Gets the embedding for a specific segment
    public func getEmbedding(forSegmentId segmentId: Int64) async throws -> Embedding? {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = embeddings.filter(self.segmentId == segmentId)

        guard let row = try db.pluck(query) else {
            return nil
        }

        // Convert Data back to [Float]
        let vectorData = row[embeddingVector]
        let vector = vectorData.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }

        return Embedding(
            id: row[id],
            segmentId: row[self.segmentId],
            vector: vector,
            model: row[embeddingModel],
            createdAt: row[createdAt]
        )
    }

    /// Checks if an embedding exists for a segment
    public func hasEmbedding(forSegmentId segmentId: Int64) async throws -> Bool {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = embeddings.filter(self.segmentId == segmentId)
        return try db.pluck(query) != nil
    }

    /// Deletes all embeddings for segments belonging to a transcript
    public func deleteEmbeddings(forTranscriptId transcriptId: Int64) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        // Get all segment IDs for this transcript
        let segmentQuery = segments.filter(self.transcriptId == transcriptId).select(id)
        var segmentIds: [Int64] = []

        for row in try db.prepare(segmentQuery) {
            segmentIds.append(row[id])
        }

        // Delete embeddings for each segment
        for segId in segmentIds {
            let embeddingQuery = embeddings.filter(self.segmentId == segId)
            try db.run(embeddingQuery.delete())
        }

        logger.info("Deleted embeddings for transcript \(transcriptId)")
    }

    /// Gets all embeddings for a transcript (for batch operations like similarity search)
    public func getAllEmbeddings(forTranscriptId transcriptId: Int64) async throws -> [Embedding] {
        guard let db = db else { throw DatabaseError.initializationFailed }

        // Join embeddings with segments to filter by transcript
        var results: [Embedding] = []

        let segmentQuery = segments.filter(self.transcriptId == transcriptId).select(id)
        var segmentIds: [Int64] = []

        for row in try db.prepare(segmentQuery) {
            segmentIds.append(row[id])
        }

        for segId in segmentIds {
            if let embedding = try await getEmbedding(forSegmentId: segId) {
                results.append(embedding)
            }
        }

        return results
    }

    // MARK: - Chat History Operations

    /// Saves a chat message to the history
    public func saveChatMessage(sessionId: String, recordingId: Int64?, role: String, content: String, citations: [Int64]?) async throws -> Int64 {
        guard let db = db else { throw DatabaseError.initializationFailed }

        // Convert citations array to JSON string
        var citationsJson: String? = nil
        if let citations = citations {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(citations) {
                citationsJson = String(data: data, encoding: .utf8)
            }
        }

        do {
            let insert = chatHistory.insert(
                self.chatSessionId <- sessionId,
                self.chatRecordingId <- recordingId,
                self.role <- role,
                self.content <- content,
                self.citations <- citationsJson,
                self.timestamp <- Date()
            )

            let rowId = try db.run(insert)
            logger.info("Chat message saved (session: \(sessionId), ID: \(rowId))")
            return rowId
        } catch {
            logger.error("Failed to save chat message: \(error.localizedDescription)")
            throw DatabaseError.insertFailed
        }
    }

    /// Gets all chat messages for a session, ordered by timestamp
    public func getChatHistory(sessionId: String) async throws -> [ChatMessage] {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = chatHistory
            .filter(self.chatSessionId == sessionId)
            .order(timestamp.asc)

        var results: [ChatMessage] = []
        let decoder = JSONDecoder()

        for row in try db.prepare(query) {
            // Parse citations JSON back to array
            var citationsArray: [Int64]? = nil
            if let citationsJson = row[citations],
               let data = citationsJson.data(using: .utf8) {
                citationsArray = try? decoder.decode([Int64].self, from: data)
            }

            let message = ChatMessage(
                id: row[id],
                sessionId: row[chatSessionId],
                recordingId: row[chatRecordingId],
                role: row[self.role],
                content: row[self.content],
                citations: citationsArray,
                timestamp: row[timestamp]
            )
            results.append(message)
        }

        return results
    }

    /// Deletes all messages for a chat session
    public func deleteChatSession(sessionId: String) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = chatHistory.filter(self.chatSessionId == sessionId)
        let deletedCount = try db.run(query.delete())

        logger.info("Deleted chat session \(sessionId) (\(deletedCount) messages)")
    }

    /// Gets all chat sessions (unique session IDs)
    public func getAllChatSessions() async throws -> [String] {
        guard let db = db else { throw DatabaseError.initializationFailed }

        var sessions: [String] = []
        let query = chatHistory.select(chatSessionId).group(chatSessionId)

        for row in try db.prepare(query) {
            sessions.append(row[chatSessionId])
        }

        return sessions
    }

    /// Gets the most recent chat message timestamp for a session
    public func getLastChatTimestamp(sessionId: String) async throws -> Date? {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let query = chatHistory
            .filter(self.chatSessionId == sessionId)
            .order(timestamp.desc)
            .limit(1)

        if let row = try db.pluck(query) {
            return row[timestamp]
        }

        return nil
    }

    // MARK: - Recording Embedding Operations

    /// Upsert a recording-level embedding (for cross-recording search)
    public func saveRecordingEmbedding(recordingId: Int64, text: String, vector: [Float], model: String) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let vectorData = vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }

        // Use INSERT OR REPLACE for upsert (recording_id has UNIQUE constraint)
        try db.run("""
            INSERT INTO recording_embeddings (recording_id, embedding_text, embedding_vector, embedding_model, created_at)
            VALUES (?, ?, ?, ?, datetime('now'))
            ON CONFLICT(recording_id) DO UPDATE SET
                embedding_text = excluded.embedding_text,
                embedding_vector = excluded.embedding_vector,
                embedding_model = excluded.embedding_model,
                created_at = datetime('now')
        """, recordingId, text, vectorData.datatypeValue, model)

        logger.info("Recording embedding saved for recording \(recordingId)")
    }

    /// Get the embedding for a specific recording
    public func getRecordingEmbedding(recordingId: Int64) async throws -> (text: String, vector: [Float])? {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let stmt = try db.prepare("SELECT embedding_text, embedding_vector FROM recording_embeddings WHERE recording_id = ?", recordingId)

        for row in stmt {
            guard let text = row[0] as? String,
                  let vectorBlob = row[1] as? Blob else { continue }

            let vectorData = Data(bytes: vectorBlob.bytes, count: vectorBlob.bytes.count)
            let vector = vectorData.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
            return (text: text, vector: vector)
        }

        return nil
    }

    /// Get all recording embeddings (for loading into memory on startup)
    public func getAllRecordingEmbeddings() async throws -> [(recordingId: Int64, vector: [Float])] {
        guard let db = db else { throw DatabaseError.initializationFailed }

        var results: [(recordingId: Int64, vector: [Float])] = []
        let stmt = try db.prepare("SELECT recording_id, embedding_vector FROM recording_embeddings")

        for row in stmt {
            guard let recId = row[0] as? Int64,
                  let vectorBlob = row[1] as? Blob else { continue }

            let vectorData = Data(bytes: vectorBlob.bytes, count: vectorBlob.bytes.count)
            let vector = vectorData.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
            results.append((recordingId: recId, vector: vector))
        }

        return results
    }

    /// Delete the recording embedding for a specific recording
    public func deleteRecordingEmbedding(recordingId: Int64) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        try db.run("DELETE FROM recording_embeddings WHERE recording_id = ?", recordingId)
        logger.info("Recording embedding deleted for recording \(recordingId)")
    }

    // MARK: - Segment Search (FTS5) Operations

    /// Insert a segment into the FTS5 search index
    public func insertSegmentSearchEntry(segmentId: Int64, recordingId: Int64, text: String) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        try db.run(
            "INSERT INTO segment_search (text, recording_id, segment_id) VALUES (?, ?, ?)",
            text, recordingId, segmentId
        )
    }

    /// Check if the segment_search FTS5 table has any entries
    public func segmentSearchCount() async throws -> Int {
        guard let db = db else { throw DatabaseError.initializationFailed }

        let count = try db.scalar("SELECT count(*) FROM segment_search") as! Int64
        return Int(count)
    }

    /// Delete all FTS5 entries for a recording
    public func deleteSegmentSearchEntries(recordingId: Int64) async throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        try db.run("DELETE FROM segment_search WHERE recording_id = ?", recordingId)
        logger.info("Segment search entries deleted for recording \(recordingId)")
    }

    /// Keyword search across recordings using FTS5 MATCH with BM25 ranking.
    /// BM25 naturally downweights common terms (like "what", "the") that appear across many segments,
    /// so no hardcoded stop word list is needed.
    public func keywordSearchRecordings(query: String, limit: Int = 10) async throws -> [(recordingId: Int64, matchCount: Int)] {
        guard let db = db else { throw DatabaseError.initializationFailed }

        // Strip non-alphanumeric chars to produce clean FTS5 tokens
        let tokens = query.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : Character(" ") }
            .split(separator: " ")
            .map { String($0).lowercased() }
            .filter { $0.count > 1 }

        guard !tokens.isEmpty else { return [] }

        let ftsQuery = tokens.joined(separator: " OR ")

        // Use FTS5's built-in `rank` column (BM25 by default) for TF-IDF relevance scoring.
        // `rank` is negative (lower = more relevant), so we negate and sum per recording.
        // Note: bm25() auxiliary function cannot be used with GROUP BY, but the `rank`
        // column is materialized per-row and supports aggregation.
        let sql = """
            SELECT CAST(recording_id AS INTEGER) as rec_id,
                   SUM(-rank) as relevance
            FROM segment_search
            WHERE segment_search MATCH ?
            GROUP BY recording_id
            ORDER BY relevance DESC
            LIMIT ?
        """

        var results: [(recordingId: Int64, matchCount: Int)] = []

        do {
            let stmt = try db.prepare(sql, ftsQuery, limit)
            // Use failableNext() instead of for-in to avoid force-unwrap trap in SQLite.swift's
            // FailableIterator.next() — FTS5 can throw during row iteration, not just prepare.
            while let row = try stmt.failableNext() {
                if let recId = row[0] as? Int64,
                   let score = row[1] as? Double {
                    results.append((recordingId: recId, matchCount: max(1, Int(score * 1000))))
                }
            }
        } catch {
            logger.warning("FTS5 keyword search failed for query '\(query)': \(error.localizedDescription)")
        }

        return results
    }
}
