import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreAudio
import os.log

// Debug logging to file (since print doesn't work in app bundles)
func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    let logFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ProjectEcho/debug.log")
    
    if let handle = try? FileHandle(forWritingTo: logFile) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.data(using: .utf8)?.write(to: logFile)
    }
}

/// Thread-safe audio writer that can be accessed from any thread
/// This is separate from the actor to allow synchronous buffer writes
@available(macOS 14.0, *)
final class AudioWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.projectecho.app", category: "AudioWriter")
    
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var isWriting = false
    
    private var bufferCount = 0
    private var recordingStartTime: CMTime?
    
    func configure(outputURL: URL, targetSampleRate: Double, targetChannels: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        
        // Use M4A format for better compatibility with audio players
        assetWriter = try AVAssetWriter(url: outputURL, fileType: .m4a)
        
        // Single audio track - use MONO (1 channel) to match microphone input
        // The microphone on Mac outputs 1 channel, so we must match that
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,  // MONO - matches microphone output
            AVEncoderBitRateKey: 128_000
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true
        
        if let input = audioInput, assetWriter?.canAdd(input) == true {
            assetWriter?.add(input)
            print("✅ [AudioWriter] Added audio input with mono settings")
        } else {
            print("❌ [AudioWriter] Failed to add audio input!")
        }
        
        logger.info("Audio writer configured with mono audio track")
    }
    
    func startWriting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard assetWriter?.startWriting() == true else {
            logger.error("Failed to start asset writer: \(self.assetWriter?.error?.localizedDescription ?? "unknown")")
            return false
        }
        assetWriter?.startSession(atSourceTime: .zero)
        isWriting = true
        recordingStartTime = nil
        bufferCount = 0
        logger.info("Audio writer started")
        return true
    }
    
    func finishWriting() async {
        // Capture writer reference synchronously
        let writer: AVAssetWriter? = {
            lock.lock()
            defer { lock.unlock() }
            isWriting = false
            audioInput?.markAsFinished()
            return assetWriter
        }()
        
        await writer?.finishWriting()
        logger.info("Audio writer finished. Total buffers: \(self.bufferCount)")
    }
    
    /// Write audio buffer - called synchronously from delegate callback
    /// Works for both system audio and microphone
    func writeAudio(_ sampleBuffer: CMSampleBuffer, source: String) {
        lock.lock()
        defer { lock.unlock() }
        
        guard isWriting else { 
            if bufferCount == 0 {
                debugLog("[\(source)] writeAudio called but isWriting=false")
            }
            return 
        }
        
        guard let input = audioInput else {
            debugLog("[\(source)] audioInput is nil!")
            return
        }
        
        guard input.isReadyForMoreMediaData else {
            return
        }
        
        // Adjust timing for first buffer
        let adjustedBuffer = adjustTiming(sampleBuffer)
        
        if input.append(adjustedBuffer) {
            bufferCount += 1
            if bufferCount == 1 {
                debugLog("[\(source)] ✅ First buffer written!")
            } else if bufferCount % 100 == 0 {
                debugLog("[\(source)] \(bufferCount) buffers written")
            }
        } else {
            let errorMsg = assetWriter?.error?.localizedDescription ?? "unknown error"
            debugLog("[\(source)] ❌ Failed to append: \(errorMsg)")
        }
    }
    
    /// Adjust sample buffer timing to start from zero
    private func adjustTiming(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if recordingStartTime == nil {
            recordingStartTime = presentationTime
        }
        
        guard let startTime = recordingStartTime else {
            return sampleBuffer
        }
        
        // Calculate offset from recording start
        let offset = CMTimeSubtract(presentationTime, startTime)
        
        // Create new timing info
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: offset,
            decodeTimeStamp: .invalid
        )
        
        var adjustedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjustedBuffer
        )
        
        if status == noErr, let buffer = adjustedBuffer {
            return buffer
        }
        
        return sampleBuffer
    }
    
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        assetWriter = nil
        audioInput = nil
        isWriting = false
        recordingStartTime = nil
    }
}

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
    
    public struct AudioMetadata: Sendable {
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
    
    // Thread-safe audio writer (not actor-isolated)
    private let audioWriter = AudioWriter()
    
    private var isRecording = false
    private var recordingStartTime: Date?
    private var outputURL: URL?
    
    private let targetSampleRate: Double = 48000.0 // Standard for video/audio work
    private let targetChannels: Int = 2 // Stereo
    
    // Delegates need to be retained
    private var micDelegate: MicrophoneCaptureDelegate?
    private var screenDelegate: ScreenCaptureDelegate?
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Permission Management
    
    /// Request necessary permissions for screen recording and microphone access
    public nonisolated func requestPermissions() async throws {
        let logger = Logger(subsystem: "com.projectecho.app", category: "AudioEngine")
        
        // Check microphone permission first (this will prompt if needed)
        let micPermission = await AVCaptureDevice.requestAccess(for: .audio)
        if !micPermission {
            logger.error("Microphone permission denied")
            throw CaptureError.permissionDenied
        }
        logger.info("Microphone permission granted")

        // For screen recording, we can't directly check permission status
        // The permission prompt will appear when we actually try to capture
        // So we just try to get shareable content - if it fails, it's likely a permission issue
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            logger.info("Screen recording permission available")
        } catch let error as NSError {
            // Check if it's actually a permission error
            // Error code -3801 is "user declined permission"
            if error.code == -3801 || error.domain == "com.apple.screencapturekit" {
                logger.error("Screen recording permission denied: \(error)")
                throw CaptureError.permissionDenied
            }
            // Other errors (like no windows available) are OK - permission is granted
            logger.warning("Screen capture content fetch failed but may not be permission issue: \(error)")
        }

        logger.info("All permissions granted")
    }
    
    // MARK: - Recording Control
    
    /// Start recording with optional app filtering
    public func startRecording(targetApp: String? = nil, outputDirectory: URL) async throws -> URL {
        debugLog("[AudioEngine] startRecording called")
        guard !isRecording else {
            debugLog("[AudioEngine] Already recording!")
            throw CaptureError.recordingAlreadyActive
        }
        
        debugLog("[AudioEngine] Starting recording session...")
        logger.info("Starting recording session...")
        
        // Create output file with .m4a extension for better compatibility
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "Echo_\(timestamp).m4a"
        let fileURL = outputDirectory.appendingPathComponent(filename)
        outputURL = fileURL
        
        // Configure the audio writer
        try audioWriter.configure(outputURL: fileURL, targetSampleRate: targetSampleRate, targetChannels: targetChannels)
        
        // Setup microphone capture FIRST (this is what most users need)
        try await setupMicrophoneCapture()
        
        // Setup ScreenCaptureKit stream for system audio
        try await setupScreenCapture(targetApp: targetApp)
        
        // Start writing
        guard audioWriter.startWriting() else {
            throw CaptureError.streamConfigurationFailed
        }
        
        // Start capture streams
        debugLog("[AudioEngine] Starting microphone capture session...")
        microphoneCaptureSession?.startRunning()
        debugLog("[AudioEngine] Microphone session isRunning: \(microphoneCaptureSession?.isRunning ?? false)")
        
        // NOTE: Disabled ScreenCaptureKit for now - it uses 2 channels which conflicts with mic's 1 channel
        // TODO: Either use separate tracks, or resample system audio to mono
        // debugLog("[AudioEngine] Starting screen capture...")
        // try await screenStream?.startCapture()
        // debugLog("[AudioEngine] Screen capture started")
        debugLog("[AudioEngine] Screen capture DISABLED (format conflict with mic)")
        
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
        
        // Stop captures first
        microphoneCaptureSession?.stopRunning()
        try? await screenStream?.stopCapture()
        
        // Small delay to ensure all buffers are processed
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Finalize audio writer
        await audioWriter.finishWriting()
        
        // Calculate metadata
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        let fileSize = try outputURL.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 ?? 0 } ?? 0
        
        let metadata = AudioMetadata(
            duration: duration,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            fileSize: fileSize,
            format: "M4A/AAC"
        )
        
        // Cleanup
        screenStream = nil
        screenDelegate = nil
        microphoneCaptureSession = nil
        micDelegate = nil
        audioWriter.reset()
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
    
    private func setupMicrophoneCapture() async throws {
        debugLog("[AudioEngine] Setting up microphone capture...")
        
        // Check authorization status FIRST
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        debugLog("[AudioEngine] Mic auth status: \(authStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")
        
        if authStatus == .notDetermined {
            debugLog("[AudioEngine] Requesting microphone permission...")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            debugLog("[AudioEngine] Permission result: \(granted ? "GRANTED" : "DENIED")")
            if !granted {
                throw CaptureError.permissionDenied
            }
        } else if authStatus == .denied || authStatus == .restricted {
            debugLog("[AudioEngine] Microphone permission DENIED!")
            throw CaptureError.permissionDenied
        }
        
        let session = AVCaptureSession()
        session.sessionPreset = .high
        
        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            debugLog("[AudioEngine] No microphone found!")
            throw CaptureError.noDevicesFound
        }
        
        debugLog("[AudioEngine] Found microphone: \(micDevice.localizedName)")
        logger.info("Using microphone: \(micDevice.localizedName)")
        
        let micInput = try AVCaptureDeviceInput(device: micDevice)
        if session.canAddInput(micInput) {
            session.addInput(micInput)
        } else {
            logger.error("Cannot add microphone input to session")
            throw CaptureError.streamConfigurationFailed
        }
        
        let output = AVCaptureAudioDataOutput()
        
        // Create delegate with reference to audioWriter
        micDelegate = MicrophoneCaptureDelegate(audioWriter: audioWriter)
        output.setSampleBufferDelegate(micDelegate, queue: DispatchQueue(label: "com.echo.mic.audio", qos: .userInteractive))
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            logger.error("Cannot add audio output to session")
            throw CaptureError.streamConfigurationFailed
        }
        
        microphoneCaptureSession = session
        debugLog("[AudioEngine] Microphone capture session configured")
        logger.info("Microphone capture configured successfully")
    }
    
    private func setupScreenCapture(targetApp: String?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        logger.info("Available displays: \(content.displays.count)")
        logger.info("Available applications: \(content.applications.count)")

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
            logger.info("Using global audio capture (all system audio)")
        } else {
            throw CaptureError.streamConfigurationFailed
        }

        // Configure stream for audio-only
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(targetSampleRate)
        config.channelCount = targetChannels
        config.excludesCurrentProcessAudio = true // Don't record ourselves
        
        // Minimize video capture overhead since we only need audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum
        config.showsCursor = false

        logger.info("ScreenCaptureKit config: capturesAudio=\(config.capturesAudio), sampleRate=\(config.sampleRate), channels=\(config.channelCount)")

        // Create stream
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        // Create delegate with reference to audioWriter
        screenDelegate = ScreenCaptureDelegate(audioWriter: audioWriter)

        // Add stream output for audio
        try stream.addStreamOutput(screenDelegate!, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.echo.screen.audio", qos: .userInteractive))

        logger.info("ScreenCaptureKit stream configured successfully")

        screenStream = stream
    }
}


// MARK: - Stream Delegate Wrappers

/// Delegate for ScreenCaptureKit audio - writes synchronously to AudioWriter
@available(macOS 14.0, *)
private final class ScreenCaptureDelegate: NSObject, SCStreamOutput {
    private let audioWriter: AudioWriter
    private var bufferCount = 0
    private let logger = Logger(subsystem: "com.projectecho.app", category: "ScreenCapture")

    init(audioWriter: AudioWriter) {
        self.audioWriter = audioWriter
        super.init()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Ignore video buffers
        guard type == .audio else { return }
        
        bufferCount += 1
        if bufferCount == 1 {
            logger.info("ScreenCaptureKit: First audio buffer received!")
        }

        // Write synchronously - CMSampleBuffer is only valid within this callback
        audioWriter.writeAudio(sampleBuffer, source: "System")
    }
}

/// Delegate for microphone capture - writes synchronously to AudioWriter
@available(macOS 14.0, *)
private final class MicrophoneCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let audioWriter: AudioWriter
    private var bufferCount = 0
    private let logger = Logger(subsystem: "com.projectecho.app", category: "MicCapture")

    init(audioWriter: AudioWriter) {
        self.audioWriter = audioWriter
        super.init()
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        bufferCount += 1
        if bufferCount == 1 {
            debugLog("[MicDelegate] First audio buffer received from capture!")
        }
        if bufferCount % 100 == 0 {
            debugLog("[MicDelegate] \(bufferCount) buffers received")
        }

        // Write synchronously - CMSampleBuffer is only valid within this callback
        audioWriter.writeAudio(sampleBuffer, source: "Mic")
    }
}
