import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreMedia
import os.log

// Debug logging to file for ScreenRecorder
private func screenDebugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [ScreenRecorder] \(message)\n"
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

/// Thread-safe video-only writer using AVAssetWriter
@available(macOS 14.0, *)
final class VideoWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.projectecho.app", category: "VideoWriter")

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var isWriting = false
    private var frameCount = 0
    private var videoStartTime: CMTime?

    func configure(outputURL: URL, width: Int, height: Int, frameRate: Double, bitrate: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        assetWriter = try AVAssetWriter(url: outputURL, fileType: .mov)

        // Video track settings - using H.264 High Profile for better quality
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2  // Keyframe every 2 seconds for better seeking
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput!,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        if let input = videoInput, assetWriter?.canAdd(input) == true {
            assetWriter?.add(input)
        }

        logger.info("Video writer configured: \(width)x\(height) @ \(frameRate)fps, \(bitrate/1000)kbps (video-only)")
    }

    func startWriting() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard assetWriter?.startWriting() == true else {
            logger.error("Failed to start asset writer: \(self.assetWriter?.error?.localizedDescription ?? "unknown")")
            screenDebugLog("VideoWriter: ERROR - startWriting failed: \(self.assetWriter?.error?.localizedDescription ?? "unknown")")
            return false
        }

        assetWriter?.startSession(atSourceTime: .zero)
        isWriting = true
        frameCount = 0
        videoStartTime = nil
        screenDebugLog("VideoWriter: AVAssetWriter started successfully (video-only)")
        logger.info("Video writer started (video-only)")
        return true
    }

    func writeVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard isWriting else {
            if frameCount == 0 {
                screenDebugLog("VideoWriter: isWriting is false, skipping frame")
            }
            return
        }

        guard let input = videoInput, input.isReadyForMoreMediaData else {
            if frameCount == 0 {
                screenDebugLog("VideoWriter: videoInput not ready for more data")
            }
            return
        }

        // Calculate adjusted time
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if videoStartTime == nil {
            videoStartTime = presentationTime
            screenDebugLog("VideoWriter: First video frame, starting at \(presentationTime.seconds)s")
        }

        guard let start = videoStartTime else { return }
        let adjustedTime = CMTimeSubtract(presentationTime, start)

        // Get pixel buffer and append
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
           let adaptor = pixelBufferAdaptor {
            if adaptor.append(imageBuffer, withPresentationTime: adjustedTime) {
                frameCount += 1
                if frameCount == 1 {
                    logger.info("First video frame written")
                    screenDebugLog("VideoWriter: ✅ First video frame WRITTEN successfully!")
                } else if frameCount % 100 == 0 {
                    logger.debug("\(self.frameCount) video frames written")
                    screenDebugLog("VideoWriter: \(frameCount) video frames written")
                }
            } else {
                if frameCount == 0 {
                    screenDebugLog("VideoWriter: ERROR - pixelBufferAdaptor.append FAILED, assetWriter status: \(String(describing: assetWriter?.status.rawValue)), error: \(String(describing: assetWriter?.error))")
                }
            }
        } else {
            if frameCount == 0 {
                screenDebugLog("VideoWriter: ERROR - Could not get imageBuffer from sampleBuffer or adaptor is nil")
            }
        }
    }

    func finishWriting() async {
        screenDebugLog("VideoWriter: finishWriting called, frameCount=\(frameCount)")
        let writer: AVAssetWriter? = {
            lock.lock()
            defer { lock.unlock() }
            screenDebugLog("VideoWriter: Setting isWriting=false and marking video input as finished")
            isWriting = false
            videoInput?.markAsFinished()
            return assetWriter
        }()

        if let w = writer {
            screenDebugLog("VideoWriter: Calling finishWriting on asset writer, status before: \(w.status.rawValue)")
            await w.finishWriting()
            screenDebugLog("VideoWriter: finishWriting completed, status after: \(w.status.rawValue), error: \(String(describing: w.error))")
        } else {
            screenDebugLog("VideoWriter: ERROR - assetWriter is nil!")
        }
        logger.info("Video writer finished. Total frames: \(self.frameCount)")
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }

        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        isWriting = false
        videoStartTime = nil
        frameCount = 0
    }

    var totalFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }
}

/// Delegate to receive video frames from SCStream
@available(macOS 14.0, *)
final class VideoStreamDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    private let videoWriter: VideoWriter
    private let logger = Logger(subsystem: "com.projectecho.app", category: "VideoStreamDelegate")
    private var videoFrameCount = 0

    init(videoWriter: VideoWriter) {
        self.videoWriter = videoWriter
        super.init()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only handle video frames - audio is captured separately by AudioCaptureEngine
        guard type == .screen else { return }

        videoFrameCount += 1
        if videoFrameCount == 1 {
            logger.info("[VideoStreamDelegate] First video frame received")
            screenDebugLog("First video frame received!")
        } else if videoFrameCount % 100 == 0 {
            screenDebugLog("\(videoFrameCount) video frames received")
        }
        videoWriter.writeVideoFrame(sampleBuffer)
    }
}

/// Main screen recorder actor for capturing Zoom window video (video-only, audio muxed post-recording)
@available(macOS 14.0, *)
public actor ScreenRecorder {

    // MARK: - Types

    public enum RecorderError: Error, LocalizedError {
        case windowNotFound
        case permissionDenied
        case recordingAlreadyActive
        case noActiveRecording
        case encodingFailed
        case streamConfigurationFailed

        public var errorDescription: String? {
            switch self {
            case .windowNotFound: return "Zoom meeting window not found"
            case .permissionDenied: return "Screen recording permission denied"
            case .recordingAlreadyActive: return "Recording is already active"
            case .noActiveRecording: return "No active recording to stop"
            case .encodingFailed: return "Video encoding failed"
            case .streamConfigurationFailed: return "Failed to configure screen capture stream"
            }
        }
    }

    public struct VideoMetadata: Sendable {
        public let duration: TimeInterval
        public let width: Int
        public let height: Int
        public let frameRate: Double
        public let fileSize: Int64
        public let frameCount: Int
    }

    public struct Configuration: Sendable {
        public var width: Int
        public var height: Int
        public var frameRate: Double
        public var bitrate: Int

        public init(
            width: Int = 1920,
            height: Int = 1080,
            frameRate: Double = 30.0,
            bitrate: Int = 8_000_000  // 8 Mbps for high quality 1080p
        ) {
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.bitrate = bitrate
        }
    }

    /// Represents a candidate window for recording
    public struct CandidateWindow: Identifiable, Sendable {
        public let id: UInt32
        public let title: String
        public let width: Int
        public let height: Int
        public let appName: String?
        public let thumbnail: CGImage?

        public init(id: UInt32, title: String, width: Int, height: Int, appName: String?, thumbnail: CGImage?) {
            self.id = id
            self.title = title
            self.width = width
            self.height = height
            self.appName = appName
            self.thumbnail = thumbnail
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.projectecho.app", category: "ScreenRecorder")

    private var windowStream: SCStream?
    private var videoWriter: VideoWriter?
    private var streamDelegate: VideoStreamDelegate?

    private var isRecording = false
    private var recordingStartTime: Date?
    private var outputURL: URL?
    private let configuration: Configuration

    // Generic meeting-related keywords (works for any app)
    private let meetingKeywords = [
        // Common meeting terms
        "meeting", "call", "conference", "webinar", "huddle", "standup",
        // Platform names
        "zoom", "meet", "teams", "slack", "discord", "webex", "facetime", "skype",
        // Meeting indicators
        "participant", "recording", "screen share", "presenting",
    ]

    // Windows to skip (definitely not meeting windows)
    private let skipPatterns = [
        // Browser UI
        "new tab", "downloads", "settings", "extensions", "preferences",
        "history", "bookmarks", "devtools", "inspector",
        // App UI
        "sign in", "sign up", "login", "home -", "welcome",
        // System
        "notification", "alert",
    ]

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Public Methods

    /// Check if currently recording
    public func isCurrentlyRecording() -> Bool {
        return isRecording
    }

    /// Get candidate windows for a bundle ID (for user selection)
    /// Returns windows sorted by likelihood of being a meeting window
    public func getCandidateWindows(bundleId: String) async throws -> [CandidateWindow] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch let error as NSError {
            if error.code == -3801 || error.domain == "com.apple.screencapturekit" {
                throw RecorderError.permissionDenied
            }
            throw error
        }

        // Get all windows for this app
        let appWindows = content.windows.filter { window in
            guard window.owningApplication?.bundleIdentifier == bundleId else { return false }
            guard window.frame.width > 100 && window.frame.height > 100 else { return false }
            return true
        }

        // Filter out skip patterns
        let candidateWindows = appWindows.filter { window in
            guard let title = window.title?.lowercased(), !title.isEmpty else { return true }
            return !skipPatterns.contains { title.contains($0) }
        }

        // Sort: meeting keyword matches first, then by size
        let sorted = candidateWindows.sorted { w1, w2 in
            let t1 = w1.title?.lowercased() ?? ""
            let t2 = w2.title?.lowercased() ?? ""
            let hasMeetingKeyword1 = meetingKeywords.contains { t1.contains($0) }
            let hasMeetingKeyword2 = meetingKeywords.contains { t2.contains($0) }

            if hasMeetingKeyword1 != hasMeetingKeyword2 {
                return hasMeetingKeyword1
            }
            return (w1.frame.width * w1.frame.height) > (w2.frame.width * w2.frame.height)
        }

        // Generate thumbnails for each window
        var candidates: [CandidateWindow] = []
        for window in sorted {
            // Capture thumbnail
            let thumbnail = try? await captureWindowThumbnail(window: window)

            candidates.append(CandidateWindow(
                id: window.windowID,
                title: window.title ?? "Untitled",
                width: Int(window.frame.width),
                height: Int(window.frame.height),
                appName: window.owningApplication?.applicationName,
                thumbnail: thumbnail
            ))
        }

        return candidates
    }

    /// Capture a thumbnail of a window
    private func captureWindowThumbnail(window: SCWindow) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = 320  // Thumbnail size
        config.height = 180
        config.scalesToFit = true
        config.showsCursor = false

        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Start recording a specific window by ID (video-only)
    public func startRecordingWindow(
        windowId: UInt32,
        bundleId: String,
        outputDirectory: URL,
        baseFilename: String? = nil
    ) async throws -> URL {
        guard !isRecording else {
            throw RecorderError.recordingAlreadyActive
        }

        // Find the specific window
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowId }) else {
            throw RecorderError.windowNotFound
        }

        logger.info("Starting screen recording for window: \(window.title ?? "untitled") (ID: \(windowId))")
        screenDebugLog("Starting screen recording for window ID \(windowId): '\(window.title ?? "untitled")'")

        return try await startRecordingWithWindow(window: window, outputDirectory: outputDirectory, baseFilename: baseFilename)
    }

    /// Start recording a specific app's window (video-only)
    /// Audio is captured separately by AudioCaptureEngine and muxed post-recording
    /// - Parameters:
    ///   - bundleId: The bundle identifier of the app to record
    ///   - outputDirectory: Directory to save the video file
    ///   - baseFilename: Optional base filename (without extension) to match audio file naming
    public func startRecording(
        bundleId: String = "us.zoom.xos",
        outputDirectory: URL,
        baseFilename: String? = nil
    ) async throws -> URL {
        guard !isRecording else {
            throw RecorderError.recordingAlreadyActive
        }

        logger.info("Starting screen recording for bundle: \(bundleId) (video-only)")
        screenDebugLog("Starting screen recording for bundle: \(bundleId) (video-only)")

        // Find the best meeting window
        let window: SCWindow
        do {
            window = try await findMeetingWindow(bundleId: bundleId)
            logger.info("Found meeting window: \(window.title ?? "untitled")")
            screenDebugLog("Found meeting window: \(window.title ?? "untitled")")
        } catch {
            screenDebugLog("ERROR: Failed to find meeting window: \(error)")
            throw error
        }

        return try await startRecordingWithWindow(window: window, outputDirectory: outputDirectory, baseFilename: baseFilename)
    }

    /// Internal method to start recording a specific SCWindow
    private func startRecordingWithWindow(
        window: SCWindow,
        outputDirectory: URL,
        baseFilename: String?
    ) async throws -> URL {
        // Create window-specific filter
        let filter = SCContentFilter(desktopIndependentWindow: window)

        // Configure for video-only capture (audio handled separately by AudioCaptureEngine)
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = configuration.width
        streamConfig.height = configuration.height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: Int32(configuration.frameRate))
        streamConfig.showsCursor = true
        streamConfig.scalesToFit = true

        // Disable audio capture - audio will be muxed from AudioCaptureEngine's output
        streamConfig.capturesAudio = false

        // Setup video writer - use provided filename or generate new one
        let filename: String
        if let base = baseFilename {
            filename = "\(base)_video.mov"
        } else {
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            filename = "Echo_\(timestamp)_video.mov"
        }
        let fileURL = outputDirectory.appendingPathComponent(filename)

        let writer = VideoWriter()
        try writer.configure(
            outputURL: fileURL,
            width: configuration.width,
            height: configuration.height,
            frameRate: configuration.frameRate,
            bitrate: configuration.bitrate
        )
        videoWriter = writer

        // Create stream
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        let delegate = VideoStreamDelegate(videoWriter: writer)
        streamDelegate = delegate

        // Add output handler for video only
        let outputQueue = DispatchQueue(label: "com.echo.screen.output", qos: .utility)
        try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: outputQueue)

        // Start writing
        screenDebugLog("Starting asset writer...")
        guard writer.startWriting() else {
            screenDebugLog("ERROR: Failed to start asset writer")
            throw RecorderError.encodingFailed
        }
        screenDebugLog("Asset writer started successfully")

        // Start capture
        do {
            screenDebugLog("Starting SCStream capture...")
            try await stream.startCapture()
            screenDebugLog("SCStream capture started successfully")
        } catch {
            logger.error("Failed to start capture: \(error.localizedDescription)")
            screenDebugLog("ERROR: Failed to start SCStream capture: \(error)")
            writer.reset()
            throw RecorderError.streamConfigurationFailed
        }

        windowStream = stream
        outputURL = fileURL
        isRecording = true
        recordingStartTime = Date()

        logger.info("Screen recording started (video-only): \(filename)")
        return fileURL
    }

    /// Stop recording
    public func stopRecording() async throws -> VideoMetadata {
        guard isRecording else {
            throw RecorderError.noActiveRecording
        }

        logger.info("Stopping screen recording...")
        screenDebugLog("Stopping screen recording...")

        // Stop capture
        if let stream = windowStream {
            try? await stream.stopCapture()
        }

        // Small delay to ensure all frames are processed
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Finalize video writer
        await videoWriter?.finishWriting()

        // Calculate metadata
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        let fileSize: Int64 = {
            guard let url = outputURL else { return 0 }
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }()

        let metadata = VideoMetadata(
            duration: duration,
            width: configuration.width,
            height: configuration.height,
            frameRate: configuration.frameRate,
            fileSize: fileSize,
            frameCount: videoWriter?.totalFrames ?? 0
        )

        // Cleanup
        windowStream = nil
        streamDelegate = nil
        videoWriter?.reset()
        videoWriter = nil
        isRecording = false
        recordingStartTime = nil

        logger.info("Screen recording stopped. Duration: \(duration)s, Size: \(fileSize) bytes, Frames: \(metadata.frameCount)")
        return metadata
    }

    // MARK: - Private Methods

    /// Find the best window to record for a given app bundle ID
    /// Uses heuristics: meeting keywords in title, then falls back to largest window
    private func findMeetingWindow(bundleId: String) async throws -> SCWindow {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch let error as NSError {
            // Check if it's a permission error (code -3801)
            if error.code == -3801 || error.domain == "com.apple.screencapturekit" {
                logger.error("Screen recording permission denied")
                throw RecorderError.permissionDenied
            }
            throw error
        }

        // Get all windows for this app
        let appWindows = content.windows.filter { window in
            guard window.owningApplication?.bundleIdentifier == bundleId else { return false }
            guard window.frame.width > 100 && window.frame.height > 100 else { return false } // Skip tiny windows
            return true
        }

        screenDebugLog("Found \(appWindows.count) windows for \(bundleId)")
        for window in appWindows {
            screenDebugLog("  - '\(window.title ?? "untitled")' (\(Int(window.frame.width))x\(Int(window.frame.height)))")
        }

        guard !appWindows.isEmpty else {
            logger.warning("No windows found for bundle: \(bundleId)")
            throw RecorderError.windowNotFound
        }

        // Filter out windows we should skip
        let candidateWindows = appWindows.filter { window in
            guard let title = window.title?.lowercased(), !title.isEmpty else { return true } // Keep untitled windows
            return !skipPatterns.contains { title.contains($0) }
        }

        screenDebugLog("After filtering skip patterns: \(candidateWindows.count) candidate windows")

        // Priority 1: Look for windows with meeting-related keywords in title
        for window in candidateWindows {
            guard let title = window.title?.lowercased() else { continue }
            if meetingKeywords.contains(where: { title.contains($0) }) {
                logger.info("Found meeting window (keyword match): \(window.title ?? "untitled")")
                screenDebugLog("Selected window (keyword match): '\(window.title ?? "untitled")'")
                return window
            }
        }

        // Priority 2: Pick the largest window (likely the main content window)
        if let largestWindow = candidateWindows.max(by: {
            ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
        }) {
            logger.info("Using largest window: \(largestWindow.title ?? "untitled") (\(Int(largestWindow.frame.width))x\(Int(largestWindow.frame.height)))")
            screenDebugLog("Selected window (largest): '\(largestWindow.title ?? "untitled")' (\(Int(largestWindow.frame.width))x\(Int(largestWindow.frame.height)))")
            return largestWindow
        }

        // Fallback: use first available window
        if let firstWindow = appWindows.first {
            logger.info("Using first available window: \(firstWindow.title ?? "untitled")")
            screenDebugLog("Selected window (fallback): '\(firstWindow.title ?? "untitled")'")
            return firstWindow
        }

        throw RecorderError.windowNotFound
    }
}
