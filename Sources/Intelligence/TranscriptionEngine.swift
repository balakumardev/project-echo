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
    
    public enum Speaker: Sendable, Equatable, Hashable {
        case user                    // Microphone track (always "You")
        case remote(Int)             // Remote participant from system audio (Speaker 1, 2, etc.)
        case unknown                 // Fallback when diarization unavailable

        public var displayName: String {
            switch self {
            case .user:
                return "You"
            case .remote(let id):
                return "Speaker \(id + 1)"  // 1-indexed for display
            case .unknown:
                return "Unknown"
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

    // Diarization components (lazy-initialized)
    private var diarizationEngine: SpeakerDiarizationEngine?
    private var trackExtractor: AudioTrackExtractor?

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

        // Step 1: Run diarization if enabled (extract tracks, identify speakers)
        var diarizationResult: SpeakerDiarizationEngine.DiarizationResult?
        if enableDiarization {
            diarizationResult = await runDiarization(for: audioURL)
        }

        // Step 2: Transcribe with WhisperKit
        let results = try await kit.transcribe(audioPath: audioURL.path)

        guard let firstResult = results.first else {
            throw TranscriptionError.transcriptionFailed
        }

        // Step 3: Build segments with speaker identification
        var segments: [Segment] = []

        for segment in firstResult.segments {
            let cleanedText = cleanWhisperTokens(segment.text)

            // Skip empty segments after cleaning
            guard !cleanedText.isEmpty else { continue }

            let segmentStart = TimeInterval(segment.start)
            let segmentEnd = TimeInterval(segment.end)

            // Identify speaker from diarization result
            let speaker: Speaker
            if let diarization = diarizationResult {
                speaker = identifySpeakerFromDiarization(
                    start: segmentStart,
                    end: segmentEnd,
                    diarization: diarization
                )
            } else {
                speaker = .unknown
            }

            let echoSegment = Segment(
                start: segmentStart,
                end: segmentEnd,
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
    
    /// Run speaker diarization on the audio file
    /// Extracts dual tracks (mic + system audio) and identifies speakers
    private func runDiarization(for audioURL: URL) async -> SpeakerDiarizationEngine.DiarizationResult? {
        // Initialize components lazily
        if trackExtractor == nil {
            trackExtractor = AudioTrackExtractor()
        }
        if diarizationEngine == nil {
            diarizationEngine = SpeakerDiarizationEngine()
        }

        guard let extractor = trackExtractor, let diarizer = diarizationEngine else {
            return nil
        }

        do {
            // Extract separate audio tracks from the recording
            logger.info("Extracting audio tracks for diarization...")
            let tracks = try await extractor.extractTracks(from: audioURL)

            defer {
                // Cleanup temp files after diarization
                Task {
                    await extractor.cleanup(tracks: tracks)
                }
            }

            // Run diarization on both tracks
            logger.info("Running speaker diarization...")
            let result = try await diarizer.processDualTrack(
                microphoneURL: tracks.microphoneURL,
                systemAudioURL: tracks.systemAudioURL
            )

            logger.info("Diarization complete: \(result.segments.count) segments, \(result.remoteSpeakerCount) remote speakers")
            return result

        } catch {
            logger.warning("Diarization failed, falling back to unknown speakers: \(error.localizedDescription)")
            return nil
        }
    }

    /// Match a transcription segment to the best diarization segment by time overlap
    private func identifySpeakerFromDiarization(
        start: TimeInterval,
        end: TimeInterval,
        diarization: SpeakerDiarizationEngine.DiarizationResult
    ) -> Speaker {
        // Find the diarization segment with the most overlap
        var bestMatch: (overlap: TimeInterval, segment: SpeakerDiarizationEngine.DiarizationSegment)?

        for diarizationSegment in diarization.segments {
            let overlapStart = max(start, diarizationSegment.start)
            let overlapEnd = min(end, diarizationSegment.end)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > 0 {
                if bestMatch == nil || overlap > bestMatch!.overlap {
                    bestMatch = (overlap, diarizationSegment)
                }
            }
        }

        if let match = bestMatch {
            if match.segment.isUser {
                return .user
            } else {
                return .remote(match.segment.speakerIndex)
            }
        }

        return .unknown
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
