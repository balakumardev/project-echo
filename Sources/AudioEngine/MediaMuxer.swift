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

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "MediaMuxer")

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// Mux video and audio files into a single combined output file.
    /// Uses ffmpeg to mix multiple audio tracks (mic + system) into a single stereo stream,
    /// preventing the garbled playback that occurs when AVPlayer plays separate tracks simultaneously.
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

        // Count audio tracks to decide filter
        let audioAsset = AVURLAsset(url: audioURL)
        let audioTrackCount = (try? await audioAsset.loadTracks(withMediaType: .audio).count) ?? 1

        // Build ffmpeg command:
        // - Input 0: video file (copy video stream as-is)
        // - Input 1: audio file (mix all audio tracks into single stereo stream)
        var arguments = [
            "-i", videoURL.path,
            "-i", audioURL.path,
            "-map", "0:v",       // Take video from input 0
            "-c:v", "copy",      // Copy video without re-encoding
        ]

        if audioTrackCount > 1 {
            // Mix multiple audio tracks into one stereo stream
            var filterInputs = ""
            for i in 0..<audioTrackCount {
                filterInputs += "[1:\(i)]"
            }
            arguments += [
                "-filter_complex", "\(filterInputs)amix=inputs=\(audioTrackCount):duration=longest",
                "-c:a", "aac", "-b:a", "192k",
            ]
        } else {
            // Single audio track - just copy it
            arguments += ["-map", "1:a", "-c:a", "copy"]
        }

        // Use shortest duration (match video length)
        arguments += ["-shortest", "-y", outputURL.path]

        logger.info("Muxing with ffmpeg: \(audioTrackCount) audio track(s)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exitStatus: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        guard exitStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            logger.error("ffmpeg mux failed with exit code \(exitStatus)")
            throw MuxerError.exportFailed("ffmpeg exited with code \(exitStatus)")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        // Get duration from output file
        let outputAsset = AVURLAsset(url: outputURL)
        let duration = (try? await outputAsset.load(.duration).seconds) ?? 0

        logger.info("Mux completed: \(outputURL.lastPathComponent), duration=\(String(format: "%.1f", duration))s, size=\(fileSize) bytes")

        return MuxResult(
            outputURL: outputURL,
            duration: duration,
            fileSize: fileSize
        )
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
