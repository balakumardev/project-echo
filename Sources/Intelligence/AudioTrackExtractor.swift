import Foundation
@preconcurrency import AVFoundation
import os.log

/// Extracts separate audio tracks from multi-track .mov recordings for diarization processing
@available(macOS 14.0, *)
public actor AudioTrackExtractor {

    // MARK: - Types

    public struct ExtractedTracks: Sendable {
        public let microphoneURL: URL       // Track 1: User's microphone (mono)
        public let systemAudioURL: URL      // Track 2: Remote participants (stereo->mono)
        public let duration: TimeInterval
        public let tempDirectory: URL       // For cleanup
    }

    public enum ExtractionError: Error, LocalizedError {
        case noAudioTracks
        case insufficientTracks(found: Int)
        case exportFailed(String)
        case unsupportedFormat

        public var errorDescription: String? {
            switch self {
            case .noAudioTracks:
                return "No audio tracks found in recording"
            case .insufficientTracks(let found):
                return "Expected 2 audio tracks, found \(found)"
            case .exportFailed(let reason):
                return "Audio export failed: \(reason)"
            case .unsupportedFormat:
                return "Unsupported audio format"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "AudioTrackExtractor")
    private let targetSampleRate: Double = 16000.0  // Required by FluidAudio

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// Extract both audio tracks to separate WAV files (16kHz mono for diarization)
    /// - Parameter inputURL: URL to the .mov recording with dual audio tracks
    /// - Returns: ExtractedTracks with URLs to the extracted audio files
    public func extractTracks(from inputURL: URL) async throws -> ExtractedTracks {
        logger.info("Extracting audio tracks from: \(inputURL.lastPathComponent)")

        let asset = AVAsset(url: inputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard !audioTracks.isEmpty else {
            throw ExtractionError.noAudioTracks
        }

        // We expect 2 tracks: mic (track 0) and system audio (track 1)
        // But handle single-track recordings gracefully
        guard audioTracks.count >= 2 else {
            logger.warning("Only \(audioTracks.count) audio track(s) found, expected 2")
            throw ExtractionError.insufficientTracks(found: audioTracks.count)
        }

        let duration = try await asset.load(.duration).seconds
        logger.info("Recording duration: \(duration)s, tracks: \(audioTracks.count)")

        // Create temp directory for extracted audio
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Engram_Diarization_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let microphoneURL = tempDir.appendingPathComponent("microphone.wav")
        let systemAudioURL = tempDir.appendingPathComponent("system_audio.wav")

        // Extract tracks in parallel
        // Track order in AVAsset: first added = index 0
        // In AudioCaptureEngine: mic is added first, system audio second
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.exportTrackToWav(audioTracks[0], from: asset, to: microphoneURL, label: "microphone")
            }
            group.addTask {
                try await self.exportTrackToWav(audioTracks[1], from: asset, to: systemAudioURL, label: "system")
            }
            try await group.waitForAll()
        }

        logger.info("Audio tracks extracted successfully")

        return ExtractedTracks(
            microphoneURL: microphoneURL,
            systemAudioURL: systemAudioURL,
            duration: duration,
            tempDirectory: tempDir
        )
    }

    /// Clean up temporary extracted files
    public func cleanup(tracks: ExtractedTracks) {
        do {
            try FileManager.default.removeItem(at: tracks.tempDirectory)
            logger.info("Cleaned up temporary audio files")
        } catch {
            logger.warning("Failed to cleanup temp files: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods

    /// Export a single audio track to 16kHz mono WAV file
    private func exportTrackToWav(_ track: AVAssetTrack, from asset: AVAsset, to outputURL: URL, label: String) async throws {
        logger.info("Exporting \(label) track to: \(outputURL.lastPathComponent)")

        // Create asset reader for the specific track
        let reader = try AVAssetReader(asset: asset)

        // Output settings: 16kHz mono PCM (required by FluidAudio)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,  // Mono
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw ExtractionError.exportFailed("Cannot add reader output for \(label)")
        }
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw ExtractionError.exportFailed(reader.error?.localizedDescription ?? "Failed to start reading \(label)")
        }

        // Collect all audio samples
        var audioData = Data()

        while reader.status == .reading {
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                break
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

            if status == noErr, let pointer = dataPointer {
                audioData.append(UnsafeBufferPointer(start: pointer, count: length))
            }
        }

        if reader.status == .failed {
            throw ExtractionError.exportFailed(reader.error?.localizedDescription ?? "Reader failed for \(label)")
        }

        // Write WAV file with header
        let wavData = createWavFile(from: audioData, sampleRate: Int(targetSampleRate), channels: 1, bitsPerSample: 16)
        try wavData.write(to: outputURL)

        let fileSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
        logger.info("Exported \(label): \(fileSize) bytes")
    }

    /// Create a WAV file with proper header from raw PCM data
    private func createWavFile(from pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var wavData = Data()

        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = pcmData.count
        let fileSize = 36 + dataSize

        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // Subchunk1Size (16 for PCM)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // AudioFormat (1 = PCM)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })

        // data subchunk
        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        wavData.append(pcmData)

        return wavData
    }
}
