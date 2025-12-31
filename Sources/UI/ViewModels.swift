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
    
    private let database: DatabaseManager
    
    init() {
        // Initialize database
        database = try! DatabaseManager()
    }
    
    func loadRecordings() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            recordings = try await database.getAllRecordings()
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
            recordings = try await database.searchTranscripts(query: query)
        } catch {
            print("Search failed: \(error)")
        }
    }
    
    func deleteRecording(_ recording: Recording) async {
        do {
            try await database.deleteRecording(id: recording.id)
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
        try? await database.getTranscript(forRecording: recording.id)
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
    
    private let database: DatabaseManager
    private let transcriptionEngine: TranscriptionEngine
    
    init() {
        database = try! DatabaseManager()
        transcriptionEngine = TranscriptionEngine()
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
            transcript = try await database.getTranscript(forRecording: recording.id)
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
            
            let transcriptId = try await database.saveTranscript(
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
