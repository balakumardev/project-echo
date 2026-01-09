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
        public let mixedURL: URL?           // Combined audio for transcription (optional)
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
        let mixedURL = tempDir.appendingPathComponent("mixed.wav")

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

        // Mix both tracks into a single file for transcription
        logger.info("Mixing audio tracks for transcription...")
        try mixAudioFiles(micURL: microphoneURL, systemURL: systemAudioURL, outputURL: mixedURL)

        logger.info("Audio tracks extracted and mixed successfully")

        return ExtractedTracks(
            microphoneURL: microphoneURL,
            systemAudioURL: systemAudioURL,
            mixedURL: mixedURL,
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

    /// Mix two mono WAV files into a single mono WAV file
    /// Both inputs are expected to be 16kHz 16-bit mono WAV files
    private func mixAudioFiles(micURL: URL, systemURL: URL, outputURL: URL) throws {
        logger.info("Mixing mic and system audio files...")

        // Read WAV files (skip 44-byte header)
        let micData = try Data(contentsOf: micURL)
        let systemData = try Data(contentsOf: systemURL)

        // Skip WAV header (44 bytes)
        let headerSize = 44
        guard micData.count > headerSize, systemData.count > headerSize else {
            throw ExtractionError.exportFailed("WAV files too small to mix")
        }

        let micPCM = micData.dropFirst(headerSize)
        let systemPCM = systemData.dropFirst(headerSize)

        // Determine output length (use longer of the two)
        let maxSamples = max(micPCM.count, systemPCM.count) / 2  // 16-bit = 2 bytes per sample
        var mixedSamples = [Int16](repeating: 0, count: maxSamples)

        // Mix samples (add with clipping protection)
        micPCM.withUnsafeBytes { micBuffer in
            systemPCM.withUnsafeBytes { systemBuffer in
                let micSamples = micBuffer.bindMemory(to: Int16.self)
                let systemSamples = systemBuffer.bindMemory(to: Int16.self)

                for i in 0..<maxSamples {
                    let micSample: Int32 = i < micSamples.count ? Int32(micSamples[i]) : 0
                    let systemSample: Int32 = i < systemSamples.count ? Int32(systemSamples[i]) : 0

                    // Mix with equal weighting (simple average to prevent clipping)
                    // Boost system audio slightly since it's often quieter
                    let mixed = (micSample + (systemSample * 12 / 10)) / 2

                    // Clip to Int16 range
                    mixedSamples[i] = Int16(clamping: max(Int32(Int16.min), min(Int32(Int16.max), mixed)))
                }
            }
        }

        // Convert to Data
        var mixedData = Data()
        for sample in mixedSamples {
            withUnsafeBytes(of: sample.littleEndian) { mixedData.append(contentsOf: $0) }
        }

        // Create WAV file
        let wavData = createWavFile(from: mixedData, sampleRate: Int(targetSampleRate), channels: 1, bitsPerSample: 16)
        try wavData.write(to: outputURL)

        let fileSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
        logger.info("Mixed audio created: \(fileSize) bytes, \(maxSamples) samples")
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
