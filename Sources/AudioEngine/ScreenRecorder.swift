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

        // Video track settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
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
            bitrate: Int = 8_000_000  // 8 Mbps for readable text
        ) {
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.bitrate = bitrate
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

    // Meeting window title patterns (same as WindowTitleMonitor)
    private let meetingPatterns = [
        "Zoom Meeting", "Meeting ID:", "Zoom Webinar", "Waiting Room"
    ]
    private let lobbyPatterns = [
        "Zoom Cloud Meetings", "Home - Zoom", "Zoom Workplace",
        "Settings", "Schedule Meeting", "Join Meeting", "Host a Meeting",
        "Sign In", "Sign Up"
    ]
    private let meetingSuffixes = [" - Zoom", " | Zoom"]

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Public Methods

    /// Check if currently recording
    public func isCurrentlyRecording() -> Bool {
        return isRecording
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

        // Find the Zoom meeting window
        let window: SCWindow
        do {
            window = try await findMeetingWindow(bundleId: bundleId)
            logger.info("Found meeting window: \(window.title ?? "untitled")")
            screenDebugLog("Found meeting window: \(window.title ?? "untitled")")
        } catch {
            screenDebugLog("ERROR: Failed to find meeting window: \(error)")
            throw error
        }

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
        let outputQueue = DispatchQueue(label: "com.echo.screen.output", qos: .userInitiated)
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

    /// Find Zoom meeting window using SCShareableContent
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

        logger.debug("Searching for window in \(content.windows.count) windows")

        // Find meeting window
        for window in content.windows {
            guard window.owningApplication?.bundleIdentifier == bundleId else { continue }
            guard let title = window.title, !title.isEmpty else { continue }

            // Skip lobby/non-meeting windows
            if lobbyPatterns.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                logger.debug("Skipping lobby window: \(title)")
                continue
            }

            // Check for explicit meeting patterns
            if meetingPatterns.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                logger.debug("Found meeting window (pattern match): \(title)")
                return window
            }

            // Check for meeting suffix (e.g., "Weekly Standup - Zoom")
            if meetingSuffixes.contains(where: { title.hasSuffix($0) }) {
                logger.debug("Found meeting window (suffix match): \(title)")
                return window
            }
        }

        // Log available Zoom windows for debugging
        let zoomWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleId }
        logger.warning("No meeting window found. Available Zoom windows: \(zoomWindows.map { $0.title ?? "untitled" })")

        throw RecorderError.windowNotFound
    }
}
