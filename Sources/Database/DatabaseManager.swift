import Foundation
import SQLite
import os.log

/// Database manager for meeting recordings and transcripts using SQLite with FTS5
public actor DatabaseManager {
    
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

        public init(id: Int64, title: String, date: Date, duration: TimeInterval, fileURL: URL, fileSize: Int64, appName: String?, hasTranscript: Bool, isFavorite: Bool = false) {
            self.id = id
            self.title = title
            self.date = date
            self.duration = duration
            self.fileURL = fileURL
            self.fileSize = fileSize
            self.appName = appName
            self.hasTranscript = hasTranscript
            self.isFavorite = isFavorite
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
    
    public enum DatabaseError: Error {
        case initializationFailed
        case insertFailed
        case queryFailed
        case notFound
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.projectecho.app", category: "Database")
    private var db: Connection?
    
    // Table definitions
    private let recordings = Table("recordings")
    private let transcripts = Table("transcripts")
    private let segments = Table("transcript_segments")
    private let searchIndex = Table("transcript_search")
    
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
    
    // MARK: - Initialization
    
    public init(databasePath: String? = nil) async throws {
        let dbPath = databasePath ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProjectEcho")
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
        
        logger.info("Database schema created successfully")
    }

    private func migrateSchema() throws {
        guard let db = db else { throw DatabaseError.initializationFailed }

        // Check if is_favorite column exists in recordings table
        let tableInfo = try db.prepare("PRAGMA table_info(recordings)")
        var hasFavoriteColumn = false

        for row in tableInfo {
            if let columnName = row[1] as? String, columnName == "is_favorite" {
                hasFavoriteColumn = true
                break
            }
        }

        // Add is_favorite column if missing
        if !hasFavoriteColumn {
            try db.execute("ALTER TABLE recordings ADD COLUMN is_favorite INTEGER DEFAULT 0")
            logger.info("Migration: Added is_favorite column to recordings table")
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
                isFavorite: row[isFavorite]
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
            isFavorite: row[isFavorite]
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
}
