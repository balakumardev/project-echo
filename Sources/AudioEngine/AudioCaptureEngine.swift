import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreAudio
import os.log

/// Main audio capture engine combining ScreenCaptureKit (system audio) + AVCaptureSession (microphone)
@available(macOS 14.0, *)
public actor AudioCaptureEngine {
    
    // MARK: - Types
    
    public enum CaptureError: Error {
        case permissionDenied
        case noDevicesFound
        case streamConfigurationFailed
        case recordingAlreadyActive
        case noActiveRecording
        case sampleRateMismatch
    }
    
    public struct AudioMetadata {
        public let duration: TimeInterval
        public let sampleRate: Double
        public let channels: Int
        public let fileSize: Int64
        public let format: String
        
        public init(duration: TimeInterval, sampleRate: Double, channels: Int, fileSize: Int64, format: String) {
            self.duration = duration
            self.sampleRate = sampleRate
            self.channels = channels
            self.fileSize = fileSize
            self.format = format
        }
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.projectecho.app", category: "AudioEngine")
    
    private var screenStream: SCStream?
    private var microphoneCaptureSession: AVCaptureSession?
    private var assetWriter: AVAssetWriter?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneAudioInput: AVAssetWriterInput?
    
    private var isRecording = false
    private var recordingStartTime: Date?
    private var outputURL: URL?
    
    private let targetSampleRate: Double = 48000.0 // Standard for video/audio work
    private let targetChannels: Int = 2 // Stereo
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Permission Management
    
    /// Request necessary permissions for screen recording and microphone access
    public nonisolated func requestPermissions() async throws {
        // Request screen recording permission - attempt to get content
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            logger.info("Screen recording permission available")
        } catch {
            logger.error("Screen recording permission denied")
            throw CaptureError.permissionDenied
        }
        
        // Request microphone permission
        let micPermission = await AVCaptureDevice.requestAccess(for: .audio)
        guard micPermission else {
            logger.error("Microphone permission denied")
            throw CaptureError.permissionDenied
        }
        
        logger.info("All permissions granted")
    }
    
    // MARK: - Recording Control
    
    /// Start recording with optional app filtering
    public func startRecording(targetApp: String? = nil, outputDirectory: URL) async throws -> URL {
        guard !isRecording else {
            throw CaptureError.recordingAlreadyActive
        }
        
        logger.info("Starting recording session...")
        
        // Create output file
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "Echo_\(timestamp).mov"
        let fileURL = outputDirectory.appendingPathComponent(filename)
        outputURL = fileURL
        
        // Setup asset writer for multi-track recording
        try await setupAssetWriter(outputURL: fileURL)
        
        // Setup ScreenCaptureKit stream
        try await setupScreenCapture(targetApp: targetApp)
        
        // Setup microphone capture
        try await setupMicrophoneCapture()
        
        // Start all streams
        guard assetWriter?.startWriting() == true else {
            throw CaptureError.streamConfigurationFailed
        }
        assetWriter?.startSession(atSourceTime: .zero)
        
        try await screenStream?.startCapture()
        microphoneCaptureSession?.startRunning()
        
        isRecording = true
        recordingStartTime = Date()
        
        logger.info("Recording started: \(filename)")
        return fileURL
    }
    
    /// Stop active recording
    public func stopRecording() async throws -> AudioMetadata {
        guard isRecording else {
            throw CaptureError.noActiveRecording
        }
        
        logger.info("Stopping recording...")
        
        // Stop captures
        try? await screenStream?.stopCapture()
        microphoneCaptureSession?.stopRunning()
        
        // Finalize asset writer
        systemAudioInput?.markAsFinished()
        microphoneAudioInput?.markAsFinished()
        
        await assetWriter?.finishWriting()
        
        // Calculate metadata
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        let fileSize = try outputURL.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 ?? 0 } ?? 0
        
        let metadata = AudioMetadata(
            duration: duration,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            fileSize: fileSize,
            format: "QuickTime/AAC"
        )
        
        // Cleanup
        screenStream = nil
        microphoneCaptureSession = nil
        assetWriter = nil
        isRecording = false
        recordingStartTime = nil
        
        logger.info("Recording stopped. Duration: \(duration)s, Size: \(fileSize) bytes")
        return metadata
    }
    
    /// Insert a timestamp marker (for "Mark Moment" feature)
    public func insertMarker(label: String) async {
        guard isRecording else { return }
        let timestamp = Date().timeIntervalSince(recordingStartTime ?? Date())
        logger.info("Marker inserted: '\(label)' at \(timestamp)s")
        // TODO: Store marker in metadata track or separate JSON file
    }
    
    // MARK: - Private Setup Methods
    
    private func setupAssetWriter(outputURL: URL) async throws {
        assetWriter = try AVAssetWriter(url: outputURL, fileType: .mov)
        
        // System Audio Track (Track 1)
        let systemAudioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVEncoderBitRateKey: 192_000
        ]
        
        systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: systemAudioSettings)
        systemAudioInput?.expectsMediaDataInRealTime = true
        
        if let input = systemAudioInput, assetWriter?.canAdd(input) == true {
            assetWriter?.add(input)
        }
        
        // Microphone Track (Track 2)
        let micAudioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1, // Mono for mic
            AVEncoderBitRateKey: 128_000
        ]
        
        microphoneAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micAudioSettings)
        microphoneAudioInput?.expectsMediaDataInRealTime = true
        
        if let input = microphoneAudioInput, assetWriter?.canAdd(input) == true {
            assetWriter?.add(input)
        }
        
        logger.info("Asset writer configured with 2 audio tracks")
    }
    
    private var micDelegate: AudioCaptureDelegate?
    private var screenDelegate: ScreenCaptureDelegate?
    
    private func setupScreenCapture(targetApp: String?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        // Determine filter
        let filter: SCContentFilter
        if let appName = targetApp,
           let app = content.applications.first(where: { $0.applicationName == appName }),
           let display = content.displays.first {
            // App-specific capture - capture display excluding other apps
            let excludedApps = content.applications.filter { $0.bundleIdentifier != app.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            logger.info("Capturing audio from: \(appName)")
        } else if let display = content.displays.first {
            // Global capture (fallback)
            filter = SCContentFilter(display: display, excludingWindows: [])
            logger.info("Using global audio capture")
        } else {
            throw CaptureError.streamConfigurationFailed
        }
        
        // Configure stream for audio-only
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(targetSampleRate)
        config.channelCount = targetChannels
        config.excludesCurrentProcessAudio = true // Don't record ourselves
        
        // Create stream
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        
        // Create and store delegate
        screenDelegate = ScreenCaptureDelegate(engine: self)
        
        // Add stream output for audio
        try stream.addStreamOutput(screenDelegate!, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.echo.audioqueue"))
        
        screenStream = stream
    }
    
    private func setupMicrophoneCapture() async throws {
        let session = AVCaptureSession()
        session.sessionPreset = .high
        
        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noDevicesFound
        }
        
        let micInput = try AVCaptureDeviceInput(device: micDevice)
        if session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        
        let output = AVCaptureAudioDataOutput()
        
        // Create and store delegate
        micDelegate = AudioCaptureDelegate(engine: self)
        output.setSampleBufferDelegate(micDelegate, queue: DispatchQueue(label: "com.echo.micqueue"))
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        
        microphoneCaptureSession = session
        logger.info("Microphone configured: \(micDevice.localizedName)")
    }
    
    // MARK: - Audio Processing
    
    func processSystemAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let input = systemAudioInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
    
    func processMicrophoneBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let input = microphoneAudioInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
}


// MARK: - Stream Delegate Wrappers

@available(macOS 14.0, *)
private final class ScreenCaptureDelegate: NSObject, SCStreamOutput {
    weak var engine: AudioCaptureEngine?
    
    init(engine: AudioCaptureEngine) {
        self.engine = engine
        super.init()
    }
    
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let engine = engine else { return }
        
        Task  {
            await engine.processSystemAudioBuffer(sampleBuffer)
        }
    }
}

@available(macOS 14.0, *)
private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var engine: AudioCaptureEngine?
    
    init(engine: AudioCaptureEngine) {
        self.engine = engine
        super.init()
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let engine = engine else { return }
        
        Task {
            await engine.processMicrophoneBuffer(sampleBuffer)
        }
    }
}
