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
        case configurationError(String)
        case geminiError(String)
    }
    
    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "Transcription")
    nonisolated(unsafe) private var whisperKit: WhisperKit?
    private var isModelLoaded = false

    // Transcription configuration
    private var config: TranscriptionConfig

    // Gemini cloud transcriber (lazy-initialized)
    private var geminiTranscriber: GeminiTranscriber?

    // Diarization components (lazy-initialized)
    private var diarizationEngine: SpeakerDiarizationEngine?
    private var trackExtractor: AudioTrackExtractor?

    // Configuration - using small.en for better accuracy (medium is even better but slower)
    // Available variants: tiny, base, small, medium, large (larger = more accurate but slower)
    // .en suffix = English-only (faster), without suffix = multilingual
    private var modelVariant: String {
        // User can override via settings, default to small.en for good balance
        UserDefaults.standard.string(forKey: "whisperModel") ?? "small.en"
    }

    // Decoding options for better accuracy
    private var decodingOptions: DecodingOptions {
        var options = DecodingOptions()
        // Enable word timestamps for better segmentation
        options.wordTimestamps = true
        // Use suppression tokens to reduce hallucination
        options.suppressBlank = true
        // Temperature 0 for most deterministic output
        options.temperature = 0.0
        // Beam search for better accuracy (1 = greedy, higher = slower but more accurate)
        options.sampleLength = 224
        // Suppress common hallucination patterns
        options.noSpeechThreshold = 0.6
        // Use VAD (Voice Activity Detection) to skip silence
        options.usePrefillPrompt = true
        return options
    }

    // MARK: - Initialization

    public init() {
        self.config = TranscriptionConfig.load()
    }

    // MARK: - Configuration

    /// Get the current transcription configuration
    public var currentConfig: TranscriptionConfig {
        config
    }

    /// Update the transcription configuration
    public func setConfig(_ newConfig: TranscriptionConfig) {
        config = newConfig
        config.save()
        logger.info("Transcription config updated: provider=\(newConfig.provider.rawValue)")
    }

    /// Set the transcription provider
    public func setProvider(_ provider: TranscriptionProvider) {
        config.provider = provider
        config.save()
        logger.info("Transcription provider set to: \(provider.rawValue)")
    }

    /// Configure Gemini settings
    public func configureGemini(apiKey: String, model: GeminiModel = .gemini3Flash) {
        config.geminiAPIKey = apiKey
        config.geminiModel = model
        config.save()
        logger.info("Gemini configured: model=\(model.rawValue)")
    }

    /// Check if Gemini is properly configured
    public var isGeminiConfigured: Bool {
        !config.geminiAPIKey.isEmpty
    }
       
    // MARK: - Model Management

    /// Load the Whisper model (call once at app startup)
    public func loadModel() async throws {
        guard !isModelLoaded else {
            fileDebugLog("[TranscriptionEngine] Model already loaded, skipping")
            return
        }

        fileDebugLog("[TranscriptionEngine] Loading Whisper model: \(self.modelVariant)")
        logger.info("Loading Whisper model: \(self.modelVariant)")
        let startTime = Date()

        whisperKit = try await WhisperKit(model: modelVariant)

        isModelLoaded = true
        let loadTime = Date().timeIntervalSince(startTime)
        fileDebugLog("[TranscriptionEngine] Whisper model loaded in \(String(format: "%.1f", loadTime))s")
        logger.info("Whisper model loaded in \(loadTime)s")
    }

    /// Unload model to free memory
    public func unloadModel() {
        whisperKit = nil
        isModelLoaded = false
        fileDebugLog("[TranscriptionEngine] Whisper model unloaded")
        logger.info("Whisper model unloaded")
    }

    /// Reload the model with current settings (call when user changes model in settings)
    public func reloadModel() async throws {
        fileDebugLog("[TranscriptionEngine] Reloading Whisper model...")
        logger.info("Reloading Whisper model...")
        unloadModel()
        try await loadModel()
    }

    /// Get the currently configured model variant
    public var currentModelVariant: String {
        modelVariant
    }

    /// Check if the model is ready for transcription
    public var isReady: Bool {
        isModelLoaded && whisperKit != nil
    }
    
    // MARK: - Transcription

    /// Transcribe an audio file with speaker diarization
    /// - Parameters:
    ///   - audioURL: URL to the audio file to transcribe
    ///   - enableDiarization: Whether to run speaker diarization (default: true, ignored for Gemini)
    ///   - diarizationOptions: Options for speaker diarization (default: .meetings for optimal accuracy)
    public func transcribe(
        audioURL: URL,
        enableDiarization: Bool = true,
        diarizationOptions: SpeakerDiarizationEngine.DiarizationOptions = .meetings
    ) async throws -> TranscriptionResult {
        fileDebugLog("[TranscriptionEngine] transcribe called: provider=\(config.provider.rawValue), file=\(audioURL.lastPathComponent)")

        // Route to appropriate provider
        switch config.provider {
        case .local:
            // Auto-load model if not loaded (handles startup race conditions and recovery from failures)
            if !isModelLoaded || whisperKit == nil {
                fileDebugLog("[TranscriptionEngine] Model not loaded, attempting auto-load...")
                do {
                    try await loadModel()
                } catch {
                    fileDebugLog("[TranscriptionEngine] Auto-load FAILED: \(error.localizedDescription)")
                    throw TranscriptionError.modelNotLoaded
                }
            }
            return try await transcribeWithWhisperKit(
                audioURL: audioURL,
                enableDiarization: enableDiarization,
                diarizationOptions: diarizationOptions
            )
        case .gemini:
            return try await transcribeWithGemini(audioURL: audioURL)
        }
    }

    /// Transcribe using Gemini cloud API
    private func transcribeWithGemini(audioURL: URL) async throws -> TranscriptionResult {
        guard !config.geminiAPIKey.isEmpty else {
            fileDebugLog("[TranscriptionEngine] Gemini API key is not configured")
            throw TranscriptionError.configurationError("Gemini API key is not configured")
        }

        fileDebugLog("[TranscriptionEngine] Starting Gemini transcription: \(audioURL.lastPathComponent), model: \(config.geminiModel.rawValue)")
        logger.info("Starting Gemini transcription: \(audioURL.lastPathComponent)")
        let startTime = Date()

        // Initialize Gemini transcriber if needed
        if geminiTranscriber == nil {
            geminiTranscriber = GeminiTranscriber()
        }

        guard let transcriber = geminiTranscriber else {
            fileDebugLog("[TranscriptionEngine] Failed to initialize GeminiTranscriber")
            throw TranscriptionError.transcriptionFailed
        }

        do {
            let geminiSegments = try await transcriber.transcribe(
                audioURL: audioURL,
                apiKey: config.geminiAPIKey,
                model: config.geminiModel
            )

            // Convert Gemini segments to engine segments
            let segments = geminiSegments.map { $0.toEngineSegment() }
            let fullText = segments.map { $0.text }.joined(separator: " ")
            let processingTime = Date().timeIntervalSince(startTime)

            fileDebugLog("[TranscriptionEngine] Gemini transcription complete: \(segments.count) segments in \(String(format: "%.1f", processingTime))s")
            logger.info("Gemini transcription complete: \(segments.count) segments in \(processingTime)s")

            return TranscriptionResult(
                text: fullText,
                segments: segments,
                language: "en", // Gemini doesn't return language, assume English
                processingTime: processingTime
            )
        } catch let error as GeminiTranscriber.GeminiError {
            fileDebugLog("[TranscriptionEngine] Gemini error: \(error.localizedDescription)")
            throw TranscriptionError.geminiError(error.localizedDescription)
        } catch {
            fileDebugLog("[TranscriptionEngine] Gemini unexpected error: \(error.localizedDescription)")
            throw TranscriptionError.geminiError(error.localizedDescription)
        }
    }

    /// Transcribe using local WhisperKit
    private func transcribeWithWhisperKit(
        audioURL: URL,
        enableDiarization: Bool,
        diarizationOptions: SpeakerDiarizationEngine.DiarizationOptions
    ) async throws -> TranscriptionResult {
        guard isModelLoaded, let kit = whisperKit else {
            fileDebugLog("[TranscriptionEngine] WhisperKit model not loaded! isModelLoaded=\(isModelLoaded), whisperKit=\(whisperKit == nil ? "nil" : "set")")
            throw TranscriptionError.modelNotLoaded
        }

        fileDebugLog("[TranscriptionEngine] Starting WhisperKit transcription: \(audioURL.lastPathComponent), model: \(modelVariant)")
        logger.info("Starting WhisperKit transcription: \(audioURL.lastPathComponent)")
        let startTime = Date()

        // Step 1: Extract and mix audio tracks (mic + system audio)
        // This ensures we transcribe BOTH the user's voice AND remote participants
        var diarizationResult: SpeakerDiarizationEngine.DiarizationResult?
        var extractedTracks: AudioTrackExtractor.ExtractedTracks?
        var audioPathForTranscription = audioURL.path

        if enableDiarization {
            // Extract tracks and get mixed audio + diarization with optimized options
            let (tracks, diarization) = await extractTracksAndRunDiarization(
                for: audioURL,
                options: diarizationOptions
            )
            extractedTracks = tracks
            diarizationResult = diarization

            // Use mixed audio for transcription (contains both mic + system audio)
            if let mixedURL = tracks?.mixedURL {
                audioPathForTranscription = mixedURL.path
                logger.info("Using mixed audio for transcription: \(mixedURL.lastPathComponent)")
            }
        }

        // Cleanup tracks after transcription
        defer {
            if let tracks = extractedTracks {
                Task {
                    if trackExtractor == nil {
                        trackExtractor = AudioTrackExtractor()
                    }
                    await trackExtractor?.cleanup(tracks: tracks)
                }
            }
        }

        // Step 2: Transcribe with WhisperKit using mixed audio and optimized decoding options
        let options = self.decodingOptions
        let model = self.modelVariant
        logger.info("Transcribing with model: \(model), options: wordTimestamps=\(options.wordTimestamps)")
        let results = try await kit.transcribe(
            audioPath: audioPathForTranscription,
            decodeOptions: options
        )

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
    
    /// Extract audio tracks and run speaker diarization with optimized configuration
    /// Returns both the extracted tracks (for mixed audio transcription) and diarization result
    /// - Parameters:
    ///   - audioURL: URL to the audio file
    ///   - options: Diarization options for speaker detection accuracy
    private func extractTracksAndRunDiarization(
        for audioURL: URL,
        options: SpeakerDiarizationEngine.DiarizationOptions = .meetings
    ) async -> (AudioTrackExtractor.ExtractedTracks?, SpeakerDiarizationEngine.DiarizationResult?) {
        // Initialize components lazily
        if trackExtractor == nil {
            trackExtractor = AudioTrackExtractor()
        }
        if diarizationEngine == nil {
            diarizationEngine = SpeakerDiarizationEngine()
        }

        guard let extractor = trackExtractor, let diarizer = diarizationEngine else {
            return (nil, nil)
        }

        do {
            // Load diarization models with optimized configuration
            try await diarizer.loadModels(options: options)

            // Extract separate audio tracks from the recording (includes mixed audio)
            logger.info("Extracting audio tracks for diarization and transcription...")
            let tracks = try await extractor.extractTracks(from: audioURL)

            // Run diarization on both tracks
            logger.info("Running speaker diarization with optimized config (threshold: \(options.clusteringThreshold))...")
            let result = try await diarizer.processDualTrack(
                microphoneURL: tracks.microphoneURL,
                systemAudioURL: tracks.systemAudioURL
            )

            logger.info("Diarization complete: \(result.segments.count) segments, \(result.remoteSpeakerCount) remote speakers")

            // Return tracks (for cleanup later) and diarization result
            // Note: cleanup is handled by the caller (transcribe method)
            return (tracks, result)

        } catch {
            logger.warning("Track extraction/diarization failed: \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    /// Run speaker diarization on the audio file (legacy method for compatibility)
    /// Extracts dual tracks (mic + system audio) and identifies speakers
    private func runDiarization(for audioURL: URL) async -> SpeakerDiarizationEngine.DiarizationResult? {
        let (_, result) = await extractTracksAndRunDiarization(for: audioURL)
        return result
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
