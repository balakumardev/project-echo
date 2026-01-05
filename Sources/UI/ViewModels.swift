import Foundation
import SwiftUI
import AVFoundation
import Database
import Intelligence
import Combine

// MARK: - Recording Notifications

/// Notification names for reactive UI updates
public extension Notification.Name {
    /// Posted when a new recording is saved to the database
    /// userInfo: ["recordingId": Int64]
    static let recordingDidSave = Notification.Name("Engram.recordingDidSave")

    /// Posted when a recording is deleted
    /// userInfo: ["recordingId": Int64]
    static let recordingDidDelete = Notification.Name("Engram.recordingDidDelete")

    /// Posted when recording content is updated (transcript, summary, action items)
    /// userInfo: ["recordingId": Int64, "type": String] where type is "transcript", "summary", or "actionItems"
    static let recordingContentDidUpdate = Notification.Name("Engram.recordingContentDidUpdate")
}

// MARK: - Library View Model

@MainActor
@available(macOS 14.0, *)
class LibraryViewModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var isLoading = false

    private var database: DatabaseManager?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // DatabaseManager will be initialized lazily in async context
        setupNotificationObservers()
    }

    private func setupNotificationObservers() {
        // Observe recording saved notifications
        NotificationCenter.default.publisher(for: .recordingDidSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadRecordings()
                }
            }
            .store(in: &cancellables)

        // Observe recording deleted notifications
        NotificationCenter.default.publisher(for: .recordingDidDelete)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadRecordings()
                }
            }
            .store(in: &cancellables)

        // Observe recording content updates (transcript, summary, action items)
        // This updates the list to reflect new hasTranscript status or other metadata changes
        NotificationCenter.default.publisher(for: .recordingContentDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadRecordings()
                }
            }
            .store(in: &cancellables)
    }
    
    private func getDatabase() async throws -> DatabaseManager {
        if let db = database {
            return db
        }
        let db = try await DatabaseManager()
        database = db
        return db
    }
    
    func loadRecordings() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let db = try await getDatabase()
            recordings = try await db.getAllRecordings()
        } catch {
            print("Failed to load recordings: \(error)")
        }
    }
    
    func search(query: String) async {
        guard !query.isEmpty else {
            await loadRecordings()
            return
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let db = try await getDatabase()
            recordings = try await db.searchTranscripts(query: query)
        } catch {
            print("Search failed: \(error)")
        }
    }
    
    func deleteRecording(_ recording: Recording) async {
        do {
            let db = try await getDatabase()
            try await db.deleteRecording(id: recording.id)
            // Delete file
            try? FileManager.default.removeItem(at: recording.fileURL)
            await loadRecordings()
        } catch {
            print("Failed to delete recording: \(error)")
        }
    }
    
    func refresh() async {
        await loadRecordings()
    }
    
    func getTranscript(for recording: Recording) async -> Transcript? {
        guard let db = try? await getDatabase() else { return nil }
        return try? await db.getTranscript(forRecording: recording.id)
    }

    func toggleFavorite(for recording: Recording) async {
        do {
            let db = try await getDatabase()
            _ = try await db.toggleFavorite(id: recording.id)
            await loadRecordings()
        } catch {
            print("Failed to toggle favorite: \(error)")
        }
    }
}

// MARK: - Recording Detail View Model

@MainActor
@available(macOS 14.0, *)
class RecordingDetailViewModel: ObservableObject {
    @Published var transcript: Transcript?
    @Published var segments: [TranscriptSegment] = []
    @Published var isLoadingTranscript = false
    @Published var audioPlayer: AVAudioPlayer?

    // Summary state
    @Published var summary: String?
    @Published var isLoadingSummary = false
    @Published var summaryError: String?

    // Action items state
    @Published var actionItems: String?
    @Published var isLoadingActionItems = false
    @Published var actionItemsError: String?

    private var database: DatabaseManager?
    private let transcriptionEngine: TranscriptionEngine
    private var summaryTask: Task<Void, Never>?
    private var actionItemsTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var currentRecordingId: Int64?

    init() {
        transcriptionEngine = TranscriptionEngine()
        setupNotificationObservers()
    }

    private func setupNotificationObservers() {
        // Observe recording content updates
        NotificationCenter.default.publisher(for: .recordingContentDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let userInfo = notification.userInfo,
                      let recordingId = userInfo["recordingId"] as? Int64,
                      recordingId == self.currentRecordingId else {
                    return
                }

                // Reload the content for the current recording
                Task { @MainActor [weak self] in
                    guard let self = self, let recordingId = self.currentRecordingId else { return }
                    await self.reloadRecordingContent(recordingId: recordingId)
                }
            }
            .store(in: &cancellables)
    }

    /// Reload summary, action items, and transcript for the current recording
    private func reloadRecordingContent(recordingId: Int64) async {
        do {
            let db = try await getDatabase()
            let freshRecording = try await db.getRecording(id: recordingId)

            // Update summary if not currently loading
            if !isLoadingSummary, let persistedSummary = freshRecording.summary, !persistedSummary.isEmpty {
                self.summary = persistedSummary
            }

            // Update action items if not currently loading
            if !isLoadingActionItems, let persistedActionItems = freshRecording.actionItems, !persistedActionItems.isEmpty {
                self.actionItems = persistedActionItems
            }

            // Reload transcript if not currently loading
            if !isLoadingTranscript && freshRecording.hasTranscript {
                if let loadedTranscript = try await db.getTranscript(forRecording: recordingId) {
                    let cleanedTranscript = Transcript(
                        id: loadedTranscript.id,
                        recordingId: loadedTranscript.recordingId,
                        fullText: cleanWhisperTokens(loadedTranscript.fullText),
                        language: loadedTranscript.language,
                        processingTime: loadedTranscript.processingTime,
                        createdAt: loadedTranscript.createdAt
                    )
                    self.transcript = cleanedTranscript

                    let loadedSegments = try await db.getSegments(forTranscriptId: loadedTranscript.id)
                    self.segments = loadedSegments.map { segment in
                        TranscriptSegment(
                            id: segment.id,
                            transcriptId: segment.transcriptId,
                            startTime: segment.startTime,
                            endTime: segment.endTime,
                            text: cleanWhisperTokens(segment.text),
                            speaker: segment.speaker,
                            confidence: segment.confidence
                        )
                    }.filter { !$0.text.isEmpty }
                }
            }
        } catch {
            print("Failed to reload recording content: \(error)")
        }
    }
    
    private func getDatabase() async throws -> DatabaseManager {
        if let db = database {
            return db
        }
        let db = try await DatabaseManager()
        database = db
        return db
    }

    /// Clean up AI response to remove thinking text, empty arrays, and other artifacts
    /// Returns nil if the cleaned result is empty or indicates no action items
    private func cleanActionItemsResponse(_ response: String) -> String? {
        // First, use ResponseProcessor to strip thinking patterns
        var cleaned = ResponseProcessor.stripThinkingPatterns(response)

        // Remove <think>...</think> blocks if present (should be handled by ResponseProcessor but just in case)
        let thinkBlockPattern = #"<think>[\s\S]*?</think>"#
        if let regex = try? NSRegularExpression(pattern: thinkBlockPattern, options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Remove standalone empty arrays "[]"
        cleaned = cleaned.replacingOccurrences(of: "[]", with: "")

        // Remove "No action items" type responses
        let noItemsPatterns = [
            #"(?i)no\s+(clear\s+)?action\s+items"#,
            #"(?i)no\s+action\s+items?\s+(were\s+)?found"#,
            #"(?i)there\s+are\s+no\s+(clear\s+)?action\s+items"#,
            #"(?i)i\s+(could\s+not|couldn't)\s+find\s+any\s+action\s+items"#
        ]
        for pattern in noItemsPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: cleaned, options: [], range: NSRange(cleaned.startIndex..., in: cleaned)) != nil {
                return nil // AI explicitly said no action items
            }
        }

        // Trim whitespace and newlines
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Return nil if empty
        return cleaned.isEmpty ? nil : cleaned
    }

    func loadRecording(_ recording: Recording) async {
        // Track current recording for notification filtering
        currentRecordingId = recording.id

        // Reset state for new recording
        audioPlayer?.stop()
        audioPlayer = nil
        transcript = nil
        segments = []

        // Reset summary state
        summaryTask?.cancel()
        summaryTask = nil
        summary = nil
        isLoadingSummary = false
        summaryError = nil

        // Reset action items state
        actionItemsTask?.cancel()
        actionItemsTask = nil
        actionItems = nil
        isLoadingActionItems = false
        actionItemsError = nil

        // Load persisted summary and action items from fresh database fetch
        // (the recording object passed in may have stale/cached values)
        do {
            let db = try await getDatabase()
            let freshRecording = try await db.getRecording(id: recording.id)
            if let persistedSummary = freshRecording.summary, !persistedSummary.isEmpty {
                summary = persistedSummary
            }
            if let persistedActionItems = freshRecording.actionItems, !persistedActionItems.isEmpty {
                actionItems = persistedActionItems
            }
        } catch {
            // Fallback to in-memory recording if database fetch fails
            if let persistedSummary = recording.summary, !persistedSummary.isEmpty {
                summary = persistedSummary
            }
            if let persistedActionItems = recording.actionItems, !persistedActionItems.isEmpty {
                actionItems = persistedActionItems
            }
        }

        // Setup audio player
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: recording.fileURL)
            audioPlayer?.prepareToPlay()
        } catch {
            print("Failed to setup audio player: \(error)")
        }

        // Always try to load transcript from database (the source of truth)
        // This handles cases where hasTranscript flag is stale (e.g., after background transcription)
        await loadTranscript(for: recording)
    }

    func setupAudioPlayer(for recording: Recording) async {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: recording.fileURL)
            audioPlayer?.prepareToPlay()
        } catch {
            print("Failed to setup audio player: \(error)")
        }
    }
    
    func loadTranscript(for recording: Recording) async {
        isLoadingTranscript = true
        defer { isLoadingTranscript = false }

        do {
            let db = try await getDatabase()
            if var loadedTranscript = try await db.getTranscript(forRecording: recording.id) {
                // Clean legacy transcripts that may have WhisperKit tokens
                loadedTranscript = Transcript(
                    id: loadedTranscript.id,
                    recordingId: loadedTranscript.recordingId,
                    fullText: cleanWhisperTokens(loadedTranscript.fullText),
                    language: loadedTranscript.language,
                    processingTime: loadedTranscript.processingTime,
                    createdAt: loadedTranscript.createdAt
                )
                transcript = loadedTranscript

                // Load segments
                let loadedSegments = try await db.getSegments(forTranscriptId: loadedTranscript.id)
                // Clean segment text as well
                segments = loadedSegments.map { segment in
                    TranscriptSegment(
                        id: segment.id,
                        transcriptId: segment.transcriptId,
                        startTime: segment.startTime,
                        endTime: segment.endTime,
                        text: cleanWhisperTokens(segment.text),
                        speaker: segment.speaker,
                        confidence: segment.confidence
                    )
                }.filter { !$0.text.isEmpty }
            }
        } catch {
            print("Failed to load transcript: \(error)")
        }
    }

    /// Clean WhisperKit special tokens from text
    private func cleanWhisperTokens(_ text: String) -> String {
        var cleaned = text

        // Remove special tokens: <|anything|>
        if let regex = try? NSRegularExpression(pattern: "<\\|[^|]*\\|>", options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Remove [BLANK_AUDIO] markers
        cleaned = cleaned.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")

        // Clean up multiple spaces
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func generateTranscript(for recording: Recording) async {
        isLoadingTranscript = true
        defer { isLoadingTranscript = false }

        do {
            // Load model if needed
            try await transcriptionEngine.loadModel()

            // Transcribe
            let result = try await transcriptionEngine.transcribe(audioURL: recording.fileURL)

            // Save to database
            let dbSegments = result.segments.map { segment in
                TranscriptSegment(
                    id: 0,
                    transcriptId: 0,
                    startTime: segment.start,
                    endTime: segment.end,
                    text: segment.text,
                    speaker: segment.speaker.displayName,
                    confidence: segment.confidence
                )
            }

            let db = try await getDatabase()
            let transcriptId = try await db.saveTranscript(
                recordingId: recording.id,
                fullText: result.text,
                language: result.language,
                processingTime: result.processingTime,
                segments: dbSegments
            )

            // Reload
            await loadTranscript(for: recording)

            // Notify UI that transcript is available
            NotificationCenter.default.post(
                name: .recordingContentDidUpdate,
                object: nil,
                userInfo: ["recordingId": recording.id, "type": "transcript"]
            )

            // Auto-index if enabled (defaults to true if not set)
            let autoIndex = UserDefaults.standard.object(forKey: "autoIndexTranscripts") as? Bool ?? true
            if autoIndex {
                await autoIndexTranscript(recording: recording, transcriptId: transcriptId)
            }
        } catch {
            print("Failed to generate transcript: \(error)")
        }
    }

    /// Automatically index a transcript for RAG search
    private func autoIndexTranscript(recording: Recording, transcriptId: Int64) async {
        do {
            let db = try await getDatabase()
            guard let transcript = try await db.getTranscript(forRecording: recording.id) else {
                print("No transcript found for recording \(recording.id), skipping indexing")
                return
            }
            let segments = try await db.getSegments(forTranscriptId: transcriptId)

            // Index using AIService
            try await AIService.shared.indexRecording(recording, transcript: transcript, segments: segments)
            print("Auto-indexed transcript for recording \(recording.id)")
        } catch {
            print("Auto-indexing failed for recording \(recording.id): \(error.localizedDescription)")
        }
    }

    /// Generate AI summary for the recording's transcript
    func generateSummary(for recording: Recording) {
        // Cancel any existing summary task
        summaryTask?.cancel()

        isLoadingSummary = true
        summary = nil
        summaryError = nil

        summaryTask = Task {
            do {
                // Use the agentic chat with a summarize request
                let stream = await AIService.shared.agentChat(
                    query: "Please provide a comprehensive summary of this meeting. Include the main topics discussed, key decisions made, and any action items mentioned.",
                    sessionId: "summary-\(recording.id)-\(Date().timeIntervalSince1970)",
                    recordingFilter: recording.id
                )

                var rawSummary = ""
                for try await token in stream {
                    guard !Task.isCancelled else { return }
                    rawSummary += token
                    // Clean thinking patterns and update in real-time for streaming effect
                    await MainActor.run {
                        self.summary = ResponseProcessor.stripThinkingPatterns(rawSummary)
                    }
                }

                // Final cleanup
                let cleanedSummary = ResponseProcessor.stripThinkingPatterns(rawSummary)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                await MainActor.run {
                    self.summary = cleanedSummary.isEmpty ? nil : cleanedSummary
                    self.isLoadingSummary = false
                }

                // Persist to database after streaming completes
                if !cleanedSummary.isEmpty {
                    do {
                        let db = try await self.getDatabase()
                        try await db.saveSummary(recordingId: recording.id, summary: cleanedSummary)

                        // Notify UI that summary is available (for other views like library list)
                        NotificationCenter.default.post(
                            name: .recordingContentDidUpdate,
                            object: nil,
                            userInfo: ["recordingId": recording.id, "type": "summary"]
                        )
                    } catch {
                        print("Failed to save summary: \(error)")
                    }
                }

            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.summaryError = error.localizedDescription
                    self.isLoadingSummary = false
                }
                print("Failed to generate summary: \(error)")
            }
        }
    }

    /// Generate AI action items for the recording's transcript
    func generateActionItems(for recording: Recording) {
        // Cancel any existing action items task
        actionItemsTask?.cancel()

        isLoadingActionItems = true
        actionItems = nil
        actionItemsError = nil

        actionItemsTask = Task {
            do {
                // Use the agentic chat with an action items extraction request
                let stream = await AIService.shared.agentChat(
                    query: """
                    Extract ONLY clear action items from this meeting. Be very strict - only include items you are at least 60% confident are real action items.

                    WHAT IS an action item:
                    - "I will send you the report by Friday" → Action item: Send report by Friday (Owner: speaker)
                    - "Can you review the proposal?" → Action item: Review the proposal (Owner: listener)
                    - "We need to schedule a follow-up meeting" → Action item: Schedule follow-up meeting

                    WHAT IS NOT an action item:
                    - General discussion or opinions
                    - Questions without clear tasks
                    - Past events or completed tasks
                    - Vague statements like "we should think about..."

                    OUTPUT FORMAT:
                    - Simple bullet list only
                    - One action per line
                    - Include owner if explicitly mentioned
                    - If NO clear action items exist, output NOTHING (empty response)
                    - Do NOT add headers, notes, or explanations
                    """,
                    sessionId: "actions-\(recording.id)-\(Date().timeIntervalSince1970)",
                    recordingFilter: recording.id
                )

                var fullActionItems = ""
                for try await token in stream {
                    guard !Task.isCancelled else { return }
                    fullActionItems += token
                    // Update the action items in real-time for streaming effect
                    // Clean the response during streaming to avoid showing garbage like "*Thinking...*"
                    await MainActor.run {
                        if let cleaned = self.cleanActionItemsResponse(fullActionItems) {
                            self.actionItems = cleaned
                        }
                        // Don't update if cleaned is nil (still thinking or no content yet)
                    }
                }

                // Clean up the final response
                let cleanedActionItems = self.cleanActionItemsResponse(fullActionItems)

                await MainActor.run {
                    self.isLoadingActionItems = false
                    // If no action items were found (or response was garbage), show a message
                    if cleanedActionItems == nil {
                        self.actionItems = nil
                        self.actionItemsError = "No action items found in this meeting."
                    } else {
                        self.actionItems = cleanedActionItems
                    }
                }

                // Persist to database after streaming completes (only if there are valid action items)
                if let cleanedActionItems = cleanedActionItems {
                    do {
                        let db = try await self.getDatabase()
                        try await db.saveActionItems(recordingId: recording.id, actionItems: cleanedActionItems)

                        // Notify UI that action items are available (for other views like library list)
                        NotificationCenter.default.post(
                            name: .recordingContentDidUpdate,
                            object: nil,
                            userInfo: ["recordingId": recording.id, "type": "actionItems"]
                        )
                    } catch {
                        print("Failed to save action items: \(error)")
                    }
                }

            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.actionItemsError = error.localizedDescription
                    self.isLoadingActionItems = false
                }
                print("Failed to generate action items: \(error)")
            }
        }
    }

    /// Cancel any ongoing summary generation
    func cancelSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        isLoadingSummary = false
    }

    /// Cancel any ongoing action items generation
    func cancelActionItems() {
        actionItemsTask?.cancel()
        actionItemsTask = nil
        isLoadingActionItems = false
    }

    func deleteRecording(_ recording: Recording) async {
        do {
            let db = try await getDatabase()

            // Delete from database
            try await db.deleteRecording(id: recording.id)

            // Delete the audio file from disk
            try? FileManager.default.removeItem(at: recording.fileURL)

            // Delete video file if exists
            // Video file pattern: audio filename + "_video.mov"
            let audioFileName = recording.fileURL.deletingPathExtension().lastPathComponent
            let videoFileName = audioFileName + "_video.mov"
            let videoURL = recording.fileURL.deletingLastPathComponent().appendingPathComponent(videoFileName)

            if FileManager.default.fileExists(atPath: videoURL.path) {
                try? FileManager.default.removeItem(at: videoURL)
            }
        } catch {
            print("Failed to delete recording: \(error)")
        }
    }
}

typealias Recording = DatabaseManager.Recording
typealias Transcript = DatabaseManager.Transcript
typealias TranscriptSegment = DatabaseManager.TranscriptSegment
