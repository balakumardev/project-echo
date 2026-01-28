import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreAudio
import os.log

// Shared file logger that writes to ~/Library/Logs/Engram/debug.log
// This matches the format used by FileLogger in the App module
private let audioEngineLogQueue = DispatchQueue(label: "dev.balakumar.engram.audioengine.log", qos: .utility)
private let audioEngineDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

/// Log a debug message to the shared debug log file
/// This is a standalone function for AudioEngine module that writes to the same location as FileLogger
func fileDebugLog(_ message: String, file: String = #file, line: Int = #line) {
    audioEngineLogQueue.async {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Engram")
        let logFile = logDir.appendingPathComponent("debug.log")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let timestamp = audioEngineDateFormatter.string(from: Date())
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let logLine = "[\(timestamp)] [DEBUG] [\(fileName):\(line)] \(message)\n"

        guard let data = logLine.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

/// Thread-safe audio writer that can be accessed from any thread
/// This is separate from the actor to allow synchronous buffer writes
@available(macOS 14.0, *)
final class AudioWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "AudioWriter")
    
    private var assetWriter: AVAssetWriter?
    private var microphoneInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var isWriting = false
    
    private var micBufferCount = 0
    private var systemBufferCount = 0
    private var micStartTime: CMTime?
    private var systemStartTime: CMTime?
    
    func configure(outputURL: URL, targetSampleRate: Double) throws {
        lock.lock()
        defer { lock.unlock() }

        // Use MOV format to support multiple audio tracks
        assetWriter = try AVAssetWriter(url: outputURL, fileType: .mov)

        // Enable fragmented movie writing for crash resistance
        // This writes the moov atom every 5 seconds instead of only at finalization
        // If the app crashes mid-recording, the file will still be playable up to the last fragment
        assetWriter?.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        fileDebugLog("[AudioWriter] Configured with movieFragmentInterval=5s for crash resistance")
        
        // Track 1: Microphone (MONO)
        let micSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,  // Mono for mic
            AVEncoderBitRateKey: 128_000
        ]
        
        microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        microphoneInput?.expectsMediaDataInRealTime = true
        
        if let input = microphoneInput, assetWriter?.canAdd(input) == true {
            assetWriter?.add(input)
            fileDebugLog("[AudioWriter] Added microphone track (mono)")
        }
        
        // Track 2: System Audio (STEREO)
        let systemSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 2,  // Stereo for system audio
            AVEncoderBitRateKey: 192_000
        ]
        
        systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: systemSettings)
        systemAudioInput?.expectsMediaDataInRealTime = true
        
        if let input = systemAudioInput, assetWriter?.canAdd(input) == true {
            assetWriter?.add(input)
            fileDebugLog("[AudioWriter] Added system audio track (stereo)")
        }
        
        logger.info("Audio writer configured with 2 audio tracks")
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
        micStartTime = nil
        systemStartTime = nil
        micBufferCount = 0
        systemBufferCount = 0
        logger.info("Audio writer started")
        return true
    }
    
    func finishWriting() async {
        // Capture writer reference synchronously
        let writer: AVAssetWriter? = {
            lock.lock()
            defer { lock.unlock() }
            isWriting = false
            microphoneInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            return assetWriter
        }()
        
        await writer?.finishWriting()
        logger.info("Audio writer finished. Mic buffers: \(self.micBufferCount), System buffers: \(self.systemBufferCount)")
    }
    
    /// Write microphone audio buffer
    func writeMicrophoneAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        
        guard isWriting else { return }
        guard let input = microphoneInput, input.isReadyForMoreMediaData else { return }
        
        let adjustedBuffer = adjustTiming(sampleBuffer, startTime: &micStartTime)
        
        if input.append(adjustedBuffer) {
            micBufferCount += 1
            if micBufferCount == 1 {
                fileDebugLog("[Mic] ✅ First buffer written!")
            } else if micBufferCount % 100 == 0 {
                fileDebugLog("[Mic] \(micBufferCount) buffers written")
            }
        }
    }
    
    /// Write system audio buffer
    func writeSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        
        guard isWriting else { return }
        guard let input = systemAudioInput, input.isReadyForMoreMediaData else { return }
        
        let adjustedBuffer = adjustTiming(sampleBuffer, startTime: &systemStartTime)
        
        if input.append(adjustedBuffer) {
            systemBufferCount += 1
            if systemBufferCount == 1 {
                fileDebugLog("[System] ✅ First buffer written!")
            } else if systemBufferCount % 100 == 0 {
                fileDebugLog("[System] \(systemBufferCount) buffers written")
            }
        }
    }
    
    /// Adjust sample buffer timing to start from zero
    private func adjustTiming(_ sampleBuffer: CMSampleBuffer, startTime: inout CMTime?) -> CMSampleBuffer {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if startTime == nil {
            startTime = presentationTime
        }
        
        guard let start = startTime else {
            return sampleBuffer
        }
        
        let offset = CMTimeSubtract(presentationTime, start)
        
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
        microphoneInput = nil
        systemAudioInput = nil
        isWriting = false
        micStartTime = nil
        systemStartTime = nil
    }
}

/// Main audio capture engine combining ScreenCaptureKit (system audio) + AVCaptureSession (microphone)
/// Uses AVCaptureSession for mic to allow sharing with other apps like Zoom
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
        case voiceProcessingFailed
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

    /// A marker/bookmark within a recording
    public struct Marker: Codable, Sendable {
        public let timestamp: TimeInterval
        public let label: String
        public let createdAt: Date

        public init(timestamp: TimeInterval, label: String, createdAt: Date = Date()) {
            self.timestamp = timestamp
            self.label = label
            self.createdAt = createdAt
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "AudioEngine")

    private var screenStream: SCStream?

    // AVCaptureSession for microphone - designed for recording, shares nicely with other apps
    private var captureSession: AVCaptureSession?
    private var micCaptureDelegate: MicrophoneCaptureDelegate?
    private var currentMicDeviceID: String?

    // Thread-safe audio writer (not actor-isolated)
    private let audioWriter = AudioWriter()

    private var isRecording = false
    private var recordingStartTime: Date?
    private var outputURL: URL?
    private var markers: [Marker] = []

    private let targetSampleRate: Double = 48000.0 // Standard for video/audio work
    private let targetChannels: Int = 2 // Stereo

    // Screen capture delegate needs to be retained
    private var screenDelegate: ScreenCaptureDelegate?

    // Device change observer
    private var deviceChangeObserver: NSObjectProtocol?

    // MARK: - Initialization

    public init() {
        Task { await setupDeviceChangeNotifications() }
    }

    // MARK: - Device Change Handling

    private func setupDeviceChangeNotifications() {
        // Observe when audio devices are connected/disconnected
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.audio) else { return }
            fileDebugLog("[AudioEngine] Audio device connected: \(device.localizedName)")
            Task { [weak self] in
                await self?.handleDeviceChange()
            }
        }

        // Also observe disconnections
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.audio) else { return }
            fileDebugLog("[AudioEngine] Audio device disconnected: \(device.localizedName)")
            // We don't switch on disconnect - system will handle fallback
        }
    }

    private func handleDeviceChange() async {
        guard isRecording else { return }

        // Get the new default device
        guard let newDevice = AVCaptureDevice.default(for: .audio) else {
            fileDebugLog("[AudioEngine] No default audio device after change")
            return
        }

        // Check if it's actually different from current
        if newDevice.uniqueID == currentMicDeviceID {
            fileDebugLog("[AudioEngine] Device change detected but same device, ignoring")
            return
        }

        fileDebugLog("[AudioEngine] Switching to new audio device: \(newDevice.localizedName)")
        logger.info("Auto-switching microphone to: \(newDevice.localizedName)")

        // Reconfigure the capture session with the new device
        await switchMicrophoneDevice(to: newDevice)
    }

    private func switchMicrophoneDevice(to newDevice: AVCaptureDevice) async {
        guard let session = captureSession else { return }

        // Stop the session temporarily
        session.stopRunning()

        // Begin configuration
        session.beginConfiguration()

        // Remove old input
        for input in session.inputs {
            session.removeInput(input)
        }

        // Add new input
        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                currentMicDeviceID = newDevice.uniqueID
                fileDebugLog("[AudioEngine] Switched to device: \(newDevice.localizedName)")
            } else {
                fileDebugLog("[AudioEngine] Cannot add new device input")
            }
        } catch {
            fileDebugLog("[AudioEngine] Failed to create input for new device: \(error.localizedDescription)")
        }

        // Commit configuration
        session.commitConfiguration()

        // Restart session
        session.startRunning()
        fileDebugLog("[AudioEngine] Session restarted with new device, isRunning: \(session.isRunning)")
    }
    
    // MARK: - Permission Management
    
    /// Request necessary permissions for screen recording and microphone access
    public nonisolated func requestPermissions() async throws {
        let logger = Logger(subsystem: "dev.balakumar.engram", category: "AudioEngine")
        
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
    
    // MARK: - Filename Helpers

    /// Sanitize a string for use as a filename
    private func sanitizeFilename(_ name: String?) -> String? {
        guard let name = name, !name.isEmpty else { return nil }

        var sanitized = name

        // Strip common meeting app suffixes
        let suffixesToRemove = [" - Zoom", " - Google Meet", " - Microsoft Teams", " | Microsoft Teams"]
        for suffix in suffixesToRemove {
            if sanitized.hasSuffix(suffix) {
                sanitized = String(sanitized.dropLast(suffix.count))
            }
        }

        // Replace invalid filesystem characters with underscores
        let invalidChars = CharacterSet(charactersIn: ":/\\?*<>|\"")
        sanitized = sanitized.unicodeScalars
            .map { invalidChars.contains($0) ? "_" : String($0) }
            .joined()

        // Replace spaces with underscores
        sanitized = sanitized.replacingOccurrences(of: " ", with: "_")

        // Collapse multiple underscores
        while sanitized.contains("__") {
            sanitized = sanitized.replacingOccurrences(of: "__", with: "_")
        }

        // Trim underscores from start/end
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        // Truncate to reasonable length
        if sanitized.count > 50 {
            sanitized = String(sanitized.prefix(50))
        }

        return sanitized.isEmpty ? nil : sanitized
    }

    // MARK: - Recording Control

    /// Start recording with optional app filtering
    /// - Parameters:
    ///   - targetApp: App name for audio filtering (used to identify which app's audio to capture)
    ///   - recordingName: Name to use for the recording file (typically the meeting title)
    ///   - outputDirectory: Directory to save the recording
    public func startRecording(targetApp: String? = nil, recordingName: String? = nil, outputDirectory: URL) async throws -> URL {
        fileDebugLog("[AudioEngine] startRecording called")
        guard !isRecording else {
            fileDebugLog("[AudioEngine] Already recording!")
            throw CaptureError.recordingAlreadyActive
        }

        // Reset markers for new recording
        markers = []

        fileDebugLog("[AudioEngine] Starting recording session...")
        logger.info("Starting recording session...")

        // Create output file with .mov extension (supports multiple audio tracks)
        // Use sanitized recording name if provided, otherwise fall back to "Echo"
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseName = sanitizeFilename(recordingName) ?? "Echo"
        let filename = "\(baseName)_\(timestamp).mov"
        let fileURL = outputDirectory.appendingPathComponent(filename)
        outputURL = fileURL
        
        // Configure the audio writer with separate tracks for mic and system audio
        try audioWriter.configure(outputURL: fileURL, targetSampleRate: targetSampleRate)
        
        // Setup microphone capture FIRST (this is what most users need)
        try await setupMicrophoneCapture()
        
        // Setup ScreenCaptureKit stream for system audio
        try await setupScreenCapture(targetApp: targetApp)
        
        // Start writing
        guard audioWriter.startWriting() else {
            throw CaptureError.streamConfigurationFailed
        }

        // Start microphone capture (AVCaptureSession)
        fileDebugLog("[AudioEngine] Starting AVCaptureSession for microphone...")
        captureSession?.startRunning()
        fileDebugLog("[AudioEngine] AVCaptureSession isRunning: \(captureSession?.isRunning ?? false)")

        // Start system audio capture (ScreenCaptureKit)
        fileDebugLog("[AudioEngine] Starting screen capture for system audio...")
        try await screenStream?.startCapture()
        fileDebugLog("[AudioEngine] Screen capture started")
        
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

        // Stop microphone capture (AVCaptureSession)
        fileDebugLog("[AudioEngine] Stopping AVCaptureSession...")
        captureSession?.stopRunning()
        fileDebugLog("[AudioEngine] AVCaptureSession stopped")

        // Stop screen capture
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
            format: "QuickTime/AAC"
        )

        // Save markers if any were created during recording
        saveMarkers()

        // Cleanup
        screenStream = nil
        screenDelegate = nil
        captureSession = nil
        micCaptureDelegate = nil
        currentMicDeviceID = nil
        audioWriter.reset()
        isRecording = false
        recordingStartTime = nil
        markers = []

        logger.info("Recording stopped. Duration: \(duration)s, Size: \(fileSize) bytes")
        return metadata
    }
    
    /// Insert a timestamp marker (for "Mark Moment" feature)
    public func insertMarker(label: String) async {
        guard isRecording else { return }
        let timestamp = Date().timeIntervalSince(recordingStartTime ?? Date())
        let marker = Marker(timestamp: timestamp, label: label)
        markers.append(marker)
        logger.info("Marker inserted: '\(label)' at \(timestamp)s (total: \(self.markers.count))")
    }

    /// Get the markers file URL for a given recording URL
    public static func markersURL(for recordingURL: URL) -> URL {
        let baseName = recordingURL.deletingPathExtension().lastPathComponent
        return recordingURL.deletingLastPathComponent().appendingPathComponent("\(baseName)_markers.json")
    }

    /// Load markers for a recording
    public static func loadMarkers(for recordingURL: URL) -> [Marker] {
        let markersFile = markersURL(for: recordingURL)
        guard FileManager.default.fileExists(atPath: markersFile.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: markersFile)
            let markers = try JSONDecoder().decode([Marker].self, from: data)
            return markers
        } catch {
            return []
        }
    }

    /// Save markers to a JSON file alongside the recording
    private func saveMarkers() {
        guard let outputURL = outputURL, !markers.isEmpty else { return }
        let markersFile = Self.markersURL(for: outputURL)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(markers)
            try data.write(to: markersFile)
            logger.info("Saved \(self.markers.count) marker(s) to \(markersFile.lastPathComponent)")
        } catch {
            logger.warning("Failed to save markers: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Setup Methods

    private func setupMicrophoneCapture() async throws {
        fileDebugLog("[AudioEngine] Setting up microphone capture with AVCaptureSession...")

        // Check authorization status FIRST
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        fileDebugLog("[AudioEngine] Mic auth status: \(authStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")

        if authStatus == .notDetermined {
            fileDebugLog("[AudioEngine] Requesting microphone permission...")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            fileDebugLog("[AudioEngine] Permission result: \(granted ? "GRANTED" : "DENIED")")
            if !granted {
                throw CaptureError.permissionDenied
            }
        } else if authStatus == .denied || authStatus == .restricted {
            fileDebugLog("[AudioEngine] Microphone permission DENIED!")
            throw CaptureError.permissionDenied
        }

        // Get the default microphone
        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            fileDebugLog("[AudioEngine] No microphone found!")
            throw CaptureError.noDevicesFound
        }
        fileDebugLog("[AudioEngine] Found microphone: \(micDevice.localizedName)")
        logger.info("Using microphone: \(micDevice.localizedName)")

        // Create AVCaptureSession - this is designed for recording and shares nicely with other apps
        let session = AVCaptureSession()

        // Add microphone input
        let micInput: AVCaptureDeviceInput
        do {
            micInput = try AVCaptureDeviceInput(device: micDevice)
        } catch {
            fileDebugLog("[AudioEngine] Failed to create mic input: \(error.localizedDescription)")
            throw CaptureError.streamConfigurationFailed
        }

        guard session.canAddInput(micInput) else {
            fileDebugLog("[AudioEngine] Cannot add mic input to session")
            throw CaptureError.streamConfigurationFailed
        }
        session.addInput(micInput)
        fileDebugLog("[AudioEngine] Added microphone input to session")

        // Create audio output with delegate
        let audioOutput = AVCaptureAudioDataOutput()
        let delegate = MicrophoneCaptureDelegate(audioWriter: audioWriter, targetSampleRate: targetSampleRate)

        // Use a serial queue for audio processing
        let audioQueue = DispatchQueue(label: "dev.balakumar.engram.mic.audio", qos: .userInteractive)
        audioOutput.setSampleBufferDelegate(delegate, queue: audioQueue)

        guard session.canAddOutput(audioOutput) else {
            fileDebugLog("[AudioEngine] Cannot add audio output to session")
            throw CaptureError.streamConfigurationFailed
        }
        session.addOutput(audioOutput)
        fileDebugLog("[AudioEngine] Added audio output to session")

        // Store references
        captureSession = session
        micCaptureDelegate = delegate
        currentMicDeviceID = micDevice.uniqueID

        fileDebugLog("[AudioEngine] AVCaptureSession configured successfully (allows mic sharing with Zoom)")
        logger.info("Microphone capture with AVCaptureSession configured successfully")
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
        try stream.addStreamOutput(screenDelegate!, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.echo.screen.audio", qos: .utility))

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
    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "ScreenCapture")

    init(audioWriter: AudioWriter) {
        self.audioWriter = audioWriter
        super.init()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Ignore video buffers
        guard type == .audio else { return }
        
        bufferCount += 1
        if bufferCount == 1 {
            fileDebugLog("[ScreenCapture] First audio buffer received!")
        }

        // Write synchronously to system audio track
        audioWriter.writeSystemAudio(sampleBuffer)
    }
}

/// Delegate for AVCaptureSession microphone capture
/// Handles audio sample buffers and converts them to the target format for writing
@available(macOS 14.0, *)
final class MicrophoneCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let audioWriter: AudioWriter
    private let targetSampleRate: Double
    private var bufferCount = 0
    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "MicCapture")

    // For timing adjustment - we need to track our own presentation times
    private let lock = NSLock()
    private var startTime: CMTime?
    private var sampleCount: Int64 = 0

    // Cached converter to avoid creating new one on every buffer (reduces crackling)
    private var cachedConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private var cachedOutputFormat: AVAudioFormat?
    private var cachedFormatDesc: CMAudioFormatDescription?

    init(audioWriter: AudioWriter, targetSampleRate: Double) {
        self.audioWriter = audioWriter
        self.targetSampleRate = targetSampleRate
        super.init()

        // Pre-create output format (always 48kHz mono float)
        cachedOutputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )

        // Pre-create format description for output
        var asbd = AudioStreamBasicDescription(
            mSampleRate: targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        if CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr {
            cachedFormatDesc = formatDesc
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        bufferCount += 1
        if bufferCount == 1 {
            // Log the format of the first buffer
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
                let sampleRate = asbd?.mSampleRate ?? 0
                let channels = asbd?.mChannelsPerFrame ?? 0
                let bitsPerChannel = asbd?.mBitsPerChannel ?? 0
                fileDebugLog("[MicCapture] First buffer received! Format: \(sampleRate)Hz, \(channels) channels, \(bitsPerChannel) bits")
            }
        }

        // Get the format description to check if we need to convert
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return
        }

        let inputSampleRate = asbd.mSampleRate
        let inputChannels = asbd.mChannelsPerFrame

        // If the input format matches our target (48kHz mono), write directly
        // Otherwise, we need to convert
        if inputSampleRate == targetSampleRate && inputChannels == 1 {
            // Direct write - just adjust timing
            let adjustedBuffer = adjustTimingForMic(sampleBuffer)
            audioWriter.writeMicrophoneAudio(adjustedBuffer)
        } else {
            // Need to convert the audio to our target format (48kHz mono)
            if let convertedBuffer = convertToTargetFormat(sampleBuffer, asbd: asbd) {
                audioWriter.writeMicrophoneAudio(convertedBuffer)
            }
        }
    }

    /// Adjust sample buffer timing to start from zero (for consistent mic track timing)
    private func adjustTimingForMic(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        lock.lock()
        defer { lock.unlock() }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if startTime == nil {
            startTime = presentationTime
        }

        guard let start = startTime else {
            return sampleBuffer
        }

        let offset = CMTimeSubtract(presentationTime, start)

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

    /// Get or create a cached converter for the given input format
    private func getConverter(inputRate: Double, inputChannels: Int) -> AVAudioConverter? {
        // Check if we can reuse the cached converter
        if let cached = cachedConverter,
           let cachedInput = cachedInputFormat,
           cachedInput.sampleRate == inputRate,
           cachedInput.channelCount == AVAudioChannelCount(inputChannels) {
            return cached
        }

        // Need to create a new converter
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputRate,
            channels: AVAudioChannelCount(inputChannels),
            interleaved: false
        ) else {
            return nil
        }

        guard let outputFormat = cachedOutputFormat else {
            return nil
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        // Use high-quality sample rate conversion to reduce crackling
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal

        // Cache the converter
        cachedConverter = converter
        cachedInputFormat = inputFormat

        fileDebugLog("[MicCapture] Created new converter: \(inputRate)Hz \(inputChannels)ch -> \(targetSampleRate)Hz 1ch")

        return converter
    }

    /// Convert audio from input format to target format (48kHz mono)
    private func convertToTargetFormat(_ sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> CMSampleBuffer? {
        // Get the audio buffer list from the sample buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }

        let inputRate = asbd.mSampleRate
        let inputChannels = Int(asbd.mChannelsPerFrame)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let inputFrameCount = bytesPerFrame > 0 ? length / bytesPerFrame : 0

        guard inputFrameCount > 0, bytesPerFrame > 0 else {
            return nil
        }

        // Get or create converter
        guard let converter = getConverter(inputRate: inputRate, inputChannels: inputChannels),
              let inputFormat = cachedInputFormat,
              let outputFormat = cachedOutputFormat else {
            return nil
        }

        // Calculate output frame count based on sample rate ratio
        let ratio = targetSampleRate / inputRate
        let outputFrameCount = Int(ceil(Double(inputFrameCount) * ratio)) + 1 // +1 for rounding safety

        // Create input buffer
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inputFrameCount)) else {
            return nil
        }

        // Copy data to input buffer, handling format conversion
        let formatFlags = asbd.mFormatFlags
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        if (formatFlags & kAudioFormatFlagIsFloat) != 0 {
            // Float format - copy directly
            if inputChannels == 1 {
                if let floatData = inputBuffer.floatChannelData?[0] {
                    memcpy(floatData, data, min(length, Int(inputFrameCount) * MemoryLayout<Float>.size))
                }
            } else {
                // Multi-channel float - need to handle interleaved
                if let floatData = inputBuffer.floatChannelData {
                    let srcFloat = UnsafePointer<Float>(OpaquePointer(data))
                    for ch in 0..<inputChannels {
                        for frame in 0..<inputFrameCount {
                            floatData[ch][frame] = srcFloat[frame * inputChannels + ch]
                        }
                    }
                }
            }
        } else if (formatFlags & kAudioFormatFlagIsSignedInteger) != 0 {
            // Integer format - need to convert to float
            if bitsPerChannel == 16 {
                // Convert Int16 to Float32
                let int16Data = UnsafePointer<Int16>(OpaquePointer(data))
                if inputChannels == 1 {
                    if let floatData = inputBuffer.floatChannelData?[0] {
                        for i in 0..<inputFrameCount {
                            floatData[i] = Float(int16Data[i]) / 32768.0
                        }
                    }
                } else {
                    // Multi-channel int16 - deinterleave
                    if let floatData = inputBuffer.floatChannelData {
                        for ch in 0..<inputChannels {
                            for frame in 0..<inputFrameCount {
                                floatData[ch][frame] = Float(int16Data[frame * inputChannels + ch]) / 32768.0
                            }
                        }
                    }
                }
            } else if bitsPerChannel == 32 {
                // Convert Int32 to Float32
                let int32Data = UnsafePointer<Int32>(OpaquePointer(data))
                if inputChannels == 1 {
                    if let floatData = inputBuffer.floatChannelData?[0] {
                        for i in 0..<inputFrameCount {
                            floatData[i] = Float(int32Data[i]) / Float(Int32.max)
                        }
                    }
                } else {
                    if let floatData = inputBuffer.floatChannelData {
                        for ch in 0..<inputChannels {
                            for frame in 0..<inputFrameCount {
                                floatData[ch][frame] = Float(int32Data[frame * inputChannels + ch]) / Float(Int32.max)
                            }
                        }
                    }
                }
            } else {
                return nil
            }
        } else {
            return nil
        }

        inputBuffer.frameLength = AVAudioFrameCount(inputFrameCount)

        // Create output buffer with extra capacity
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outputFrameCount)) else {
            return nil
        }

        // Perform conversion
        var error: NSError?
        var inputConsumed = false
        let conversionStatus = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionStatus != .error, error == nil, outputBuffer.frameLength > 0 else {
            return nil
        }

        // Create CMSampleBuffer from output
        return createSampleBuffer(from: outputBuffer)
    }

    /// Create a CMSampleBuffer from an AVAudioPCMBuffer with proper timing
    private func createSampleBuffer(from buffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        guard let channelData = buffer.floatChannelData else { return nil }
        guard let formatDesc = cachedFormatDesc else { return nil }

        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return nil }

        // Calculate presentation time based on accumulated sample count
        lock.lock()
        let currentSampleTime = sampleCount
        sampleCount += Int64(frameCount)
        lock.unlock()

        let presentationTime = CMTime(value: currentSampleTime, timescale: CMTimeScale(targetSampleRate))

        // Copy audio data (mono)
        let dataSize = Int(frameCount) * MemoryLayout<Float>.size
        let audioData = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCount))
        defer { audioData.deallocate() }
        memcpy(audioData, channelData[0], dataSize)

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let block = blockBuffer else {
            return nil
        }

        // Copy data to block buffer
        guard CMBlockBufferReplaceDataBytes(
            with: audioData,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: dataSize
        ) == kCMBlockBufferNoErr else {
            return nil
        }

        // Create sample buffer
        var outputSampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &outputSampleBuffer
        ) == noErr else {
            return nil
        }

        return outputSampleBuffer
    }
}
