import Foundation
import AVFoundation
import os.log

/// Utility for combining video and audio files into a single output
/// Uses AVMutableComposition + AVAssetExportSession for reliable muxing
@available(macOS 14.0, *)
public actor MediaMuxer {

    // MARK: - Types

    public enum MuxerError: Error, LocalizedError {
        case videoFileNotFound
        case audioFileNotFound
        case noVideoTrack
        case noAudioTrack
        case exportFailed(String)
        case outputFileExists

        public var errorDescription: String? {
            switch self {
            case .videoFileNotFound: return "Video file not found"
            case .audioFileNotFound: return "Audio file not found"
            case .noVideoTrack: return "No video track found in video file"
            case .noAudioTrack: return "No audio track found in audio file"
            case .exportFailed(let reason): return "Export failed: \(reason)"
            case .outputFileExists: return "Output file already exists"
            }
        }
    }

    public struct MuxResult: Sendable {
        public let outputURL: URL
        public let duration: TimeInterval
        public let fileSize: Int64
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.projectecho.app", category: "MediaMuxer")

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// Mux video and audio files into a single combined output file
    /// - Parameters:
    ///   - videoURL: URL to video-only MOV file (from ScreenRecorder)
    ///   - audioURL: URL to audio-only MOV file (from AudioCaptureEngine)
    ///   - outputURL: URL for the combined output file
    /// - Returns: MuxResult with output file info
    public func mux(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL
    ) async throws -> MuxResult {
        logger.info("Starting mux: video=\(videoURL.lastPathComponent), audio=\(audioURL.lastPathComponent)")

        // Verify input files exist
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            logger.error("Video file not found: \(videoURL.path)")
            throw MuxerError.videoFileNotFound
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            logger.error("Audio file not found: \(audioURL.path)")
            throw MuxerError.audioFileNotFound
        }

        // Remove output file if it exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Load assets
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        // Create composition
        let composition = AVMutableComposition()

        // Add video track
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            logger.error("No video track found in: \(videoURL.lastPathComponent)")
            throw MuxerError.noVideoTrack
        }

        let videoDuration = try await videoAsset.load(.duration)

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MuxerError.exportFailed("Could not create video track in composition")
        }

        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )

        // Add audio track(s) from audio file
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        if audioTracks.isEmpty {
            logger.warning("No audio tracks found in: \(audioURL.lastPathComponent)")
            // Continue without audio - video will still be muxed
        } else {
            // Add all audio tracks (mic + system audio if present)
            for (index, audioTrack) in audioTracks.enumerated() {
                guard let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    logger.warning("Could not create audio track \(index) in composition")
                    continue
                }

                // Use video duration to sync - audio may be slightly longer/shorter
                let audioTrackDuration = try await audioAsset.load(.duration)
                let insertDuration = CMTimeMinimum(videoDuration, audioTrackDuration)

                do {
                    try compositionAudioTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: insertDuration),
                        of: audioTrack,
                        at: .zero
                    )
                    logger.info("Added audio track \(index) to composition")
                } catch {
                    logger.warning("Failed to insert audio track \(index): \(error.localizedDescription)")
                }
            }
        }

        // Export the composition
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MuxerError.exportFailed("Could not create export session")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        logger.info("Starting export to: \(outputURL.lastPathComponent)")

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            let duration = videoDuration.seconds

            logger.info("Mux completed: \(outputURL.lastPathComponent), duration=\(duration)s, size=\(fileSize) bytes")

            return MuxResult(
                outputURL: outputURL,
                duration: duration,
                fileSize: fileSize
            )

        case .failed:
            let errorMessage = exportSession.error?.localizedDescription ?? "Unknown error"
            logger.error("Export failed: \(errorMessage)")
            throw MuxerError.exportFailed(errorMessage)

        case .cancelled:
            logger.warning("Export was cancelled")
            throw MuxerError.exportFailed("Export was cancelled")

        default:
            throw MuxerError.exportFailed("Unexpected export status: \(exportSession.status.rawValue)")
        }
    }

    /// Convenience method that muxes and replaces the original video file
    /// - Parameters:
    ///   - videoURL: URL to video-only MOV file (will be replaced with combined file)
    ///   - audioURL: URL to audio-only MOV file
    /// - Returns: MuxResult with the replaced video file info
    public func muxInPlace(
        videoURL: URL,
        audioURL: URL
    ) async throws -> MuxResult {
        // Create temporary output path
        let tempURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent("temp_muxed_\(UUID().uuidString).mov")

        // Mux to temporary file
        let result = try await mux(videoURL: videoURL, audioURL: audioURL, outputURL: tempURL)

        // Replace original video file with muxed file
        try FileManager.default.removeItem(at: videoURL)
        try FileManager.default.moveItem(at: tempURL, to: videoURL)

        logger.info("Replaced \(videoURL.lastPathComponent) with muxed version")

        return MuxResult(
            outputURL: videoURL,
            duration: result.duration,
            fileSize: result.fileSize
        )
    }
}
