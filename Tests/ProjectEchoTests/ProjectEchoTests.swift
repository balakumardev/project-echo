import XCTest
@testable import AudioEngine
@testable import Intelligence
@testable import Database

@available(macOS 14.0, *)
final class ProjectEchoTests: XCTestCase {
    
    // MARK: - Audio Engine Tests
    
    func testAudioEngineInitialization() async throws {
        let engine = AudioCaptureEngine()
        XCTAssertNotNil(engine)
    }
    
    func testPermissionRequest() async throws {
        let engine = AudioCaptureEngine()
        
        // Note: This will fail in CI without permissions
        // Manual testing required
        do {
            try await engine.requestPermissions()
            XCTAssert(true, "Permissions granted")
        } catch {
            XCTAssertTrue(error is AudioCaptureEngine.CaptureError)
        }
    }
    
    // MARK: - Database Tests
    
    func testDatabaseInitialization() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).db")
        
        let db = try await DatabaseManager(databasePath: tempDB.path)
        XCTAssertNotNil(db)
    }
    
    func testRecordingSave() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).db")
        
        let db = try await DatabaseManager(databasePath: tempDB.path)
        
        let recordingId = try await db.saveRecording(
            title: "Test Recording",
            date: Date(),
            duration: 60.0,
            fileURL: URL(fileURLWithPath: "/tmp/test.mov"),
            fileSize: 1024,
            appName: "Zoom"
        )
        
        XCTAssertGreaterThan(recordingId, 0)
        
        let recording = try await db.getRecording(id: recordingId)
        XCTAssertEqual(recording.title, "Test Recording")
        XCTAssertEqual(recording.duration, 60.0)
    }
    
    func testTranscriptSearch() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).db")
        
        let db = try await DatabaseManager(databasePath: tempDB.path)
        
        // Create recording
        let recordingId = try await db.saveRecording(
            title: "Meeting Recording",
            date: Date(),
            duration: 120.0,
            fileURL: URL(fileURLWithPath: "/tmp/meeting.mov"),
            fileSize: 2048,
            appName: "Teams"
        )
        
        // Save transcript
        let segment = DatabaseManager.TranscriptSegment(
            id: 0,
            transcriptId: 0,
            startTime: 0,
            endTime: 10,
            text: "This is a test transcript about project planning",
            speaker: "John",
            confidence: 0.95
        )
        
        _ = try await db.saveTranscript(
            recordingId: recordingId,
            fullText: "This is a test transcript about project planning",
            language: "en",
            processingTime: 5.0,
            segments: [segment]
        )
        
        // Search
        let results = try await db.searchTranscripts(query: "project")
        XCTAssertGreaterThan(results.count, 0)
    }
    
    // MARK: - Transcription Tests
    
    func testTranscriptionEngineInitialization() async throws {
        let engine = TranscriptionEngine()
        XCTAssertNotNil(engine)
    }
    
    // Note: Model loading tests require actual Whisper models
    // and should be run manually with proper setup
}
