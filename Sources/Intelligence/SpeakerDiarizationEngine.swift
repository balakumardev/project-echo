import Foundation
import FluidAudio
import os.log

/// Handles speaker diarization using FluidAudio's CoreML models
/// Processes dual-track audio: mic track (user) + system audio (remote participants)
@available(macOS 14.0, *)
public actor SpeakerDiarizationEngine {

    // MARK: - Types

    /// Configuration options for speaker diarization
    /// Optimized defaults based on FluidAudio benchmarks (17.7% DER on AMI dataset)
    public struct DiarizationOptions: Sendable {
        /// Clustering threshold (0.6-0.8). Higher = fewer speakers, lower = more speakers
        /// Optimal: 0.7 for most meetings (achieves 17.7% DER)
        public var clusteringThreshold: Double

        /// Minimum speech segment duration in seconds
        public var minDurationOn: Double

        /// Minimum silence between speakers in seconds
        public var minDurationOff: Double

        /// Expected speaker count (nil = auto-detect)
        public var expectedSpeakerCount: Int?

        /// Maximum speakers to detect (helps constrain clustering when auto-detecting)
        public var maxSpeakers: Int

        /// VAD threshold for microphone track (0.0-1.0, lower = more sensitive)
        public var vadThreshold: Float

        public init(
            clusteringThreshold: Double = 0.7,
            minDurationOn: Double = 0.5,
            minDurationOff: Double = 0.3,
            expectedSpeakerCount: Int? = nil,
            maxSpeakers: Int = 8,
            vadThreshold: Float = 0.7
        ) {
            self.clusteringThreshold = clusteringThreshold
            self.minDurationOn = minDurationOn
            self.minDurationOff = minDurationOff
            self.expectedSpeakerCount = expectedSpeakerCount
            self.maxSpeakers = maxSpeakers
            self.vadThreshold = vadThreshold
        }

        /// Default options - balanced for general use
        public static let `default` = DiarizationOptions()

        /// Optimized for typical meeting recordings (2-6 participants)
        public static let meetings = DiarizationOptions(
            clusteringThreshold: 0.7,
            minDurationOn: 0.5,
            minDurationOff: 0.3,
            expectedSpeakerCount: nil,
            maxSpeakers: 6,
            vadThreshold: 0.7
        )

        /// Optimized for 1:1 conversations
        public static let oneOnOne = DiarizationOptions(
            clusteringThreshold: 0.75,
            minDurationOn: 0.3,
            minDurationOff: 0.2,
            expectedSpeakerCount: 2,
            maxSpeakers: 2,
            vadThreshold: 0.65
        )

        /// Optimized for large meetings with many speakers
        public static let largeMeeting = DiarizationOptions(
            clusteringThreshold: 0.65,
            minDurationOn: 0.5,
            minDurationOff: 0.4,
            expectedSpeakerCount: nil,
            maxSpeakers: 12,
            vadThreshold: 0.7
        )
    }

    public struct DiarizationSegment: Sendable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let speakerLabel: String     // "SPEAKER_00", "SPEAKER_01", or "USER" for mic
        public let isUser: Bool             // true if from microphone track
        public let confidence: Float

        public init(start: TimeInterval, end: TimeInterval, speakerLabel: String, isUser: Bool, confidence: Float = 1.0) {
            self.start = start
            self.end = end
            self.speakerLabel = speakerLabel
            self.isUser = isUser
            self.confidence = confidence
        }

        /// Convert speaker label to display-friendly index (0, 1, 2, etc.)
        public var speakerIndex: Int {
            if isUser { return -1 }
            // Extract number from labels like "SPEAKER_00", "SPEAKER_01"
            if let range = speakerLabel.range(of: #"\d+$"#, options: .regularExpression),
               let index = Int(speakerLabel[range]) {
                return index
            }
            return speakerLabel.hashValue % 100  // Fallback
        }
    }

    public struct DiarizationResult: Sendable {
        public let segments: [DiarizationSegment]
        public let remoteSpeakerCount: Int   // Number of unique speakers in system audio (excluding user)
        public let processingTime: TimeInterval

        public init(segments: [DiarizationSegment], remoteSpeakerCount: Int, processingTime: TimeInterval) {
            self.segments = segments
            self.remoteSpeakerCount = remoteSpeakerCount
            self.processingTime = processingTime
        }
    }

    public enum DiarizationError: Error, LocalizedError {
        case modelLoadFailed(String)
        case processingFailed(String)
        case audioLoadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let reason):
                return "Failed to load diarization models: \(reason)"
            case .processingFailed(let reason):
                return "Diarization processing failed: \(reason)"
            case .audioLoadFailed(let reason):
                return "Failed to load audio: \(reason)"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "SpeakerDiarization")
    private var diarizerManager: OfflineDiarizerManager?
    private var vadManager: VadManager?
    private var isModelLoaded = false
    private var currentOptions: DiarizationOptions = .meetings

    // MARK: - Initialization

    public init() {}

    public init(options: DiarizationOptions) {
        self.currentOptions = options
    }

    // MARK: - Model Management

    /// Load diarization models with optimized configuration
    /// - Parameter options: Configuration options (defaults to .meetings for optimal accuracy)
    public func loadModels(options: DiarizationOptions = .meetings) async throws {
        guard !isModelLoaded else {
            logger.info("Models already loaded")
            return
        }

        self.currentOptions = options
        logger.info("Loading speaker diarization models with optimized config...")
        logger.info("Config: threshold=\(options.clusteringThreshold), maxSpeakers=\(options.maxSpeakers), vadThreshold=\(options.vadThreshold)")
        let startTime = Date()

        do {
            // Build optimized diarizer config based on FluidAudio benchmarks
            // Optimal threshold of 0.7 achieves 17.7% DER on AMI dataset
            var diarizerConfig = OfflineDiarizerConfig(
                clusteringThreshold: options.clusteringThreshold,
                segmentationMinDurationOn: options.minDurationOn,
                segmentationMinDurationOff: options.minDurationOff
            )

            // Apply speaker count constraints
            if let exactCount = options.expectedSpeakerCount {
                diarizerConfig = diarizerConfig.withSpeakers(exactly: exactCount)
                logger.info("Using exact speaker count: \(exactCount)")
            } else {
                diarizerConfig = diarizerConfig.withSpeakers(min: 1, max: options.maxSpeakers)
                logger.info("Using speaker range: 1-\(options.maxSpeakers)")
            }

            diarizerManager = OfflineDiarizerManager(config: diarizerConfig)
            try await diarizerManager?.prepareModels()

            // Initialize VAD for mic track processing with optimized threshold
            let vadConfig = VadConfig(defaultThreshold: options.vadThreshold)
            vadManager = try await VadManager(config: vadConfig)

            isModelLoaded = true
            let loadTime = Date().timeIntervalSince(startTime)
            logger.info("Diarization models loaded in \(loadTime)s")
        } catch {
            throw DiarizationError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Reload models with new options (unloads existing models first)
    public func reloadModels(with options: DiarizationOptions) async throws {
        unloadModels()
        try await loadModels(options: options)
    }

    /// Unload models to free memory
    public func unloadModels() {
        diarizerManager = nil
        vadManager = nil
        isModelLoaded = false
        logger.info("Diarization models unloaded")
    }

    // MARK: - Diarization

    /// Process dual-track audio with smart speaker identification
    /// - Parameters:
    ///   - microphoneURL: URL to extracted microphone audio (16kHz mono WAV)
    ///   - systemAudioURL: URL to extracted system audio (16kHz mono WAV)
    /// - Returns: DiarizationResult with all speaker segments
    public func processDualTrack(
        microphoneURL: URL,
        systemAudioURL: URL
    ) async throws -> DiarizationResult {
        // Ensure models are loaded
        if !isModelLoaded {
            try await loadModels()
        }

        guard let diarizer = diarizerManager, let vad = vadManager else {
            throw DiarizationError.modelLoadFailed("Managers not initialized")
        }

        let startTime = Date()
        logger.info("Starting dual-track diarization")

        var allSegments: [DiarizationSegment] = []
        var remoteSpeakerCount = 0

        // Process system audio (remote participants) with full diarization
        do {
            logger.info("Running diarization on system audio...")
            let systemResult = try await diarizer.process(systemAudioURL)

            // Track unique speaker labels
            var uniqueSpeakers = Set<String>()

            for segment in systemResult.segments {
                uniqueSpeakers.insert(segment.speakerId)

                allSegments.append(DiarizationSegment(
                    start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds),
                    speakerLabel: segment.speakerId,
                    isUser: false,
                    confidence: 1.0
                ))
            }

            remoteSpeakerCount = uniqueSpeakers.count
            logger.info("System audio: \(systemResult.segments.count) segments, \(remoteSpeakerCount) speakers")
        } catch {
            logger.warning("System audio diarization failed: \(error.localizedDescription)")
            // Continue without system audio diarization
        }

        // Process microphone audio (user) with optimized VAD configuration
        do {
            logger.info("Running VAD on microphone audio...")
            let micSamples = try loadAudioSamples(from: microphoneURL)

            // Use optimized segmentation config for better speech detection
            let vadSegConfig = VadSegmentationConfig(
                minSpeechDuration: 0.2,      // 200ms minimum speech (detect shorter utterances)
                minSilenceDuration: 0.5,     // 500ms silence between segments
                maxSpeechDuration: 30.0,     // 30s max segment (longer for meetings)
                speechPadding: 0.15          // 150ms padding for natural boundaries
            )
            let vadSegments = try await vad.segmentSpeech(micSamples, config: vadSegConfig)

            for segment in vadSegments {
                allSegments.append(DiarizationSegment(
                    start: TimeInterval(segment.startTime),
                    end: TimeInterval(segment.endTime),
                    speakerLabel: "USER",
                    isUser: true,
                    confidence: 1.0
                ))
            }

            logger.info("Microphone audio: \(vadSegments.count) speech segments")
        } catch {
            logger.warning("Microphone VAD failed: \(error.localizedDescription)")
            // Continue without mic segments
        }

        // Sort all segments by start time
        allSegments.sort { $0.start < $1.start }

        let processingTime = Date().timeIntervalSince(startTime)
        logger.info("Diarization complete: \(allSegments.count) total segments in \(processingTime)s")

        return DiarizationResult(
            segments: allSegments,
            remoteSpeakerCount: remoteSpeakerCount,
            processingTime: processingTime
        )
    }

    /// Process a single audio file (for single-track recordings)
    public func processSingleTrack(audioURL: URL) async throws -> DiarizationResult {
        if !isModelLoaded {
            try await loadModels()
        }

        guard let diarizer = diarizerManager else {
            throw DiarizationError.modelLoadFailed("Diarizer not initialized")
        }

        let startTime = Date()
        logger.info("Running single-track diarization")

        let result = try await diarizer.process(audioURL)

        var uniqueSpeakers = Set<String>()
        var segments: [DiarizationSegment] = []

        for segment in result.segments {
            uniqueSpeakers.insert(segment.speakerId)
            segments.append(DiarizationSegment(
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds),
                speakerLabel: segment.speakerId,
                isUser: false,  // Can't determine without mic track
                confidence: 1.0
            ))
        }

        let processingTime = Date().timeIntervalSince(startTime)

        return DiarizationResult(
            segments: segments,
            remoteSpeakerCount: uniqueSpeakers.count,
            processingTime: processingTime
        )
    }

    // MARK: - Private Helpers

    /// Load audio samples from WAV file as Float array (16kHz mono expected)
    private func loadAudioSamples(from url: URL) throws -> [Float] {
        do {
            let converter = AudioConverter()
            return try converter.resampleAudioFile(url)
        } catch {
            throw DiarizationError.audioLoadFailed(error.localizedDescription)
        }
    }
}
