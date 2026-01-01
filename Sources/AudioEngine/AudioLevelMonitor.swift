import Foundation
@preconcurrency import ScreenCaptureKit
import Accelerate
import os.log

// Debug file logging for AudioLevelMonitor
private func audioDebugLog(_ message: String) {
    let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projectecho_debug.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [Audio] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

/// Lightweight audio monitoring for detecting meeting activity without recording to disk
@available(macOS 14.0, *)
public actor AudioLevelMonitor {

    // MARK: - Types

    public struct AudioLevel: Sendable {
        public let rms: Float           // Root Mean Square (0.0 - 1.0)
        public let peak: Float          // Peak level (0.0 - 1.0)
        public let decibels: Float      // Level in dB (typically -160 to 0)
        public let timestamp: Date

        public var isSilent: Bool {
            decibels < -40.0
        }
    }

    public enum MonitoringState: Sendable, Equatable {
        case idle
        case monitoring
        case audioDetected    // Sustained audio above threshold
        case silence          // Sustained silence below threshold
    }

    public struct Configuration: Sendable {
        public var silenceThresholdDB: Float = -40.0      // dB level below which is "silence"
        public var activityThresholdDB: Float = -35.0     // dB level above which is "activity"
        public var sustainedActivityDuration: TimeInterval = 2.0   // Seconds of audio to confirm meeting
        public var sustainedSilenceDuration: TimeInterval = 45.0   // Seconds of silence to end meeting
        public var sampleRate: Double = 48000.0

        public init(
            silenceThresholdDB: Float = -40.0,
            activityThresholdDB: Float = -35.0,
            sustainedActivityDuration: TimeInterval = 2.0,
            sustainedSilenceDuration: TimeInterval = 45.0,
            sampleRate: Double = 48000.0
        ) {
            self.silenceThresholdDB = silenceThresholdDB
            self.activityThresholdDB = activityThresholdDB
            self.sustainedActivityDuration = sustainedActivityDuration
            self.sustainedSilenceDuration = sustainedSilenceDuration
            self.sampleRate = sampleRate
        }
    }

    public enum MonitorError: Error, LocalizedError {
        case permissionDenied
        case appNotFound
        case noDisplayAvailable
        case streamConfigurationFailed
        case alreadyMonitoring

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen recording permission is required for audio monitoring"
            case .appNotFound:
                return "The specified application was not found"
            case .noDisplayAvailable:
                return "No display available for capture"
            case .streamConfigurationFailed:
                return "Failed to configure audio stream"
            case .alreadyMonitoring:
                return "Already monitoring audio"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.projectecho.app", category: "AudioLevelMonitor")
    private var configuration: Configuration

    private var screenStream: SCStream?
    private var monitorDelegate: AudioMonitorStreamDelegate?
    private var isMonitoring = false

    // State tracking
    private var currentState: MonitoringState = .idle
    private var audioActivityStartTime: Date?
    private var silenceStartTime: Date?
    private var lastAudioLevel: AudioLevel?
    private var monitoredAppName: String?

    // AsyncStream continuations
    private var levelContinuation: AsyncStream<AudioLevel>.Continuation?
    private var stateContinuation: AsyncStream<MonitoringState>.Continuation?

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Public Methods

    /// Start monitoring audio from a specific app
    public func startMonitoring(for appName: String) async throws {
        guard !isMonitoring else {
            audioDebugLog("Already monitoring, throwing error")
            throw MonitorError.alreadyMonitoring
        }

        audioDebugLog("Starting audio monitoring for: \(appName)")
        monitoredAppName = appName

        try await setupMonitoringStream(for: appName)
        audioDebugLog("Stream setup complete for: \(appName)")

        try await screenStream?.startCapture()
        audioDebugLog("Screen capture started")
        isMonitoring = true
        currentState = .monitoring
        stateContinuation?.yield(.monitoring)

        audioDebugLog("Audio monitoring started successfully for: \(appName)")
    }

    /// Start monitoring all system audio
    public func startMonitoringSystemAudio() async throws {
        guard !isMonitoring else {
            throw MonitorError.alreadyMonitoring
        }

        logger.info("Starting system audio monitoring")
        monitoredAppName = nil

        try await setupMonitoringStream(for: nil)

        try await screenStream?.startCapture()
        isMonitoring = true
        currentState = .monitoring
        stateContinuation?.yield(.monitoring)

        logger.info("System audio monitoring started")
    }

    /// Stop monitoring
    public func stopMonitoring() async {
        guard isMonitoring else { return }

        logger.info("Stopping audio monitoring")

        try? await screenStream?.stopCapture()
        screenStream = nil
        monitorDelegate = nil

        isMonitoring = false
        currentState = .idle
        audioActivityStartTime = nil
        silenceStartTime = nil
        monitoredAppName = nil

        stateContinuation?.yield(.idle)

        logger.info("Audio monitoring stopped")
    }

    /// Get current monitoring state
    public func getState() -> MonitoringState {
        return currentState
    }

    /// Get last audio level reading
    public func getLastLevel() -> AudioLevel? {
        return lastAudioLevel
    }

    /// Check if currently monitoring
    public func isCurrentlyMonitoring() -> Bool {
        return isMonitoring
    }

    /// Stream of real-time audio levels
    public func audioLevelStream() -> AsyncStream<AudioLevel> {
        AsyncStream { continuation in
            self.levelContinuation = continuation

            continuation.onTermination = { @Sendable _ in
                Task { await self.clearLevelContinuation() }
            }
        }
    }

    /// Stream of state changes
    public func stateStream() -> AsyncStream<MonitoringState> {
        AsyncStream { continuation in
            self.stateContinuation = continuation

            // Emit current state immediately
            continuation.yield(currentState)

            continuation.onTermination = { @Sendable _ in
                Task { await self.clearStateContinuation() }
            }
        }
    }

    /// Update configuration
    public func updateConfiguration(_ newConfig: Configuration) {
        self.configuration = newConfig
    }

    // MARK: - Private Methods

    private func clearLevelContinuation() {
        levelContinuation = nil
    }

    private func clearStateContinuation() {
        stateContinuation = nil
    }

    private func setupMonitoringStream(for appName: String?) async throws {
        audioDebugLog("setupMonitoringStream called for: \(appName ?? "system")")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        audioDebugLog("Got \(content.applications.count) applications from SCShareableContent")

        guard let display = content.displays.first else {
            audioDebugLog("ERROR: No display available")
            throw MonitorError.noDisplayAvailable
        }

        // Determine filter
        let filter: SCContentFilter
        if let appName = appName {
            // Find target app by name (case-insensitive partial match)
            audioDebugLog("Looking for app containing: \(appName)")

            // Log all apps for debugging
            for app in content.applications.prefix(20) {
                audioDebugLog("  Available app: \(app.applicationName) (\(app.bundleIdentifier))")
            }

            guard let app = content.applications.first(where: {
                $0.applicationName.localizedCaseInsensitiveContains(appName)
            }) else {
                audioDebugLog("ERROR: App not found: \(appName)")
                throw MonitorError.appNotFound
            }

            audioDebugLog("Found app: \(app.applicationName) with bundleId: \(app.bundleIdentifier)")

            // Filter to just this app
            let excludedApps = content.applications.filter { $0.bundleIdentifier != app.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            audioDebugLog("Created filter excluding \(excludedApps.count) other apps")
        } else {
            // Global capture (all system audio)
            filter = SCContentFilter(display: display, excludingWindows: [])
            logger.info("Monitoring all system audio")
        }

        // Configure for audio-only with minimal overhead
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(configuration.sampleRate)
        config.channelCount = 1  // Mono is sufficient for level monitoring
        config.excludesCurrentProcessAudio = true

        // Minimize video capture overhead (required by SCStream but we ignore it)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 FPS minimum
        config.showsCursor = false

        // Create stream
        screenStream = SCStream(filter: filter, configuration: config, delegate: nil)

        // Create delegate for audio processing
        monitorDelegate = AudioMonitorStreamDelegate { [weak self] buffer in
            Task { await self?.processAudioBuffer(buffer) }
        }

        // Add stream output for audio
        try screenStream?.addStreamOutput(
            monitorDelegate!,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "com.echo.monitor.audio", qos: .userInteractive)
        )

        logger.info("Audio monitoring stream configured")
    }

    private func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        let level = calculateAudioLevel(from: sampleBuffer)
        lastAudioLevel = level

        // Emit level to stream
        levelContinuation?.yield(level)

        // Update state based on audio level
        updateStateFromLevel(level)
    }

    private func updateStateFromLevel(_ level: AudioLevel) {
        let now = Date()
        let hasActivity = level.decibels >= configuration.activityThresholdDB
        let isSilent = level.decibels < configuration.silenceThresholdDB

        // Debug: log audio levels every 3 seconds
        if Int(now.timeIntervalSince1970) % 3 == 0 {
            audioDebugLog("dB=\(String(format: "%.1f", level.decibels)), hasActivity=\(hasActivity), state=\(currentState), threshold=\(configuration.activityThresholdDB)")
        }

        switch currentState {
        case .idle:
            break // Should not receive levels while idle

        case .monitoring:
            if hasActivity {
                // Start tracking activity duration
                if audioActivityStartTime == nil {
                    audioActivityStartTime = now
                    audioDebugLog("Activity started tracking at dB=\(String(format: "%.1f", level.decibels))")
                }
                silenceStartTime = nil

                // Check if sustained activity
                if let startTime = audioActivityStartTime,
                   now.timeIntervalSince(startTime) >= configuration.sustainedActivityDuration {
                    currentState = .audioDetected
                    stateContinuation?.yield(.audioDetected)
                    audioDebugLog("SUSTAINED AUDIO DETECTED - transitioning to audioDetected after \(now.timeIntervalSince(startTime))s")
                    logger.info("Sustained audio detected - meeting likely in progress")
                }
            } else {
                // Reset activity tracking
                if audioActivityStartTime != nil {
                    audioDebugLog("Activity tracking reset (audio dropped to dB=\(String(format: "%.1f", level.decibels)))")
                }
                audioActivityStartTime = nil
            }

        case .audioDetected:
            if isSilent {
                // Start tracking silence duration
                if silenceStartTime == nil {
                    silenceStartTime = now
                }
                audioActivityStartTime = nil

                // Check if sustained silence
                if let startTime = silenceStartTime,
                   now.timeIntervalSince(startTime) >= configuration.sustainedSilenceDuration {
                    currentState = .silence
                    stateContinuation?.yield(.silence)
                    logger.info("Sustained silence detected - meeting likely ended")
                }
            } else if hasActivity {
                // Reset silence tracking, still have activity
                silenceStartTime = nil
                audioActivityStartTime = now
            }

        case .silence:
            if hasActivity {
                // Audio resumed
                currentState = .audioDetected
                silenceStartTime = nil
                audioActivityStartTime = now
                stateContinuation?.yield(.audioDetected)
                logger.info("Audio resumed after silence")
            }
        }
    }

    /// Calculate audio levels from a sample buffer
    private func calculateAudioLevel(from sampleBuffer: CMSampleBuffer) -> AudioLevel {
        guard let audioBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return AudioLevel(rms: 0, peak: 0, decibels: -160, timestamp: Date())
        }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(
            audioBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard let data = dataPointer, totalLength > 0 else {
            return AudioLevel(rms: 0, peak: 0, decibels: -160, timestamp: Date())
        }

        // Assuming Float32 samples
        let sampleCount = totalLength / MemoryLayout<Float32>.size
        guard sampleCount > 0 else {
            return AudioLevel(rms: 0, peak: 0, decibels: -160, timestamp: Date())
        }

        // Use Accelerate framework for efficient RMS calculation
        let floatPointer = data.withMemoryRebound(to: Float32.self, capacity: sampleCount) { $0 }

        var rms: Float = 0
        vDSP_rmsqv(floatPointer, 1, &rms, vDSP_Length(sampleCount))

        var peak: Float = 0
        vDSP_maxmgv(floatPointer, 1, &peak, vDSP_Length(sampleCount))

        // Convert RMS to decibels (avoid log of zero)
        let decibels = 20 * log10(max(rms, 0.0000001))

        return AudioLevel(rms: rms, peak: peak, decibels: decibels, timestamp: Date())
    }

    /// Static utility for calculating audio levels (for use by other components)
    public static func calculateRMS(from sampleBuffer: CMSampleBuffer) -> (rms: Float, peak: Float, decibels: Float) {
        guard let audioBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return (0, 0, -160)
        }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(
            audioBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard let data = dataPointer, totalLength > 0 else {
            return (0, 0, -160)
        }

        let sampleCount = totalLength / MemoryLayout<Float32>.size
        guard sampleCount > 0 else {
            return (0, 0, -160)
        }

        let floatPointer = data.withMemoryRebound(to: Float32.self, capacity: sampleCount) { $0 }

        var rms: Float = 0
        vDSP_rmsqv(floatPointer, 1, &rms, vDSP_Length(sampleCount))

        var peak: Float = 0
        vDSP_maxmgv(floatPointer, 1, &peak, vDSP_Length(sampleCount))

        let decibels = 20 * log10(max(rms, 0.0000001))

        return (rms, peak, decibels)
    }
}

// MARK: - Stream Delegate

@available(macOS 14.0, *)
private final class AudioMonitorStreamDelegate: NSObject, SCStreamOutput {
    private let handler: @Sendable (CMSampleBuffer) -> Void

    init(handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only process audio buffers
        guard type == .audio else { return }
        handler(sampleBuffer)
    }
}
