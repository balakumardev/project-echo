// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import Foundation
import AppKit
import AudioEngine
import Database
import UI
import os.log

/// Coordinates recording lifecycle: start, stop, save to DB, queue transcription.
/// Handles manual recording (menu bar start/stop) and meeting-triggered recording.
@MainActor
@available(macOS 14.0, *)
class RecordingCoordinator {

    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Recording")

    // MARK: - Dependencies

    let audioEngine: AudioCaptureEngine
    let screenRecorder: ScreenRecorder
    let mediaMuxer: MediaMuxer
    let database: DatabaseManager
    let outputDirectory: URL

    // MARK: - State

    var currentRecordingURL: URL?
    var currentVideoRecordingURL: URL?
    var currentRecordingApp: String?

    // MARK: - Callbacks

    /// Called when the menu bar recording indicator needs updating.
    var onRecordingStateChanged: ((Bool) -> Void)?

    /// Called when an error alert should be shown.
    var onError: ((String) -> Void)?

    /// Called when a permission alert should be shown.
    var onPermissionError: (() -> Void)?

    /// Called to reset meeting detector state after manual stop.
    var onRecordingStopped: (() async -> Void)?

    // MARK: - Settings (read from AppStorage via UserDefaults)

    private var recordVideoEnabled: Bool {
        UserDefaults.standard.bool(forKey: "recordVideoEnabled")
    }

    private var windowSelectionMode: String {
        UserDefaults.standard.string(forKey: "windowSelectionMode") ?? "smart"
    }

    // MARK: - Init

    init(
        audioEngine: AudioCaptureEngine,
        screenRecorder: ScreenRecorder,
        mediaMuxer: MediaMuxer,
        database: DatabaseManager,
        outputDirectory: URL
    ) {
        self.audioEngine = audioEngine
        self.screenRecorder = screenRecorder
        self.mediaMuxer = mediaMuxer
        self.database = database
        self.outputDirectory = outputDirectory
    }

    // MARK: - Manual Recording (MenuBar)

    /// Start a manual recording triggered by the menu bar button.
    func startManualRecording() {
        Task {
            do {
                try await audioEngine.requestPermissions()
                currentRecordingURL = try await audioEngine.startRecording(outputDirectory: outputDirectory)
                logger.info("Recording started: \(self.currentRecordingURL?.lastPathComponent ?? "unknown")")
            } catch AudioCaptureEngine.CaptureError.permissionDenied {
                logger.error("Permission denied for recording")
                onRecordingStateChanged?(false)
                onPermissionError?()
            } catch let error as NSError {
                logger.error("Failed to start recording: \(error)")
                onRecordingStateChanged?(false)
                if error.code == -3801 || error.localizedDescription.contains("TCC") || error.localizedDescription.contains("declined") {
                    onPermissionError?()
                } else {
                    onError?("Failed to start recording: \(error.localizedDescription)")
                }
            } catch {
                logger.error("Failed to start recording: \(error.localizedDescription)")
                onRecordingStateChanged?(false)
                onError?("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }

    /// Stop a manual recording triggered by the menu bar button.
    func stopManualRecording() {
        Task {
            do {
                let metadata = try await audioEngine.stopRecording()
                logger.info("Recording stopped: \(metadata.duration)s")

                await finalizeVideoRecording()
                await saveRecordingToDatabase(metadata: metadata)

                currentRecordingURL = nil
                currentRecordingApp = nil

                // Notify meeting detector to reset
                await onRecordingStopped?()

            } catch {
                logger.error("Failed to stop recording: \(error.localizedDescription)")
                onError?("Failed to stop recording: \(error.localizedDescription)")
            }
        }
    }

    /// Insert a marker at the current recording position.
    func insertMarker() {
        let engine = audioEngine
        let log = logger
        Task {
            await engine.insertMarker(label: "User Marker")
            log.info("Marker inserted")
        }
    }

    // MARK: - Meeting Recording

    /// Start recording for a detected meeting. Called by MeetingDetector.
    /// - Parameter appName: The name of the meeting app detected.
    /// - Parameter getMeetingBundleID: Closure to get the detected bundle ID from MeetingDetector.
    /// - Returns: The URL of the audio recording file.
    func startMeetingRecording(for appName: String, getMeetingBundleID: () async -> String?) async throws -> URL {
        logger.info("Starting meeting recording for: \(appName)")

        try await audioEngine.requestPermissions()

        let detectedBundleID = await getMeetingBundleID()

        // Determine bundle ID for screen recording
        let screenRecordBundleID: String?
        if let detected = detectedBundleID, !detected.isEmpty {
            screenRecordBundleID = detected
            logger.info("Using detected bundle ID for screen recording: \(detected)")
        } else if appName.lowercased().contains("zoom") {
            screenRecordBundleID = "us.zoom.xos"
        } else {
            if let app = MeetingDetector.supportedApps.first(where: {
                appName.localizedCaseInsensitiveContains($0.displayName)
            }), !app.bundleId.isEmpty {
                screenRecordBundleID = app.bundleId
            } else {
                logger.warning("No bundle ID available for screen recording: \(appName)")
                screenRecordBundleID = nil
            }
        }

        // Get meeting window title for file naming
        var recordingName = appName
        if let bundleID = screenRecordBundleID {
            if let windowTitle = await screenRecorder.getMeetingWindowTitle(bundleId: bundleID) {
                recordingName = windowTitle
                logger.info("Using window title for recording name: \(windowTitle)")
            } else {
                logger.info("No window title found, using app name: \(appName)")
            }
        }

        // Start audio recording
        let url = try await audioEngine.startRecording(targetApp: appName, recordingName: recordingName, outputDirectory: outputDirectory)
        currentRecordingURL = url
        currentRecordingApp = appName

        // Start video recording if enabled
        if recordVideoEnabled, let bundleID = screenRecordBundleID {
            let baseFilename = url.deletingPathExtension().lastPathComponent
            let mode = windowSelectionMode
            Task {
                do {
                    switch mode {
                    case "alwaysAsk":
                        try await startRecordingWithPicker(
                            bundleId: bundleID,
                            appName: appName,
                            baseFilename: baseFilename
                        )
                    case "auto":
                        try await startRecordingAutomatic(
                            bundleId: bundleID,
                            baseFilename: baseFilename
                        )
                    default:
                        try await startRecordingSmart(
                            bundleId: bundleID,
                            appName: appName,
                            baseFilename: baseFilename
                        )
                    }
                } catch {
                    logger.warning("Video recording failed to start: \(error.localizedDescription)")
                }
            }
        }

        return url
    }

    /// Stop a meeting recording. Called by MeetingDetector.
    func stopMeetingRecording() async throws {
        logger.info("Stopping meeting recording")

        let metadata = try await audioEngine.stopRecording()

        await finalizeVideoRecording()
        await saveRecordingToDatabase(metadata: metadata)

        currentRecordingURL = nil
        currentRecordingApp = nil
    }

    // MARK: - Active App Detection

    /// Detect the active conferencing app.
    func detectActiveApp() -> String? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appName = frontmostApp.localizedName ?? ""
        let conferencingApps = ["Zoom", "Microsoft Teams", "Google Chrome", "Safari", "Slack"]

        return conferencingApps.contains(appName) ? appName : nil
    }

    // MARK: - Emergency Finalization

    /// Emergency finalization of any active recordings during app termination.
    func finalizeActiveRecordings() async {
        guard currentRecordingURL != nil || currentVideoRecordingURL != nil else {
            FileLogger.shared.debug("finalizeActiveRecordings: no active recordings to finalize")
            return
        }

        logger.info("Finalizing active recordings...")
        FileLogger.shared.debug("finalizeActiveRecordings: starting emergency finalization")

        if currentRecordingURL != nil {
            do {
                _ = try await audioEngine.stopRecording()
                FileLogger.shared.debug("finalizeActiveRecordings: audio recording finalized")
            } catch {
                logger.error("Failed to finalize audio recording: \(error.localizedDescription)")
                FileLogger.shared.debug("finalizeActiveRecordings: audio finalization failed: \(error)")
            }
        }

        if currentVideoRecordingURL != nil {
            do {
                _ = try await screenRecorder.stopRecording()
                FileLogger.shared.debug("finalizeActiveRecordings: video recording finalized")
            } catch {
                logger.error("Failed to finalize video recording: \(error.localizedDescription)")
                FileLogger.shared.debug("finalizeActiveRecordings: video finalization failed: \(error)")
            }
        }

        logger.info("Emergency recording finalization complete")
        FileLogger.shared.debug("finalizeActiveRecordings: completed")
    }

    // MARK: - Private Helpers

    /// Stop video recording and mux audio+video together.
    private func finalizeVideoRecording() async {
        guard let videoURL = currentVideoRecordingURL, let audioURL = currentRecordingURL else {
            return
        }

        do {
            let videoMetadata = try await screenRecorder.stopRecording()
            logger.info("Video recording stopped: \(videoMetadata.duration)s, \(videoMetadata.frameCount) frames")

            logger.info("Muxing video + audio...")
            let muxResult = try await mediaMuxer.muxInPlace(videoURL: videoURL, audioURL: audioURL)
            logger.info("Mux completed: \(muxResult.outputURL.lastPathComponent), \(muxResult.duration)s, \(muxResult.fileSize) bytes")
        } catch {
            logger.warning("Failed to stop/mux video recording: \(error.localizedDescription)")
        }
        currentVideoRecordingURL = nil
    }

    /// Save the completed recording to the database and queue transcription.
    private func saveRecordingToDatabase(metadata: AudioCaptureEngine.AudioMetadata) async {
        guard let url = currentRecordingURL else { return }

        do {
            let title = url.deletingPathExtension().lastPathComponent
            let recordingId = try await database.saveRecording(
                title: title,
                date: Date(),
                duration: metadata.duration,
                fileURL: url,
                fileSize: metadata.fileSize,
                appName: currentRecordingApp ?? detectActiveApp()
            )

            logger.info("Recording saved to database: ID \(recordingId)")

            NotificationCenter.default.post(
                name: .recordingDidSave,
                object: nil,
                userInfo: ["recordingId": recordingId]
            )

            _ = await ProcessingQueue.shared.queueTranscription(recordingId: recordingId, audioURL: url)
        } catch {
            logger.error("Failed to save recording: \(error.localizedDescription)")
        }
    }

    // MARK: - Video Recording Modes

    /// Smart mode: Uses heuristics first, shows picker only if ambiguous.
    private func startRecordingSmart(bundleId: String, appName: String, baseFilename: String) async throws {
        do {
            let videoURL = try await screenRecorder.startRecording(
                bundleId: bundleId,
                outputDirectory: outputDirectory,
                baseFilename: baseFilename
            )
            await MainActor.run {
                currentVideoRecordingURL = videoURL
            }
            logger.info("Video recording started for \(bundleId): \(videoURL.lastPathComponent)")
        } catch ScreenRecorder.RecorderError.windowNotFound {
            logger.info("No clear meeting window found, checking for candidates...")

            let candidates = try await screenRecorder.getCandidateWindows(bundleId: bundleId)

            if candidates.isEmpty {
                logger.warning("No windows found for \(bundleId), skipping video recording")
                return
            }

            let videoURL: URL
            if candidates.count == 1 {
                logger.info("Single candidate window, auto-selecting: \(candidates[0].title)")
                videoURL = try await screenRecorder.startRecordingWindow(
                    windowId: candidates[0].id,
                    bundleId: bundleId,
                    outputDirectory: outputDirectory,
                    baseFilename: baseFilename
                )
            } else {
                logger.info("Multiple windows found (\(candidates.count)), showing selector")
                let controller = WindowSelectorController()
                let selectedWindow = await controller.showSelector(windows: candidates, appName: appName)

                guard let window = selectedWindow else {
                    logger.info("User cancelled window selection, skipping video recording")
                    return
                }

                logger.info("User selected window: \(window.title)")
                videoURL = try await screenRecorder.startRecordingWindow(
                    windowId: window.id,
                    bundleId: bundleId,
                    outputDirectory: outputDirectory,
                    baseFilename: baseFilename
                )
            }

            await MainActor.run {
                currentVideoRecordingURL = videoURL
            }
            logger.info("Video recording started for \(bundleId): \(videoURL.lastPathComponent)")
        }
    }

    /// Always Ask mode: Always shows picker for 2+ windows.
    private func startRecordingWithPicker(bundleId: String, appName: String, baseFilename: String) async throws {
        let candidates = try await screenRecorder.getCandidateWindows(bundleId: bundleId)

        if candidates.isEmpty {
            logger.warning("No windows found for \(bundleId), skipping video recording")
            return
        }

        let videoURL: URL
        if candidates.count == 1 {
            logger.info("Single candidate window, auto-selecting: \(candidates[0].title)")
            videoURL = try await screenRecorder.startRecordingWindow(
                windowId: candidates[0].id,
                bundleId: bundleId,
                outputDirectory: outputDirectory,
                baseFilename: baseFilename
            )
        } else {
            logger.info("Multiple windows found (\(candidates.count)), showing selector (Always Ask mode)")
            let controller = WindowSelectorController()
            let selectedWindow = await controller.showSelector(windows: candidates, appName: appName)

            guard let window = selectedWindow else {
                logger.info("User cancelled window selection, skipping video recording")
                return
            }

            logger.info("User selected window: \(window.title)")
            videoURL = try await screenRecorder.startRecordingWindow(
                windowId: window.id,
                bundleId: bundleId,
                outputDirectory: outputDirectory,
                baseFilename: baseFilename
            )
        }

        await MainActor.run {
            currentVideoRecordingURL = videoURL
        }
        logger.info("Video recording started for \(bundleId): \(videoURL.lastPathComponent)")
    }

    /// Auto mode: Never shows picker, uses heuristics or picks largest window.
    private func startRecordingAutomatic(bundleId: String, baseFilename: String) async throws {
        do {
            let videoURL = try await screenRecorder.startRecording(
                bundleId: bundleId,
                outputDirectory: outputDirectory,
                baseFilename: baseFilename
            )
            await MainActor.run {
                currentVideoRecordingURL = videoURL
            }
            logger.info("Video recording started for \(bundleId): \(videoURL.lastPathComponent)")
        } catch ScreenRecorder.RecorderError.windowNotFound {
            logger.info("No clear meeting window found, picking largest window (Auto mode)")

            let candidates = try await screenRecorder.getCandidateWindows(bundleId: bundleId)

            if candidates.isEmpty {
                logger.warning("No windows found for \(bundleId), skipping video recording")
                return
            }

            let largestWindow = candidates.max { ($0.width * $0.height) < ($1.width * $1.height) }!

            logger.info("Auto-selecting largest window: \(largestWindow.title) (\(largestWindow.width)x\(largestWindow.height))")
            let videoURL = try await screenRecorder.startRecordingWindow(
                windowId: largestWindow.id,
                bundleId: bundleId,
                outputDirectory: outputDirectory,
                baseFilename: baseFilename
            )

            await MainActor.run {
                currentVideoRecordingURL = videoURL
            }
            logger.info("Video recording started for \(bundleId): \(videoURL.lastPathComponent)")
        }
    }
}
