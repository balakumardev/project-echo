import Foundation
import WhisperKit
@preconcurrency import AVFoundation
import os.log

/// Handles transcription using WhisperKit (CoreML Whisper) and speaker diarization
@available(macOS 14.0, *)
public actor TranscriptionEngine {
    
    // MARK: - Types
    
    public struct TranscriptionResult: Sendable {
        public let text: String
        public let segments: [Segment]
        public let language: String?
        public let processingTime: TimeInterval
        
        public init(text: String, segments: [Segment], language: String?, processingTime: TimeInterval) {
            self.text = text
            self.segments = segments
            self.language = language
            self.processingTime = processingTime
        }
    }
    
    public struct Segment: Sendable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
        public let speaker: Speaker
        public let confidence: Float
        
        public init(start: TimeInterval, end: TimeInterval, text: String, speaker: Speaker, confidence: Float) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
            self.confidence = confidence
        }
    }
    
    public enum Speaker: Sendable {
        case user
        case system
        case unknown(Int) // For multi-speaker scenarios
        
        public var displayName: String {
            switch self {
            case .user: return "You"
            case .system: return "Guest"
            case .unknown(let id): return "Speaker \(id)"
            }
        }
    }
    
    public enum TranscriptionError: Error {
        case modelNotLoaded
        case audioConversionFailed
        case transcriptionFailed
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.projectecho.app", category: "Transcription")
    nonisolated(unsafe) private var whisperKit: WhisperKit?
    private var isModelLoaded = false
    
    // Configuration
    private let modelVariant: String = "base.en" // Can be: tiny, base, small, medium, large
    
    // MARK: - Initialization
    
    public init() {}
       
    // MARK: - Model Management
    
    /// Load the Whisper model (call once at app startup)
    public func loadModel() async throws {
        guard !isModelLoaded else { return }
        
        logger.info("Loading Whisper model: \(self.modelVariant)")
        let startTime = Date()
        
        whisperKit = try await WhisperKit(model: modelVariant)
        
        isModelLoaded = true
        let loadTime = Date().timeIntervalSince(startTime)
        logger.info("Whisper model loaded in \(loadTime)s")
    }
    
    /// Unload model to free memory
    public func unloadModel() {
        whisperKit = nil
        isModelLoaded = false
        logger.info("Whisper model unloaded")
    }
    
    // MARK: - Transcription
    
    /// Transcribe an audio file with speaker diarization
    public func transcribe(audioURL: URL, enableDiarization: Bool = true) async throws -> TranscriptionResult {
        guard isModelLoaded, let kit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }
        
        logger.info("Starting transcription: \(audioURL.lastPathComponent)")
        let startTime = Date()
        
        // Transcribe - returns array of results
        let results = try await kit.transcribe(audioPath: audioURL.path)
        
        guard let firstResult = results.first else {
            throw TranscriptionError.transcriptionFailed
        }
        
        // Build segments with speaker identification
        var segments: [Segment] = []
        
        for (index, segment) in firstResult.segments.enumerated() {
            let speaker: Speaker = enableDiarization 
                ? identifySpeaker(segmentIndex: index, totalSegments: firstResult.segments.count)
                : .unknown(0)
            
            let cleanedText = cleanWhisperTokens(segment.text)

            // Skip empty segments after cleaning
            guard !cleanedText.isEmpty else { continue }

            let echoSegment = Segment(
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end),
                text: cleanedText,
                speaker: speaker,
                confidence: Float(segment.avgLogprob)
            )
            segments.append(echoSegment)
        }

        let fullText = segments.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let processingTime = Date().timeIntervalSince(startTime)
        
        logger.info("Transcription complete: \(segments.count) segments in \(processingTime)s")
        
        return TranscriptionResult(
            text: fullText,
            segments: segments,
            language: firstResult.language,
            processingTime: processingTime
        )
    }
    
    /// Generate summary and action items from transcript
    public func generateSummary(transcript: TranscriptionResult) async -> Summary {
        // TODO: Integrate with local LLM or cloud API for summarization
        // For now, extract simple patterns
        
        let actionItems = extractActionItems(from: transcript.text)
        let keyTopics = extractKeyTopics(from: transcript.text)
        
        return Summary(
            mainPoints: ["Meeting discussion captured - \(transcript.segments.count) segments"],
            actionItems: actionItems,
            keyTopics: keyTopics,
            duration: transcript.segments.last?.end ?? 0
        )
    }
    
    // MARK: - Private Helpers
    
    private func prepareAudioData(from url: URL) async throws -> Data {
        // Whisper expects 16kHz mono PCM
        let asset = AVAsset(url: url)
        
        // Verify audio track exists
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw TranscriptionError.audioConversionFailed
        }
        
        // WhisperKit handles conversion internally when using transcribe(audioPath:)
        // This is a placeholder for explicit data handling if needed
        
        return Data()
    }
    
    /// Simple speaker identification based on track separation
    /// Assumes Track 1 = System (other party), Track 2 = User (microphone)
    private func identifySpeaker(segmentIndex: Int, totalSegments: Int) -> Speaker {
        // Simplified logic: alternate between speakers
        // In production, use audio embeddings and clustering
        return segmentIndex % 2 == 0 ? .system : .user
    }
    
    /// Extract action items using keyword matching
    private func extractActionItems(from text: String) -> [String] {
        let keywords = ["action item", "todo", "follow up", "need to", "will do", "task"]
        var items: [String] = []
        
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        for sentence in sentences {
            if keywords.contains(where: { sentence.lowercased().contains($0) }) {
                items.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        
        return items
    }
    
    /// Extract key topics (placeholder - would use NLP in production)
    private func extractKeyTopics(from text: String) -> [String] {
        // Simple word frequency analysis
        let words = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 5 } // Ignore short words

        let frequencies = Dictionary(grouping: words, by: { $0 }).mapValues { $0.count }
        let topWords = frequencies.sorted { $0.value > $1.value }.prefix(5).map { $0.key }

        return Array(topWords)
    }

    /// Clean WhisperKit special tokens from transcript text
    /// Removes tokens like <|startoftranscript|>, <|0.00|>, <|endoftext|>, etc.
    private func cleanWhisperTokens(_ text: String) -> String {
        var cleaned = text

        // Remove special tokens with regex pattern: <|anything|>
        // This handles: <|startoftranscript|>, <|endoftext|>, <|notimestamps|>,
        // <|transcribe|>, <|translate|>, <|en|>, <|0.00|>, etc.
        if let regex = try? NSRegularExpression(pattern: "<\\|[^|]*\\|>", options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Also remove [BLANK_AUDIO] markers
        cleaned = cleaned.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")

        // Clean up multiple spaces and trim
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Supporting Types

public struct Summary: Sendable {
    public let mainPoints: [String]
    public let actionItems: [String]
    public let keyTopics: [String]
    public let duration: TimeInterval
    
    public init(mainPoints: [String], actionItems: [String], keyTopics: [String], duration: TimeInterval) {
        self.mainPoints = mainPoints
        self.actionItems = actionItems
        self.keyTopics = keyTopics
        self.duration = duration
    }
}
