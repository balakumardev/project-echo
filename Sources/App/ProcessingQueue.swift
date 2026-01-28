import Foundation
import os.log
import Database
import UI

/// Manages background processing tasks with proper queuing to prevent resource conflicts.
///
/// This actor ensures:
/// - Only one transcription runs at a time (WhisperKit is memory-intensive)
/// - Only one AI generation runs at a time (LLM inference needs GPU)
/// - Tasks are processed in order (FIFO)
/// - Errors don't block subsequent tasks
@available(macOS 14.0, *)
public actor ProcessingQueue {

    // MARK: - Singleton

    public static let shared = ProcessingQueue()

    // MARK: - Types

    public struct QueuedTask: Identifiable, Sendable {
        public let id: UUID
        public let recordingId: Int64
        public let type: TaskType
        public let createdAt: Date

        public enum TaskType: String, Sendable {
            case transcription
            case aiGeneration  // Includes summary + action items
        }
    }

    public struct QueueStatus: Sendable {
        public let transcriptionQueueLength: Int
        public let aiGenerationQueueLength: Int
        public let currentTranscription: Int64?  // recordingId being transcribed
        public let currentAIGeneration: Int64?   // recordingId being processed

        public var isIdle: Bool {
            transcriptionQueueLength == 0 &&
            aiGenerationQueueLength == 0 &&
            currentTranscription == nil &&
            currentAIGeneration == nil
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "ProcessingQueue")

    // Transcription queue
    private var transcriptionQueue: [QueuedTask] = []
    private var isTranscribing = false
    private var currentTranscriptionId: Int64?

    // AI generation queue
    private var aiGenerationQueue: [QueuedTask] = []
    private var isGenerating = false
    private var currentAIGenerationId: Int64?

    // Task handlers (set by EngramApp)
    private var transcriptionHandler: ((Int64, URL) async -> Void)?
    private var aiGenerationHandler: ((Int64) async -> Void)?

    // Track pending URLs for transcription
    private var pendingTranscriptionURLs: [Int64: URL] = [:]

    // MARK: - Initialization

    private init() {}

    // MARK: - Configuration

    /// Set the handler for transcription tasks
    public func setTranscriptionHandler(_ handler: @escaping (Int64, URL) async -> Void) {
        transcriptionHandler = handler
        FileLogger.shared.debug("[ProcessingQueue] Transcription handler set")
    }

    /// Set the handler for AI generation tasks
    public func setAIGenerationHandler(_ handler: @escaping (Int64) async -> Void) {
        aiGenerationHandler = handler
        FileLogger.shared.debug("[ProcessingQueue] AI generation handler set")
    }

    // MARK: - Public API

    /// Queue a transcription task
    public func queueTranscription(recordingId: Int64, audioURL: URL) {
        let task = QueuedTask(
            id: UUID(),
            recordingId: recordingId,
            type: .transcription,
            createdAt: Date()
        )
        transcriptionQueue.append(task)
        pendingTranscriptionURLs[recordingId] = audioURL

        FileLogger.shared.debug("[ProcessingQueue] Queued transcription for recording \(recordingId). Queue length: \(transcriptionQueue.count)")
        logger.info("Queued transcription for recording \(recordingId). Queue length: \(self.transcriptionQueue.count)")

        // Notify UI of queue change
        notifyQueueStatusChanged()

        // Start processing if not already running
        Task {
            await processTranscriptionQueue()
        }
    }

    /// Queue an AI generation task (summary + action items)
    public func queueAIGeneration(recordingId: Int64) {
        let task = QueuedTask(
            id: UUID(),
            recordingId: recordingId,
            type: .aiGeneration,
            createdAt: Date()
        )
        aiGenerationQueue.append(task)

        logger.info("Queued AI generation for recording \(recordingId). Queue length: \(self.aiGenerationQueue.count)")

        // Notify UI of queue change
        notifyQueueStatusChanged()

        // Start processing if not already running
        Task {
            await processAIGenerationQueue()
        }
    }

    /// Get current queue status
    public func getStatus() -> QueueStatus {
        QueueStatus(
            transcriptionQueueLength: transcriptionQueue.count,
            aiGenerationQueueLength: aiGenerationQueue.count,
            currentTranscription: currentTranscriptionId,
            currentAIGeneration: currentAIGenerationId
        )
    }

    /// Post a notification with current queue status (for UI updates)
    private func notifyQueueStatusChanged() {
        let transcriptionCount = transcriptionQueue.count
        let aiCount = aiGenerationQueue.count

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .processingQueueDidChange,
                object: nil,
                userInfo: [
                    "transcriptionQueue": transcriptionCount,
                    "aiGenerationQueue": aiCount
                ]
            )
        }
    }

    /// Cancel all pending tasks for a recording
    public func cancelTasks(for recordingId: Int64) {
        transcriptionQueue.removeAll { $0.recordingId == recordingId }
        aiGenerationQueue.removeAll { $0.recordingId == recordingId }
        pendingTranscriptionURLs.removeValue(forKey: recordingId)
        logger.info("Cancelled pending tasks for recording \(recordingId)")
    }

    // MARK: - Startup Recovery

    /// Resume incomplete work from a previous session.
    /// Scans the database for recordings that need processing and queues them.
    /// Called on app startup after handlers are configured.
    ///
    /// - Parameters:
    ///   - database: The database manager to query
    ///   - autoTranscribe: Whether auto-transcription is enabled
    ///   - autoGenerateSummary: Whether auto-summary generation is enabled
    ///   - autoGenerateActionItems: Whether auto-action-items generation is enabled
    public func resumeIncompleteWork(
        database: DatabaseManager,
        autoTranscribe: Bool,
        autoGenerateSummary: Bool,
        autoGenerateActionItems: Bool
    ) async {
        FileLogger.shared.debug("[ProcessingQueue] resumeIncompleteWork called. autoTranscribe=\(autoTranscribe), handlerSet=\(transcriptionHandler != nil)")
        logger.info("Scanning for incomplete work to resume...")

        var transcriptionsQueued = 0
        var aiGenerationsQueued = 0

        // 1. Find recordings that need transcription
        if autoTranscribe {
            do {
                let needsTranscription = try await database.getRecordingsNeedingTranscription()
                FileLogger.shared.debug("[ProcessingQueue] Found \(needsTranscription.count) recordings needing transcription")
                for recording in needsTranscription {
                    // Skip if already queued
                    guard !transcriptionQueue.contains(where: { $0.recordingId == recording.id }) else {
                        FileLogger.shared.debug("[ProcessingQueue] Recording \(recording.id) already in queue, skipping")
                        continue
                    }
                    queueTranscription(recordingId: recording.id, audioURL: recording.fileURL)
                    transcriptionsQueued += 1
                }
            } catch {
                FileLogger.shared.debugError("[ProcessingQueue] Failed to query recordings needing transcription", error: error)
                logger.error("Failed to query recordings needing transcription: \(error.localizedDescription)")
            }
        } else {
            FileLogger.shared.debug("[ProcessingQueue] autoTranscribe is FALSE, skipping transcription queue")
        }

        // 2. Find recordings that need AI generation (summary and/or action items)
        if autoGenerateSummary || autoGenerateActionItems {
            do {
                let needsAI = try await database.getRecordingsNeedingAIGeneration(
                    needsSummary: autoGenerateSummary,
                    needsActionItems: autoGenerateActionItems
                )
                for recording in needsAI {
                    // Skip if already queued
                    guard !aiGenerationQueue.contains(where: { $0.recordingId == recording.id }) else {
                        continue
                    }
                    queueAIGeneration(recordingId: recording.id)
                    aiGenerationsQueued += 1
                }
            } catch {
                logger.error("Failed to query recordings needing AI generation: \(error.localizedDescription)")
            }
        }

        if transcriptionsQueued > 0 || aiGenerationsQueued > 0 {
            FileLogger.shared.debug("[ProcessingQueue] Resumed incomplete work: \(transcriptionsQueued) transcriptions, \(aiGenerationsQueued) AI generations queued")
            logger.info("Resumed incomplete work: \(transcriptionsQueued) transcriptions, \(aiGenerationsQueued) AI generations queued")
        } else {
            FileLogger.shared.debug("[ProcessingQueue] No incomplete work to resume")
            logger.info("No incomplete work to resume")
        }
    }

    // MARK: - Queue Processing

    private func processTranscriptionQueue() async {
        FileLogger.shared.debug("[ProcessingQueue] processTranscriptionQueue called. isTranscribing=\(isTranscribing), queueLength=\(transcriptionQueue.count), handlerSet=\(transcriptionHandler != nil)")

        // Prevent concurrent processing
        guard !isTranscribing else {
            FileLogger.shared.debug("[ProcessingQueue] Already transcribing, skipping")
            return
        }
        guard let task = transcriptionQueue.first else {
            FileLogger.shared.debug("[ProcessingQueue] Queue empty, nothing to process")
            return
        }
        guard let handler = transcriptionHandler else {
            FileLogger.shared.debug("[ProcessingQueue] ERROR: No transcription handler set!")
            logger.warning("No transcription handler set")
            return
        }
        guard let audioURL = pendingTranscriptionURLs[task.recordingId] else {
            FileLogger.shared.debug("[ProcessingQueue] No audio URL for recording \(task.recordingId), skipping")
            logger.warning("No audio URL for recording \(task.recordingId)")
            transcriptionQueue.removeFirst()
            await processTranscriptionQueue()
            return
        }

        isTranscribing = true
        currentTranscriptionId = task.recordingId
        transcriptionQueue.removeFirst()
        pendingTranscriptionURLs.removeValue(forKey: task.recordingId)

        FileLogger.shared.debug("[ProcessingQueue] Starting transcription for recording \(task.recordingId)")
        logger.info("Starting transcription for recording \(task.recordingId)")

        // Execute transcription (handler should post notifications)
        await handler(task.recordingId, audioURL)

        FileLogger.shared.debug("[ProcessingQueue] Completed transcription for recording \(task.recordingId)")
        logger.info("Completed transcription for recording \(task.recordingId)")

        isTranscribing = false
        currentTranscriptionId = nil

        // Notify UI of completion
        notifyQueueStatusChanged()

        // Process next task if any
        await processTranscriptionQueue()
    }

    private func processAIGenerationQueue() async {
        // Prevent concurrent processing
        guard !isGenerating else { return }
        guard let task = aiGenerationQueue.first else { return }
        guard let handler = aiGenerationHandler else {
            logger.warning("No AI generation handler set")
            return
        }

        isGenerating = true
        currentAIGenerationId = task.recordingId
        aiGenerationQueue.removeFirst()

        logger.info("Starting AI generation for recording \(task.recordingId)")

        // Execute AI generation (handler should post notifications)
        await handler(task.recordingId)

        logger.info("Completed AI generation for recording \(task.recordingId)")

        isGenerating = false
        currentAIGenerationId = nil

        // Notify UI of completion
        notifyQueueStatusChanged()

        // Process next task if any
        await processAIGenerationQueue()
    }
}
