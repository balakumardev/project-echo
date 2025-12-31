import Foundation
import SwiftUI
import AVFoundation
import Database
import Intelligence

// MARK: - Library View Model

@MainActor
@available(macOS 14.0, *)
class LibraryViewModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var isLoading = false
    
    private var database: DatabaseManager?
    
    init() {
        // DatabaseManager will be initialized lazily in async context
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
}

// MARK: - Recording Detail View Model

@MainActor
@available(macOS 14.0, *)
class RecordingDetailViewModel: ObservableObject {
    @Published var transcript: Transcript?
    @Published var segments: [TranscriptSegment] = []
    @Published var isLoadingTranscript = false
    @Published var audioPlayer: AVAudioPlayer?
    
    private var database: DatabaseManager?
    private let transcriptionEngine: TranscriptionEngine
    
    init() {
        transcriptionEngine = TranscriptionEngine()
    }
    
    private func getDatabase() async throws -> DatabaseManager {
        if let db = database {
            return db
        }
        let db = try await DatabaseManager()
        database = db
        return db
    }
    
    func loadRecording(_ recording: Recording) async {
        // Reset state for new recording
        audioPlayer?.stop()
        audioPlayer = nil
        transcript = nil
        segments = []

        // Setup audio player
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: recording.fileURL)
            audioPlayer?.prepareToPlay()
        } catch {
            print("Failed to setup audio player: \(error)")
        }

        // Load transcript if available
        if recording.hasTranscript {
            await loadTranscript(for: recording)
        }
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
            transcript = try await db.getTranscript(forRecording: recording.id)
            // TODO: Load segments
        } catch {
            print("Failed to load transcript: \(error)")
        }
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
            _ = try await db.saveTranscript(
                recordingId: recording.id,
                fullText: result.text,
                language: result.language,
                processingTime: result.processingTime,
                segments: dbSegments
            )
            
            // Reload
            await loadTranscript(for: recording)
        } catch {
            print("Failed to generate transcript: \(error)")
        }
    }
}

typealias Recording = DatabaseManager.Recording
typealias Transcript = DatabaseManager.Transcript
typealias TranscriptSegment = DatabaseManager.TranscriptSegment
