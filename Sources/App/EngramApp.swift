// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import SwiftUI
import AppKit
import Combine
import ServiceManagement
import AudioEngine
import Intelligence
import Database
import UI
import os.log

// Re-export types needed for AI Chat
public typealias RAGPipelineProtocol = UI.RAGPipelineProtocol
public typealias RAGResponse = UI.RAGResponse
public typealias Citation = UI.Citation

// Import Theme from UI module
@_exported import enum UI.Theme

// Note: Uses FileLogger.shared for centralized logging across the App module

// MARK: - Window Action Notifications
// Notifications for opening windows from AppDelegate before SwiftUI windows are available
extension Notification.Name {
    static let openLibraryWindow = Notification.Name("dev.balakumar.engram.openLibraryWindow")
    static let openSettingsWindow = Notification.Name("dev.balakumar.engram.openSettingsWindow")
    static let openAIChatWindow = Notification.Name("dev.balakumar.engram.openAIChatWindow")
}

// MARK: - Window Action Holder
// Allows AppDelegate to trigger SwiftUI window actions
@MainActor
enum WindowActions {
    static var openLibrary: (() -> Void)?
    static var openSettings: (() -> Void)?
    static var openAIChat: (() -> Void)?
}

@main
@available(macOS 14.0, *)
struct EngramApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "engram" else { return }

        // Activate app and bring to front
        NSApp.activate(ignoringOtherApps: true)

        // Open the library window via SwiftUI
        openWindow(id: "library")
    }

    init() {
        // Set up notification observers for opening windows
        // This allows AppDelegate to trigger window opens before SwiftUI windows exist
        setupNotificationObservers()
    }

    private func setupNotificationObservers() {
        // Observe library window request
        NotificationCenter.default.addObserver(
            forName: .openLibraryWindow,
            object: nil,
            queue: .main
        ) { [self] _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "library")
            }
        }

        // Observe settings window request
        NotificationCenter.default.addObserver(
            forName: .openSettingsWindow,
            object: nil,
            queue: .main
        ) { [self] _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }

        // Observe AI chat window request
        NotificationCenter.default.addObserver(
            forName: .openAIChatWindow,
            object: nil,
            queue: .main
        ) { [self] _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "ai-chat")
            }
        }
    }

    var body: some Scene {
        // Library window - single instance only
        Window("Engram Library", id: "library") {
            LibraryView()
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    // Register window actions when first window appears
                    registerWindowActions()
                }
        }
        .handlesExternalEvents(matching: Set(["library", "*"]))
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // AI Chat menu item
            CommandGroup(after: .windowList) {
                Button("AI Chat") {
                    openWindow(id: "ai-chat")
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            }
        }

        // AI Chat window
        WindowGroup("AI Chat", id: "ai-chat") {
            AIChatWindowView()
                .onAppear {
                    registerWindowActions()
                }
        }
        .defaultSize(width: 500, height: 600)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Settings window
        Settings {
            SettingsView()
                .onAppear {
                    // Also register here in case settings opens first
                    registerWindowActions()
                }
        }
    }

    private func registerWindowActions() {
        WindowActions.openLibrary = { [openWindow] in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "library")
        }
        WindowActions.openSettings = { [openSettings] in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        WindowActions.openAIChat = { [openWindow] in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "ai-chat")
        }
    }
}

// MARK: - App Delegate

@MainActor
@available(macOS 14.0, *)
class AppDelegate: NSObject, NSApplicationDelegate, MenuBarDelegate {

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "App")

    // Core engines - initialized in applicationDidFinishLaunching before any use
    // Using implicitly unwrapped optionals since these are always set before use
    private var audioEngine: AudioCaptureEngine!
    private var screenRecorder: ScreenRecorder!
    private var mediaMuxer: MediaMuxer!
    private var transcriptionEngine: TranscriptionEngine!
    private var database: DatabaseManager!

    // UI
    private var menuBarController: MenuBarController!

    // Meeting Detection
    private var meetingDetector: MeetingDetector!
    private var systemEventHandler: SystemEventHandler!
    private var systemEventTask: Task<Void, Never>?

    // Auto Recording Settings
    @AppStorage("autoRecord") private var autoRecordEnabled = true
    @AppStorage("enabledMeetingApps") private var enabledMeetingAppsRaw = "zoom,teams,meet,slack,discord"
    @AppStorage("autoRecordOnWake") private var autoRecordOnWake: Bool = true
    @AppStorage("recordVideoEnabled") private var recordVideoEnabled: Bool = false
    @AppStorage("windowSelectionMode") private var windowSelectionMode: String = "smart"

    // Auto AI Generation Settings
    @AppStorage("autoGenerateSummary") private var autoGenerateSummary = true
    @AppStorage("autoGenerateActionItems") private var autoGenerateActionItems = true

    // Legacy (kept for migration)
    @AppStorage("monitoredApps") private var monitoredAppsRaw = "Zoom,Microsoft Teams,Google Chrome,FaceTime"

    // State
    private var currentRecordingURL: URL?
    private var currentVideoRecordingURL: URL?
    private var outputDirectory: URL!
    private var currentRecordingApp: String?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure only one instance of the app runs at a time
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            if runningApps.count > 1 {
                // Another instance is already running - activate it and quit this one
                logger.warning("Another instance of Engram is already running. Terminating this instance.")
                if let existingApp = runningApps.first(where: { $0 != NSRunningApplication.current }) {
                    existingApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                }
                NSApp.terminate(nil)
                return
            }
        }
        
        logger.info("Engram starting...")

        // Hide dock icon (menu bar only app)
        NSApp.setActivationPolicy(.accessory)

        // Setup output directory
        setupOutputDirectory()

        // Initialize components (includes setting up processing queue handlers BEFORE resuming work)
        Task {
            // IMPORTANT: Set up processing queue handlers FIRST, before initializing components
            // This ensures handlers are ready before resumeIncompleteWork is called
            await setupProcessingQueueAsync()

            await initializeComponents()
        }

        // Setup menu bar
        menuBarController = MenuBarController()
        menuBarController.delegate = self

        // Setup Meeting Detection
        setupMeetingDetection()

        logger.info("Engram ready")
    }

    private func setupProcessingQueueAsync() async {
        // Configure the processing queue with handlers that call our methods
        // This ensures transcription and AI generation tasks run serially

        FileLogger.shared.debug("setupProcessingQueueAsync: Setting handlers...")

        // Transcription handler
        await ProcessingQueue.shared.setTranscriptionHandler { [weak self] recordingId, audioURL in
            FileLogger.shared.debug("Transcription handler called for recording \(recordingId)")
            await self?.transcribeRecording(id: recordingId, url: audioURL)
            FileLogger.shared.debug("Transcription handler completed for recording \(recordingId)")
        }

        // AI generation handler (summary + action items)
        await ProcessingQueue.shared.setAIGenerationHandler { [weak self] recordingId in
            FileLogger.shared.debug("AI generation handler called for recording \(recordingId)")
            await self?.autoGenerateAIContent(recordingId: recordingId)
            FileLogger.shared.debug("AI generation handler completed for recording \(recordingId)")
        }

        FileLogger.shared.debug("setupProcessingQueueAsync: Handlers configured successfully")
        logger.info("Processing queue handlers configured")
    }

    /// Resume incomplete processing tasks from a previous session.
    /// Called after database is initialized to query for recordings that need work.
    private func resumeIncompleteProcessing() async {
        FileLogger.shared.debug("resumeIncompleteProcessing called")

        guard let db = database else {
            FileLogger.shared.debug("resumeIncompleteProcessing: database not initialized")
            logger.warning("Cannot resume incomplete processing - database not initialized")
            return
        }

        // Read user preferences
        let autoTranscribeEnabled = UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true
        let autoSummaryEnabled = autoGenerateSummary
        let autoActionItemsEnabled = autoGenerateActionItems

        FileLogger.shared.debug("resumeIncompleteProcessing: autoTranscribe=\(autoTranscribeEnabled), autoSummary=\(autoSummaryEnabled), autoActions=\(autoActionItemsEnabled)")
        logger.info("Checking for incomplete work (transcribe: \(autoTranscribeEnabled), summary: \(autoSummaryEnabled), actions: \(autoActionItemsEnabled))")

        // Queue any incomplete work
        await ProcessingQueue.shared.resumeIncompleteWork(
            database: db,
            autoTranscribe: autoTranscribeEnabled,
            autoGenerateSummary: autoSummaryEnabled,
            autoGenerateActionItems: autoActionItemsEnabled
        )

        FileLogger.shared.debug("resumeIncompleteProcessing completed")
    }

    // MARK: - URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "engram" else { continue }
            logger.info("Handling URL: \(url.absoluteString)")

            // Activate and let SwiftUI's handlesExternalEvents handle the window
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    private func setupOutputDirectory() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputDirectory = documentsURL.appendingPathComponent("Engram/Recordings")

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        logger.info("Output directory: \(self.outputDirectory.path)")
    }
    
    private func initializeComponents() async {
        // Audio Engine
        audioEngine = AudioCaptureEngine()

        // Screen Recorder for Zoom window capture
        screenRecorder = ScreenRecorder()

        // Media Muxer for combining video + audio post-recording
        mediaMuxer = MediaMuxer()

        // Try to request permissions, but don't show alert on startup
        // The permission prompts will appear when user actually tries to record
        do {
            try await audioEngine.requestPermissions()
            logger.info("Permissions granted")
        } catch {
            logger.warning("Permissions not yet granted (will prompt when recording starts): \(error.localizedDescription)")
            // Don't show alert here - let it happen naturally when user clicks "Start Recording"
        }

        // Transcription Engine
        transcriptionEngine = TranscriptionEngine()

        // Load Whisper model - we need this before resuming incomplete transcriptions
        // Load synchronously so resume can work, but don't block the main thread
        let engine = transcriptionEngine
        let log = logger
        do {
            try await engine?.loadModel()
            log.info("Whisper model loaded")
        } catch {
            log.error("Failed to load Whisper model: \(error.localizedDescription)")
        }

        // Database (use shared instance to prevent concurrent access issues)
        do {
            database = try await DatabaseManager.shared()
            logger.info("Database initialized")

            // Resume any incomplete work from previous session
            // This runs after database AND model are ready so transcriptions can succeed
            await resumeIncompleteProcessing()
        } catch {
            logger.error("Database initialization failed: \(error.localizedDescription)")
        }

        // Initialize AI Service in background ONLY if enabled
        let aiEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true
        if aiEnabled {
            let aiLog = logger
            let db = database
            let appDelegate = self
            Task.detached(priority: .background) {
                do {
                    try await AIService.shared.initialize()
                    aiLog.info("AI Service initialized")

                    // After AI is ready, regenerate titles for recordings with summaries but generic titles
                    await appDelegate.regenerateMissingTitles(database: db)
                } catch {
                    aiLog.warning("AI Service initialization failed: \(error.localizedDescription)")
                }
            }
        } else {
            logger.info("AI Service disabled by user preference, skipping initialization")
        }
    }

    /// Regenerate titles for recordings that have summaries but still have generic titles
    private func regenerateMissingTitles(database: DatabaseManager?) async {
        guard let db = database else { return }

        // Wait for AI service to be fully ready (model loaded) - can take 2+ minutes
        FileLogger.shared.debug("[TitleRegen] Waiting for AI service to be ready...")
        var waitCount = 0
        var aiReady = await AIService.shared.isReady
        while !aiReady && waitCount < 180 {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            waitCount += 1
            if waitCount % 30 == 0 {
                FileLogger.shared.debug("[TitleRegen] Still waiting for AI service... (\(waitCount)s)")
            }
            aiReady = await AIService.shared.isReady
        }

        guard aiReady else {
            FileLogger.shared.debug("[TitleRegen] AI service not ready after 180s, skipping title regeneration")
            return
        }
        FileLogger.shared.debug("[TitleRegen] AI service ready, starting title regeneration")

        do {
            let recordings = try await db.getAllRecordings()
            for recording in recordings {
                // Check if title is generic (Zoom_Meeting_ or Zoom_Workplace_)
                let isGenericTitle = recording.title.hasPrefix("Zoom_Meeting_") ||
                                     recording.title.hasPrefix("Zoom_Workplace_") ||
                                     recording.title.hasPrefix("Zoom Meeting")

                // Check if has summary
                let hasSummary = recording.summary != nil &&
                                 !recording.summary!.isEmpty &&
                                 !recording.summary!.hasPrefix("[No")

                if isGenericTitle && hasSummary {
                    FileLogger.shared.debug("[TitleRegen] Recording \(recording.id) needs title regeneration")
                    await generateTitleFromSummary(recordingId: recording.id, summary: recording.summary!)
                }
            }
        } catch {
            logger.warning("Failed to check for missing titles: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func showPermissionAlert() {
        let appPath = Bundle.main.bundlePath
        
        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = """
Engram needs Screen Recording and Microphone permissions.

For ad-hoc signed apps, you must manually add them:

1. Open System Settings → Privacy & Security
2. Go to Screen Recording → Click '+' → Add this app
3. Go to Microphone → Click '+' → Add this app
4. Restart Engram

App location: \(appPath)
"""
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Screen Recording Settings")
        alert.addButton(withTitle: "Open Microphone Settings")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
    
    // MARK: - MenuBarDelegate
    
    func menuBarDidRequestStartRecording() {
        Task {
            do {
                // First check/request permissions
                try await audioEngine.requestPermissions()

                currentRecordingURL = try await audioEngine.startRecording(outputDirectory: outputDirectory)
                logger.info("Recording started: \(self.currentRecordingURL?.lastPathComponent ?? "unknown")")
            } catch AudioCaptureEngine.CaptureError.permissionDenied {
                logger.error("Permission denied for recording")
                menuBarController.setRecording(false)
                await showPermissionAlert()
            } catch let error as NSError {
                logger.error("Failed to start recording: \(error)")
                menuBarController.setRecording(false)

                // Check if it's a permission error
                if error.code == -3801 || error.localizedDescription.contains("TCC") || error.localizedDescription.contains("declined") {
                    await showPermissionAlert()
                } else {
                    await showErrorAlert(message: "Failed to start recording: \(error.localizedDescription)")
                }
            } catch {
                logger.error("Failed to start recording: \(error.localizedDescription)")
                menuBarController.setRecording(false)
                await showErrorAlert(message: "Failed to start recording: \(error.localizedDescription)")
            }
        }
    }
    
    func menuBarDidRequestStopRecording() {
        Task {
            do {
                let metadata = try await audioEngine.stopRecording()
                logger.info("Recording stopped: \(metadata.duration)s")

                // Stop video recording if active and mux with audio
                if let videoURL = currentVideoRecordingURL, let audioURL = currentRecordingURL {
                    do {
                        let videoMetadata = try await screenRecorder.stopRecording()
                        logger.info("Video recording stopped: \(videoMetadata.duration)s, \(videoMetadata.frameCount) frames")

                        // Mux video + audio into the video file
                        logger.info("Muxing video + audio...")
                        let muxResult = try await mediaMuxer.muxInPlace(videoURL: videoURL, audioURL: audioURL)
                        logger.info("Mux completed: \(muxResult.outputURL.lastPathComponent), \(muxResult.duration)s, \(muxResult.fileSize) bytes")
                    } catch {
                        logger.warning("Failed to stop/mux video recording: \(error.localizedDescription)")
                    }
                    currentVideoRecordingURL = nil
                }

                // Save to database
                if let url = currentRecordingURL {
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

                    // Notify UI that a new recording was saved
                    NotificationCenter.default.post(
                        name: .recordingDidSave,
                        object: nil,
                        userInfo: ["recordingId": recordingId]
                    )

                    // Queue transcription (processed serially to avoid resource conflicts)
                    await ProcessingQueue.shared.queueTranscription(recordingId: recordingId, audioURL: url)
                }

                currentRecordingURL = nil
                currentRecordingApp = nil

                // IMPORTANT: Notify the MeetingDetector to go back to monitoring state
                // This allows auto-recording to restart if a meeting is still in progress
                // We use resetRecordingState() since recording is already stopped
                await meetingDetector.resetRecordingState()

            } catch {
                logger.error("Failed to stop recording: \(error.localizedDescription)")
                await showErrorAlert(message: "Failed to stop recording: \(error.localizedDescription)")
            }
        }
    }
    
    func menuBarDidRequestInsertMarker() {
        let engine = audioEngine
        let log = logger
        Task {
            await engine?.insertMarker(label: "User Marker")
            log.info("Marker inserted")
        }
    }
    
    func menuBarDidRequestOpenLibrary() {
        if let action = WindowActions.openLibrary {
            // Use SwiftUI's openWindow if available
            action()
        } else {
            // Fallback: Post notification to open library window
            // This works even before any SwiftUI window has appeared
            logger.info("Using notification fallback to open library window")
            NotificationCenter.default.post(name: .openLibraryWindow, object: nil)
        }
    }

    func menuBarDidRequestOpenSettings() {
        if let action = WindowActions.openSettings {
            // Use SwiftUI's openSettings if available
            action()
        } else {
            // Fallback: Post notification to open settings window
            logger.info("Using notification fallback to open settings window")
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        }
    }

    func menuBarDidRequestOpenAIChat() {
        if let action = WindowActions.openAIChat {
            // Use SwiftUI's openWindow if available
            action()
        } else {
            // Fallback: Post notification to open AI chat window
            logger.info("Using notification fallback to open AI chat window")
            NotificationCenter.default.post(name: .openAIChatWindow, object: nil)
        }
    }

    // MARK: - Helper Methods
    
    private func detectActiveApp() -> String? {
        // Detect active conferencing app
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        
        let appName = frontmostApp.localizedName ?? ""
        let conferencingApps = ["Zoom", "Microsoft Teams", "Google Chrome", "Safari", "Slack"]
        
        return conferencingApps.contains(appName) ? appName : nil
    }

    /// Reload the Whisper model when user changes settings
    func reloadWhisperModel() async {
        logger.info("Reloading Whisper model due to settings change...")
        do {
            try await transcriptionEngine.reloadModel()
            let modelName = await transcriptionEngine.currentModelVariant
            logger.info("Whisper model reloaded: \(modelName)")
        } catch {
            logger.error("Failed to reload Whisper model: \(error.localizedDescription)")
            logError("Failed to reload Whisper model", error: error)
        }
    }

    private func transcribeRecording(id: Int64, url: URL) async {
        FileLogger.shared.debug("[transcribeRecording] Starting for recording \(id), url: \(url.lastPathComponent)")
        logger.info("Starting auto-transcription for recording \(id)")

        // Notify UI that transcription started
        NotificationCenter.default.post(
            name: .processingDidStart,
            object: nil,
            userInfo: ["recordingId": id, "type": ProcessingType.transcription.rawValue]
        )

        do {
            FileLogger.shared.debug("[transcribeRecording] Calling transcriptionEngine.transcribe...")
            let result = try await transcriptionEngine.transcribe(audioURL: url)
            FileLogger.shared.debug("[transcribeRecording] Transcription completed: \(result.segments.count) segments, \(result.text.count) chars")

            let segments = result.segments.map { segment in
                DatabaseManager.TranscriptSegment(
                    id: 0,
                    transcriptId: 0,
                    startTime: segment.start,
                    endTime: segment.end,
                    text: segment.text,
                    speaker: segment.speaker.displayName,
                    confidence: segment.confidence
                )
            }

            let transcriptId = try await database.saveTranscript(
                recordingId: id,
                fullText: result.text,
                language: result.language,
                processingTime: result.processingTime,
                segments: segments
            )

            logger.info("Transcription completed for recording \(id)")

            // Notify UI that transcription completed
            NotificationCenter.default.post(
                name: .processingDidComplete,
                object: nil,
                userInfo: ["recordingId": id, "type": ProcessingType.transcription.rawValue]
            )

            // Notify UI that transcript is available
            NotificationCenter.default.post(
                name: .recordingContentDidUpdate,
                object: nil,
                userInfo: ["recordingId": id, "type": "transcript"]
            )

            // Auto-index if enabled (defaults to true if not set)
            let autoIndex = UserDefaults.standard.object(forKey: "autoIndexTranscripts") as? Bool ?? true
            if autoIndex {
                await autoIndexTranscript(recordingId: id, transcriptId: transcriptId)
            }

            // Queue AI generation (processed serially to avoid LLM resource conflicts)
            await ProcessingQueue.shared.queueAIGeneration(recordingId: id)
        } catch {
            FileLogger.shared.debugError("[transcribeRecording] FAILED for recording \(id)", error: error)
            logger.error("Auto-transcription failed: \(error.localizedDescription)")
            // Notify UI that transcription completed (even on error)
            NotificationCenter.default.post(
                name: .processingDidComplete,
                object: nil,
                userInfo: ["recordingId": id, "type": ProcessingType.transcription.rawValue]
            )
        }
    }

    /// Automatically index a transcript for RAG search
    private func autoIndexTranscript(recordingId: Int64, transcriptId: Int64) async {
        do {
            // Fetch the recording, transcript, and segments
            let recording = try await database.getRecording(id: recordingId)
            guard let transcript = try await database.getTranscript(forRecording: recordingId) else {
                logger.warning("No transcript found for recording \(recordingId), skipping indexing")
                return
            }
            let segments = try await database.getSegments(forTranscriptId: transcriptId)

            // Index using AIService
            try await AIService.shared.indexRecording(recording, transcript: transcript, segments: segments)
            logger.info("Auto-indexed transcript for recording \(recordingId)")
        } catch {
            logger.warning("Auto-indexing failed for recording \(recordingId): \(error.localizedDescription)")
        }
    }

    /// Clean up AI response to remove thinking text, empty arrays, and other artifacts
    /// Returns nil if the cleaned result is empty or indicates no action items
    private func cleanActionItemsResponse(_ response: String) -> String? {
        // First, use ResponseProcessor to strip thinking patterns
        var cleaned = ResponseProcessor.stripThinkingPatterns(response)

        // Remove <think>...</think> blocks if present (should be handled by ResponseProcessor but just in case)
        let thinkBlockPattern = #"<think>[\s\S]*?</think>"#
        if let regex = try? NSRegularExpression(pattern: thinkBlockPattern, options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Remove standalone empty arrays "[]"
        cleaned = cleaned.replacingOccurrences(of: "[]", with: "")

        // Remove "No action items" type responses
        let noItemsPatterns = [
            #"(?i)no\s+(clear\s+)?action\s+items"#,
            #"(?i)no\s+action\s+items?\s+(were\s+)?found"#,
            #"(?i)there\s+are\s+no\s+(clear\s+)?action\s+items"#,
            #"(?i)i\s+(could\s+not|couldn't)\s+find\s+any\s+action\s+items"#
        ]
        for pattern in noItemsPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: cleaned, options: [], range: NSRange(cleaned.startIndex..., in: cleaned)) != nil {
                return nil // AI explicitly said no action items
            }
        }

        // Trim whitespace and newlines
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Return nil if empty
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Check if transcript has meaningful content worth generating AI summary for
    /// Returns false for empty transcripts or transcripts with only noise markers
    private func hasMeaningfulContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Remove timestamp prefixes like "[0:00]" and speaker labels like "Unknown:" or "Speaker 2:"
        let cleanedText = trimmed
            .replacingOccurrences(of: #"\[\d+:\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(Unknown|Speaker\s*\d*|You):"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // List of noise markers that indicate no real content
        let noiseMarkers = [
            "[INAUDIBLE]", "[inaudible]",
            "[SILENCE]", "[silence]",
            "[NOISE]", "[noise]",
            "[MUSIC]", "[music]",
            "[BLANK_AUDIO]", "[blank_audio]",
            "[BACKGROUND_NOISE]", "[background_noise]"
        ]

        // Check if the cleaned text only contains noise markers
        var textWithoutNoise = cleanedText
        for marker in noiseMarkers {
            textWithoutNoise = textWithoutNoise.replacingOccurrences(of: marker, with: "")
        }
        textWithoutNoise = textWithoutNoise.trimmingCharacters(in: .whitespacesAndNewlines)

        // Require at least 20 characters of actual content (roughly 4-5 words)
        // This filters out transcripts that are basically empty or only noise
        if textWithoutNoise.count < 20 {
            return false
        }

        // Also require at least 3 words
        let words = textWithoutNoise.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        if words.count < 3 {
            return false
        }

        return true
    }

    /// Automatically generate AI summary and action items for a recording
    private func autoGenerateAIContent(recordingId: Int64) async {
        // Check if AI is enabled
        let aiEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true
        guard aiEnabled else { return }

        guard autoGenerateSummary || autoGenerateActionItems else { return }

        do {
            // Verify transcript exists and has meaningful content before generating AI content
            if let transcript = try? await database.getTranscript(forRecording: recordingId) {
                if !hasMeaningfulContent(transcript.fullText) {
                    logger.warning("Skipping auto-generation for recording \(recordingId) - transcript has no meaningful content")
                    // Save markers to prevent re-processing on restart
                    if autoGenerateSummary {
                        try? await database.saveSummary(recordingId: recordingId, summary: "[No meaningful audio content]")
                    }
                    if autoGenerateActionItems {
                        try? await database.saveActionItems(recordingId: recordingId, actionItems: "[No action items]")
                    }
                    return
                }
            } else {
                logger.warning("Skipping auto-generation for recording \(recordingId) - no transcript found")
                return
            }

            // Generate summary if enabled
            if autoGenerateSummary {
                logger.info("Auto-generating summary for recording \(recordingId)")

                // Notify UI that summary generation started
                NotificationCenter.default.post(
                    name: .processingDidStart,
                    object: nil,
                    userInfo: ["recordingId": recordingId, "type": ProcessingType.summary.rawValue]
                )

                let summaryStream = await AIService.shared.agentChat(
                    query: "Provide a comprehensive summary of this meeting including main topics, key decisions, and important points.",
                    sessionId: "auto-summary-\(recordingId)",
                    recordingFilter: recordingId
                )
                var summary = ""
                for try await token in summaryStream {
                    summary += token
                }

                // Notify UI that summary generation completed
                NotificationCenter.default.post(
                    name: .processingDidComplete,
                    object: nil,
                    userInfo: ["recordingId": recordingId, "type": ProcessingType.summary.rawValue]
                )

                if !summary.isEmpty {
                    try await database.saveSummary(recordingId: recordingId, summary: summary)
                    logger.info("Auto-generated summary for recording \(recordingId)")
                    FileLogger.shared.debug("[AutoGen] Summary saved for recording \(recordingId), calling generateTitleFromSummary...")

                    // Generate a meaningful title from the summary if current title is generic
                    await generateTitleFromSummary(recordingId: recordingId, summary: summary)
                    FileLogger.shared.debug("[AutoGen] generateTitleFromSummary completed for recording \(recordingId)")

                    // Notify UI that summary is available
                    NotificationCenter.default.post(
                        name: .recordingContentDidUpdate,
                        object: nil,
                        userInfo: ["recordingId": recordingId, "type": "summary"]
                    )
                } else {
                    // Save marker to prevent re-processing on restart
                    try await database.saveSummary(recordingId: recordingId, summary: "[No summary generated]")
                    logger.info("No summary generated for recording \(recordingId) - marked as processed")
                }
            }

            // Generate action items if enabled
            if autoGenerateActionItems {
                logger.info("Auto-generating action items for recording \(recordingId)")

                // Notify UI that action items extraction started
                NotificationCenter.default.post(
                    name: .processingDidStart,
                    object: nil,
                    userInfo: ["recordingId": recordingId, "type": ProcessingType.actionItems.rawValue]
                )

                let actionStream = await AIService.shared.agentChat(
                    query: """
                    Extract ONLY clear action items from this meeting. Be very strict - only include items you are at least 60% confident are real action items.

                    WHAT IS an action item:
                    - "I will send you the report by Friday" → Action item: Send report by Friday (Owner: speaker)
                    - "Can you review the proposal?" → Action item: Review the proposal (Owner: listener)
                    - "We need to schedule a follow-up meeting" → Action item: Schedule follow-up meeting

                    WHAT IS NOT an action item:
                    - General discussion or opinions
                    - Questions without clear tasks
                    - Past events or completed tasks
                    - Vague statements like "we should think about..."

                    OUTPUT FORMAT:
                    - Simple bullet list only
                    - One action per line
                    - Include owner if explicitly mentioned
                    - If NO clear action items exist, output NOTHING (empty response)
                    - Do NOT add headers, notes, or explanations
                    """,
                    sessionId: "auto-actions-\(recordingId)",
                    recordingFilter: recordingId
                )
                var actionItems = ""
                for try await token in actionStream {
                    actionItems += token
                }

                // Notify UI that action items extraction completed
                NotificationCenter.default.post(
                    name: .processingDidComplete,
                    object: nil,
                    userInfo: ["recordingId": recordingId, "type": ProcessingType.actionItems.rawValue]
                )

                // Clean up the response to remove thinking text, empty arrays, etc.
                if let cleanedActionItems = cleanActionItemsResponse(actionItems) {
                    try await database.saveActionItems(recordingId: recordingId, actionItems: cleanedActionItems)
                    logger.info("Auto-generated action items for recording \(recordingId)")

                    // Notify UI that action items are available
                    NotificationCenter.default.post(
                        name: .recordingContentDidUpdate,
                        object: nil,
                        userInfo: ["recordingId": recordingId, "type": "actionItems"]
                    )
                } else {
                    // Save marker to prevent re-processing on restart
                    try await database.saveActionItems(recordingId: recordingId, actionItems: "[No action items]")
                    logger.info("No action items found for recording \(recordingId) - marked as processed")
                }
            }
        } catch {
            logger.warning("Auto AI generation failed for recording \(recordingId): \(error.localizedDescription)")
        }
    }

    /// Generate a meaningful title from the meeting summary using LLM
    /// Always generates an AI title since we have meaningful content (summary)
    private func generateTitleFromSummary(recordingId: Int64, summary: String) async {
        FileLogger.shared.rag("[TitleGen] Starting for recording \(recordingId), summary length: \(summary.count)")
        do {
            logger.info("Generating title for recording \(recordingId) from summary...")
            FileLogger.shared.rag("[TitleGen] Calling directGenerate for recording \(recordingId)...")

            // Generate a concise title from the summary
            let titlePrompt = """
                Based on this meeting summary, generate a concise, descriptive title (5-8 words max).
                The title should capture the main topic or purpose of the meeting.
                Return ONLY the title, nothing else. No quotes, no explanation.

                Summary:
                \(summary.prefix(1500))
                """

            // Use directGenerate for simple prompt processing without RAG
            let titleStream = await AIService.shared.directGenerate(
                prompt: titlePrompt,
                systemPrompt: "You are a helpful assistant that generates concise meeting titles. Return only the title, nothing else."
            )

            var generatedTitle = ""
            for try await token in titleStream {
                generatedTitle += token
            }
            FileLogger.shared.rag("[TitleGen] Raw generated title length: \(generatedTitle.count)")

            // Strip <think>...</think> tags from reasoning models (e.g., Qwen3)
            if let thinkEndRange = generatedTitle.range(of: "</think>") {
                generatedTitle = String(generatedTitle[thinkEndRange.upperBound...])
                FileLogger.shared.rag("[TitleGen] Stripped thinking tags, remaining: '\(generatedTitle)'")
            }

            // Clean up the generated title
            generatedTitle = generatedTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\n", with: " ")

            // Validate the title
            guard !generatedTitle.isEmpty, generatedTitle.count >= 3, generatedTitle.count <= 100 else {
                logger.warning("Generated title is invalid: '\(generatedTitle)'")
                FileLogger.shared.rag("[TitleGen] INVALID title for recording \(recordingId): '\(generatedTitle)' (length: \(generatedTitle.count))")
                return
            }

            // Update the database with the new title
            FileLogger.shared.rag("[TitleGen] Updating database title for recording \(recordingId) to: '\(generatedTitle)'")
            try await database.updateTitle(recordingId: recordingId, newTitle: generatedTitle)
            logger.info("Updated recording \(recordingId) title to: \(generatedTitle)")
            FileLogger.shared.rag("[TitleGen] SUCCESS: Recording \(recordingId) title updated to: '\(generatedTitle)'")

            // Notify UI that recording info has been updated
            NotificationCenter.default.post(
                name: .recordingContentDidUpdate,
                object: nil,
                userInfo: ["recordingId": recordingId, "type": "title"]
            )

        } catch {
            logger.warning("Failed to generate title for recording \(recordingId): \(error.localizedDescription)")
            FileLogger.shared.rag("[TitleGen] ERROR for recording \(recordingId): \(error.localizedDescription)")
        }
    }

    @MainActor
    private func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
    
    // MARK: - Meeting Detection

    private func setupMeetingDetection() {
        // Parse enabled apps
        let enabledApps = Set(enabledMeetingAppsRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })

        // Create meeting detector with configuration
        let config = MeetingDetector.Configuration(
            enabledApps: enabledApps,
            checkOnWake: autoRecordOnWake
        )

        meetingDetector = MeetingDetector(configuration: config)

        // Set delegate callbacks
        Task {
            await meetingDetector.setDelegate(
                stateChanged: { [weak self] detector, state in
                    self?.handleMeetingStateChange(state)
                },
                startRecording: { [weak self] detector, appName in
                    guard let self = self else { throw MeetingDetectorError.delegateNotAvailable }
                    return try await self.startMeetingRecording(for: appName)
                },
                stopRecording: { [weak self] detector in
                    guard let self = self else { return }
                    try await self.stopMeetingRecording()
                },
                error: { [weak self] detector, error in
                    self?.logger.error("Meeting detector error: \(error.localizedDescription)")
                }
            )

            // Start detector if auto-record is enabled
            FileLogger.shared.debug("autoRecordEnabled = \(autoRecordEnabled)")
            if autoRecordEnabled {
                FileLogger.shared.debug("Calling meetingDetector.start()...")
                await meetingDetector.start()
                FileLogger.shared.debug("meetingDetector.start() completed")
                logger.info("Meeting detector started")
            } else {
                FileLogger.shared.debug("Auto-record is DISABLED, not starting detector")
            }
        }

        // Setup system event handler for sleep/wake
        systemEventHandler = SystemEventHandler()
        systemEventTask = Task {
            for await event in systemEventHandler.eventStream() {
                await handleSystemEvent(event)
            }
        }
    }

    private func handleMeetingStateChange(_ state: MeetingDetector.State) {
        switch state {
        case .idle:
            menuBarController.setRecording(false)
            menuBarController.setMonitoring(false, app: nil)
        case .monitoring(let app):
            menuBarController.setRecording(false)
            menuBarController.setMonitoring(true, app: app)
        case .meetingDetected(let app):
            logger.info("Meeting detected for: \(app)")
        case .recording(let app):
            menuBarController.setRecording(true)
            menuBarController.setMonitoring(false, app: nil)
            currentRecordingApp = app
        case .endingMeeting(let app):
            logger.info("Meeting ending for: \(app)")
        }
    }

    private func startMeetingRecording(for appName: String) async throws -> URL {
        logger.info("Starting meeting recording for: \(appName)")

        // Request permissions if needed
        try await audioEngine.requestPermissions()

        // Get the detected bundle ID from MeetingDetector (if available)
        let detectedBundleID = await meetingDetector.getCurrentRecordingBundleID()

        // Determine which bundle ID to use for screen recording
        let screenRecordBundleID: String?
        if let detected = detectedBundleID, !detected.isEmpty {
            // Use the detected bundle ID (works for browsers and all apps)
            screenRecordBundleID = detected
            logger.info("Using detected bundle ID for screen recording: \(detected)")
        } else if appName.lowercased().contains("zoom") {
            // Fallback for Zoom
            screenRecordBundleID = "us.zoom.xos"
        } else {
            // Try to find bundle ID from MeetingDetector's supportedApps
            if let app = MeetingDetector.supportedApps.first(where: {
                appName.localizedCaseInsensitiveContains($0.displayName)
            }), !app.bundleId.isEmpty {
                screenRecordBundleID = app.bundleId
            } else {
                // No bundle ID available, skip screen recording
                logger.warning("No bundle ID available for screen recording: \(appName)")
                screenRecordBundleID = nil
            }
        }

        // Get the meeting window title for file naming (use window title instead of app/bundle name)
        var recordingName = appName
        if let bundleID = screenRecordBundleID {
            if let windowTitle = await screenRecorder.getMeetingWindowTitle(bundleId: bundleID) {
                recordingName = windowTitle
                logger.info("Using window title for recording name: \(windowTitle)")
            } else {
                logger.info("No window title found, using app name: \(appName)")
            }
        }

        // Start audio recording with meeting title as the recording name
        let url = try await audioEngine.startRecording(targetApp: appName, recordingName: recordingName, outputDirectory: outputDirectory)
        currentRecordingURL = url
        currentRecordingApp = appName

        // Start video recording (non-blocking, audio continues if video fails)
        // Only record video if the user has enabled it in settings (defaults to OFF)
        if recordVideoEnabled, let bundleID = screenRecordBundleID {
            // Extract base filename from audio URL to keep timestamps synchronized
            let baseFilename = url.deletingPathExtension().lastPathComponent
            let mode = windowSelectionMode
            Task {
                do {
                    switch mode {
                    case "alwaysAsk":
                        // Always Ask: Get candidates first, show picker for 2+ windows
                        try await startRecordingWithPicker(
                            bundleId: bundleID,
                            appName: appName,
                            baseFilename: baseFilename
                        )

                    case "auto":
                        // Auto: Never show picker, use heuristics or pick largest
                        try await startRecordingAutomatic(
                            bundleId: bundleID,
                            baseFilename: baseFilename
                        )

                    default:
                        // Smart (default): Current behavior - heuristics first, picker if ambiguous
                        try await startRecordingSmart(
                            bundleId: bundleID,
                            appName: appName,
                            baseFilename: baseFilename
                        )
                    }
                } catch {
                    logger.warning("Video recording failed to start: \(error.localizedDescription)")
                    // Continue with audio-only recording
                }
            }
        }

        return url
    }

    private func stopMeetingRecording() async throws {
        logger.info("Stopping meeting recording")

        let metadata = try await audioEngine.stopRecording()

        // Stop video recording if active and mux with audio
        if let videoURL = currentVideoRecordingURL, let audioURL = currentRecordingURL {
            do {
                let videoMetadata = try await screenRecorder.stopRecording()
                logger.info("Video recording stopped: \(videoMetadata.duration)s, \(videoMetadata.frameCount) frames")

                // Mux video + audio into the video file (replaces video-only with video+audio)
                logger.info("Muxing video + audio...")
                let muxResult = try await mediaMuxer.muxInPlace(videoURL: videoURL, audioURL: audioURL)
                logger.info("Mux completed: \(muxResult.outputURL.lastPathComponent), \(muxResult.duration)s, \(muxResult.fileSize) bytes")
            } catch {
                logger.warning("Failed to stop/mux video recording: \(error.localizedDescription)")
            }
            currentVideoRecordingURL = nil
        }

        // Save to database
        if let url = currentRecordingURL {
            let title = url.deletingPathExtension().lastPathComponent
            let recordingId = try await database.saveRecording(
                title: title,
                date: Date(),
                duration: metadata.duration,
                fileURL: url,
                fileSize: metadata.fileSize,
                appName: currentRecordingApp
            )

            logger.info("Meeting recording saved: ID \(recordingId)")

            // Notify UI that a new recording was saved
            NotificationCenter.default.post(
                name: .recordingDidSave,
                object: nil,
                userInfo: ["recordingId": recordingId]
            )

            // Queue transcription (processed serially to avoid resource conflicts)
            await ProcessingQueue.shared.queueTranscription(recordingId: recordingId, audioURL: url)
        }

        currentRecordingURL = nil
        currentRecordingApp = nil
    }

    // MARK: - Video Recording Modes

    /// Smart mode: Uses heuristics first, shows picker only if ambiguous
    private func startRecordingSmart(bundleId: String, appName: String, baseFilename: String) async throws {
        do {
            // First, try automatic detection using heuristics
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
            // Heuristics failed - fall back to window selector
            logger.info("No clear meeting window found, checking for candidates...")

            let candidates = try await screenRecorder.getCandidateWindows(bundleId: bundleId)

            if candidates.isEmpty {
                logger.warning("No windows found for \(bundleId), skipping video recording")
                return
            }

            let videoURL: URL
            if candidates.count == 1 {
                // Single window - auto-select
                logger.info("Single candidate window, auto-selecting: \(candidates[0].title)")
                videoURL = try await screenRecorder.startRecordingWindow(
                    windowId: candidates[0].id,
                    bundleId: bundleId,
                    outputDirectory: outputDirectory,
                    baseFilename: baseFilename
                )
            } else {
                // Multiple windows - show selector popup
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

    /// Always Ask mode: Always shows picker for 2+ windows
    private func startRecordingWithPicker(bundleId: String, appName: String, baseFilename: String) async throws {
        let candidates = try await screenRecorder.getCandidateWindows(bundleId: bundleId)

        if candidates.isEmpty {
            logger.warning("No windows found for \(bundleId), skipping video recording")
            return
        }

        let videoURL: URL
        if candidates.count == 1 {
            // Single window - auto-select (no point showing picker)
            logger.info("Single candidate window, auto-selecting: \(candidates[0].title)")
            videoURL = try await screenRecorder.startRecordingWindow(
                windowId: candidates[0].id,
                bundleId: bundleId,
                outputDirectory: outputDirectory,
                baseFilename: baseFilename
            )
        } else {
            // Multiple windows - always show selector
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

    /// Auto mode: Never shows picker, uses heuristics or picks largest window
    private func startRecordingAutomatic(bundleId: String, baseFilename: String) async throws {
        do {
            // First, try automatic detection using heuristics
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
            // Heuristics failed - pick largest window automatically (no picker)
            logger.info("No clear meeting window found, picking largest window (Auto mode)")

            let candidates = try await screenRecorder.getCandidateWindows(bundleId: bundleId)

            if candidates.isEmpty {
                logger.warning("No windows found for \(bundleId), skipping video recording")
                return
            }

            // Pick the largest window by area
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

    private func handleSystemEvent(_ event: SystemEventHandler.SystemEvent) async {
        switch event {
        case .didWake:
            logger.info("System woke from sleep")
            if autoRecordEnabled && autoRecordOnWake {
                await meetingDetector.handleSystemWake()
            }
        case .willSleep:
            logger.info("System going to sleep")
            await meetingDetector.handleSystemSleep()
        case .screenLocked:
            logger.info("Screen locked")
        case .screenUnlocked:
            logger.info("Screen unlocked")
            // Optionally check for meetings when screen unlocks
            if autoRecordEnabled && autoRecordOnWake {
                await meetingDetector.handleSystemWake()
            }
        }
    }
}

// MARK: - Meeting Detector Error

enum MeetingDetectorError: Error {
    case delegateNotAvailable
}

// MARK: - Settings View

struct SettingsView: View {
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar - centered
            SettingsTabBar(selectedTab: $selectedTab)

            Divider()
                .foregroundColor(Theme.Colors.border)

            // Content area
            Group {
                switch selectedTab {
                case 0:
                    GeneralSettingsView()
                case 1:
                    AISettingsView()
                case 2:
                    PrivacySettingsView()
                case 3:
                    AdvancedSettingsView()
                case 4:
                    AboutSettingsView()
                default:
                    GeneralSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 560, height: 520)
        .background(Theme.Colors.background)
    }
}

struct SettingsTabBar: View {
    @Binding var selectedTab: Int

    private let tabs = [
        ("General", "gear"),
        ("AI", "sparkles"),
        ("Privacy", "hand.raised.fill"),
        ("Advanced", "slider.horizontal.3"),
        ("About", "info.circle")
    ]

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(0..<tabs.count, id: \.self) { index in
                SettingsTabButton(
                    title: tabs[index].0,
                    icon: tabs[index].1,
                    isSelected: selectedTab == index
                ) {
                    withAnimation(Theme.Animation.fast) {
                        selectedTab = index
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Colors.surface)
    }
}

struct SettingsTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : (isHovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? Theme.Colors.primary : (isHovered ? Theme.Colors.surfaceHover : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autoRecord") private var autoRecord = true
    @AppStorage("autoTranscribe") private var autoTranscribe = true
    @AppStorage("whisperModel") private var whisperModel = "small.en"
    @AppStorage("storageLocation") private var storageLocation = "~/Documents/Engram"
    @AppStorage("autoRecordOnWake") private var autoRecordOnWake: Bool = true
    @AppStorage("recordVideoEnabled") private var recordVideoEnabled: Bool = false
    @AppStorage("windowSelectionMode") private var windowSelectionMode: String = "smart"

    // Login item state
    @State private var launchAtLogin: Bool = false
    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var isLoadingLoginStatus: Bool = true
    @State private var loginItemError: String?
    @State private var showLoginItemError: Bool = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Startup Section
                SettingsSection(title: "Startup", icon: "power") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Launch at Login")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)
                                Text("Automatically start Engram when you log in")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            if isLoadingLoginStatus {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 51, height: 31) // Match toggle size
                            } else {
                                Toggle("", isOn: $launchAtLogin)
                                    .toggleStyle(.switch)
                                    .tint(Theme.Colors.primary)
                                    .labelsHidden()
                                    .onChange(of: launchAtLogin) { _, newValue in
                                        setLoginItemEnabled(newValue)
                                    }
                            }
                        }

                        // Show status if requires approval (using cached status to avoid blocking main thread)
                        if !isLoadingLoginStatus && loginItemStatus == .requiresApproval {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 11))
                                Text("Open System Settings > General > Login Items to approve")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                            }
                            .padding(.top, 8)
                        }
                    }
                }
                .task {
                    // Load login item status asynchronously to avoid blocking main thread
                    // SMAppService.mainApp.status is slow (~1-3s) as it queries launch services
                    await loadLoginItemStatusAsync()
                }
                .alert("Login Item Error", isPresented: $showLoginItemError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(loginItemError ?? "An unknown error occurred")
                }

                // Recording Section
                SettingsSection(title: "Recording", icon: "waveform") {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsToggle(
                            title: "Auto-record Meetings",
                            subtitle: "Automatically start recording when a meeting app uses your microphone",
                            isOn: $autoRecord
                        )

                        Divider().padding(.vertical, 8)

                        SettingsToggle(
                            title: "Auto-transcribe recordings",
                            subtitle: "Automatically transcribe recordings when they finish",
                            isOn: $autoTranscribe
                        )

                        Divider().padding(.vertical, 8)

                        SettingsToggle(
                            title: "Resume on wake",
                            subtitle: "Check for active meetings when your Mac wakes from sleep",
                            isOn: $autoRecordOnWake
                        )

                        Divider().padding(.vertical, 8)

                        SettingsToggle(
                            title: "Record screen video",
                            subtitle: "Capture meeting window video along with audio (uses more storage)",
                            isOn: $recordVideoEnabled
                        )

                        if recordVideoEnabled {
                            Divider().padding(.vertical, 8)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Window selection")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                Picker("", selection: $windowSelectionMode) {
                                    Text("Smart").tag("smart")
                                    Text("Always Ask").tag("alwaysAsk")
                                    Text("Auto").tag("auto")
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()

                                Text(windowSelectionHelpText)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }
                            .padding(.leading, 8)
                        }
                    }
                }

                // Meeting Apps Section
                if autoRecord {
                    SettingsSection(title: "Meeting Apps", icon: "app.badge.checkmark") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Select which apps to monitor for meetings:")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)

                            MeetingAppsPickerView()
                        }
                    }
                }

                // Transcription Section
                SettingsSection(title: "Transcription", icon: "text.quote") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Whisper Model")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.Colors.textPrimary)

                        Picker("", selection: $whisperModel) {
                            Text("Tiny").tag("tiny.en")
                            Text("Base").tag("base.en")
                            Text("Small (Recommended)").tag("small.en")
                            Text("Medium").tag("medium.en")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: whisperModel) { oldValue, newValue in
                            // Reload Whisper model when user changes selection
                            Task {
                                if let appDelegate = NSApp.delegate as? AppDelegate {
                                    await appDelegate.reloadWhisperModel()
                                }
                            }
                        }

                        Text("Larger models are more accurate but use more resources. Changes take effect immediately.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Colors.textMuted)
                    }
                }

                // Storage Section
                SettingsSection(title: "Storage", icon: "folder") {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.Colors.secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Storage Location")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Colors.textPrimary)
                            Text(storageLocation)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button("Change...") {
                            chooseStorageLocation()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.Colors.background)
    }

    private func chooseStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            storageLocation = url.path
        }
    }

    private var windowSelectionHelpText: String {
        switch windowSelectionMode {
        case "alwaysAsk":
            return "You'll choose which window to record for every meeting"
        case "auto":
            return "Automatically picks the meeting window without asking"
        default:
            return "Detects meeting window automatically, asks only if uncertain"
        }
    }

    /// Loads login item status asynchronously to avoid blocking the main thread
    /// SMAppService.mainApp.status is slow (~1-3s) as it communicates with launch services daemon
    private func loadLoginItemStatusAsync() async {
        isLoadingLoginStatus = true

        // Run the slow status check on a background thread
        let status = await Task.detached(priority: .userInitiated) {
            SMAppService.mainApp.status
        }.value

        // Update UI on main thread
        await MainActor.run {
            loginItemStatus = status
            updateLoginItemStateFromCachedStatus()
            isLoadingLoginStatus = false
        }
    }

    /// Updates the toggle state based on the cached SMAppService status (fast, no system calls)
    private func updateLoginItemStateFromCachedStatus() {
        switch loginItemStatus {
        case .enabled:
            launchAtLogin = true
        case .notRegistered, .notFound:
            launchAtLogin = false
        case .requiresApproval:
            // User needs to approve in System Settings, but we keep it "on" to show intent
            launchAtLogin = true
        @unknown default:
            launchAtLogin = false
        }
    }

    /// Registers or unregisters the app as a login item
    private func setLoginItemEnabled(_ enabled: Bool) {
        // Use cached status to avoid blocking main thread with repeated status checks
        let currentStatus = loginItemStatus

        do {
            if enabled {
                // Check if already enabled to avoid unnecessary registration
                if currentStatus != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                // Only unregister if currently registered
                if currentStatus == .enabled || currentStatus == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            }
            // Refresh status asynchronously after change
            Task {
                await loadLoginItemStatusAsync()
            }
        } catch {
            loginItemError = error.localizedDescription
            showLoginItemError = true
            // Refresh status asynchronously to revert toggle to actual state
            Task {
                await loadLoginItemStatusAsync()
            }
        }
    }
}

struct PrivacySettingsView: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .center, spacing: 24) {
                // Privacy hero
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Theme.Colors.successMuted)
                            .frame(width: 72, height: 72)

                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 32))
                            .foregroundColor(Theme.Colors.success)
                    }

                    VStack(spacing: 8) {
                        Text("Privacy First")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Theme.Colors.textPrimary)

                        Text("Engram processes all audio locally on your device.\nNo data is ever sent to external servers.")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)

                // Privacy features
                VStack(alignment: .leading, spacing: 0) {
                    PrivacyFeatureRow(
                        icon: "internaldrive.fill",
                        title: "Audio stored locally",
                        description: "All recordings are saved only on your Mac"
                    )

                    Divider().padding(.vertical, 10)

                    PrivacyFeatureRow(
                        icon: "cpu.fill",
                        title: "On-device AI transcription",
                        description: "WhisperKit runs entirely on your hardware"
                    )

                    Divider().padding(.vertical, 10)

                    PrivacyFeatureRow(
                        icon: "icloud.slash.fill",
                        title: "No cloud uploads",
                        description: "Your audio never leaves your device"
                    )

                    Divider().padding(.vertical, 10)

                    PrivacyFeatureRow(
                        icon: "chart.bar.xaxis",
                        title: "No analytics or tracking",
                        description: "Zero telemetry, no usage data collected"
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.Colors.borderSubtle, lineWidth: 1)
                )
            }
            .padding(20)
        }
        .background(Theme.Colors.background)
    }
}

struct PrivacyFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Theme.Colors.success)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.Colors.textPrimary)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Colors.textMuted)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(Theme.Colors.success)
        }
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("sampleRate") private var sampleRate = 48000
    @AppStorage("audioQuality") private var audioQuality = "high"
    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Audio Quality Section
                SettingsSection(title: "Audio Quality", icon: "waveform.badge.plus") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sample Rate")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Colors.textPrimary)

                            Picker("", selection: $sampleRate) {
                                Text("44.1 kHz").tag(44100)
                                Text("48 kHz").tag(48000)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Quality Preset")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Colors.textPrimary)

                            Picker("", selection: $audioQuality) {
                                Text("Standard").tag("standard")
                                Text("High").tag("high")
                                Text("Maximum").tag("maximum")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text("Higher quality uses more disk space")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                        }
                    }
                }

                // Reset Section
                SettingsSection(title: "Reset", icon: "arrow.counterclockwise") {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset All Settings")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Colors.textPrimary)
                            Text("Restore all settings to their defaults")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                        }

                        Spacer()

                        Button("Reset") {
                            showResetConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Theme.Colors.error)
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.Colors.background)
        .alert("Reset All Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetAllSettings()
            }
        } message: {
            Text("This will restore all settings to their defaults. This cannot be undone.")
        }
    }

    private func resetAllSettings() {
        // Reset all AppStorage values to defaults
        UserDefaults.standard.removeObject(forKey: "autoRecord")
        UserDefaults.standard.removeObject(forKey: "autoTranscribe")
        UserDefaults.standard.removeObject(forKey: "whisperModel")
        UserDefaults.standard.removeObject(forKey: "storageLocation")
        UserDefaults.standard.removeObject(forKey: "autoRecordOnWake")
        UserDefaults.standard.removeObject(forKey: "recordVideoEnabled")
        UserDefaults.standard.removeObject(forKey: "sampleRate")
        UserDefaults.standard.removeObject(forKey: "audioQuality")
        UserDefaults.standard.removeObject(forKey: "enabledMeetingApps")
        UserDefaults.standard.removeObject(forKey: "customMeetingApps")
        UserDefaults.standard.removeObject(forKey: "autoGenerateSummary")
        UserDefaults.standard.removeObject(forKey: "autoGenerateActionItems")

        // Reload custom apps manager to reflect cleared state
        CustomMeetingAppsManager.shared.loadCustomApps()

        // Unregister login item if registered
        let status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval {
            try? SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - AI Settings View

@available(macOS 14.0, *)
struct AISettingsView: View {
    @StateObject private var aiService = AIServiceObservable()
    @AppStorage("aiEnabled") private var aiEnabled = true
    @AppStorage("autoIndexTranscripts") private var autoIndexTranscripts = true
    @AppStorage("autoGenerateSummary") private var autoGenerateSummary = true
    @AppStorage("autoGenerateActionItems") private var autoGenerateActionItems = true
    @State private var isRebuildingIndex = false

    // MARK: - Pending State (unified apply)
    /// Pending provider selection (nil means no change from current)
    @State private var pendingProvider: AIService.Provider?
    /// Pending OpenAI API key
    @State private var pendingOpenAIKey: String = ""
    /// Pending OpenAI base URL
    @State private var pendingOpenAIBaseURL: String = ""
    /// Pending OpenAI model name
    @State private var pendingOpenAIModel: String = ""
    /// Pending OpenAI temperature
    @State private var pendingOpenAITemperature: Float = 1.0
    /// Pending MLX model ID (nil means no change from current)
    @State private var pendingMLXModel: String?
    /// Whether initial values have been loaded from service
    @State private var hasLoadedInitial = false
    /// Whether changes are currently being applied
    @State private var isApplyingChanges = false
    /// Error message from last apply attempt
    @State private var applyError: String?
    /// Whether to show clear models confirmation dialog
    @State private var showClearModelsConfirmation = false
    /// Message shown after clearing models
    @State private var clearedBytesMessage: String?

    private var availableModels: [ModelRegistry.ModelInfo] {
        ModelRegistry.availableModels
    }

    /// The effective selected provider (uses pending if set, otherwise current)
    private var effectiveSelectedProvider: AIService.Provider {
        pendingProvider ?? aiService.provider
    }

    /// The effective selected MLX model (uses pending if set, otherwise current)
    private var effectiveSelectedMLXModel: String {
        pendingMLXModel ?? aiService.selectedModelId
    }

    /// Whether there are any unsaved changes across all settings
    private var hasUnsavedChanges: Bool {
        // Provider changed
        if let pending = pendingProvider, pending != aiService.provider {
            return true
        }

        // Check OpenAI config if using OpenAI (current or pending)
        if effectiveSelectedProvider == .openAICompatible {
            if pendingOpenAIKey != aiService.openAIKey ||
               pendingOpenAIBaseURL != aiService.openAIBaseURL ||
               pendingOpenAIModel != aiService.openAIModel ||
               pendingOpenAITemperature != aiService.openAITemperature {
                return true
            }
        }

        // Check MLX model if using local MLX (current or pending)
        if effectiveSelectedProvider == .localMLX {
            if let pending = pendingMLXModel, pending != aiService.selectedModelId {
                return true
            }
        }

        return false
    }

    /// Description of what's currently active
    private var currentlyUsingDescription: String {
        switch aiService.provider {
        case .localMLX:
            if case .ready(let name) = aiService.status {
                return "Local MLX - \(name)"
            } else if let modelInfo = ModelRegistry.model(for: aiService.selectedModelId) {
                return "Local MLX - \(modelInfo.displayName) (not loaded)"
            } else {
                return "Local MLX - No model configured"
            }
        case .openAICompatible:
            if case .ready = aiService.status {
                return "OpenAI API - \(aiService.openAIModel)"
            } else {
                return "OpenAI API - Not connected"
            }
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Master AI Toggle
                SettingsSection(title: "AI Features", icon: "sparkles") {
                    Toggle(isOn: $aiEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable AI Features")
                                .font(Theme.Typography.body)
                            Text("Turn off to disable all AI functionality including chat, summaries, and indexing")
                                .font(Theme.Typography.caption)
                                .foregroundColor(Theme.Colors.textSecondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if !aiEnabled {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "info.circle")
                                .foregroundColor(Theme.Colors.warning)
                            Text("AI is disabled. Model is not loaded and no AI features are available.")
                                .font(Theme.Typography.caption)
                                .foregroundColor(Theme.Colors.warning)
                        }
                        .padding(.top, Theme.Spacing.xs)
                    }
                }

                // Status Section - Shows current AI state
                statusSection

                // AI Provider Section
                SettingsSection(title: "AI Provider", icon: "cpu") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Currently using indicator
                        HStack(spacing: 8) {
                            Circle()
                                .fill(aiService.isReady ? Theme.Colors.success : Theme.Colors.textMuted)
                                .frame(width: 8, height: 8)
                            Text("Currently using:")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                            Text(currentlyUsingDescription)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.Colors.textPrimary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.Colors.surface)
                        )

                        // MARK: - Unsaved Changes Banner (Prominent Location)
                        if hasUnsavedChanges {
                            VStack(spacing: 10) {
                                // Unsaved changes banner
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(Theme.Colors.warning)
                                        .font(.system(size: 14))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("You have unsaved changes")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(Theme.Colors.textPrimary)
                                        Text(unsavedChangesDescription)
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.Colors.textMuted)
                                    }
                                    Spacer()
                                }

                                // Error display
                                if let error = applyError {
                                    HStack(spacing: 8) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(Theme.Colors.error)
                                            .font(.system(size: 14))
                                        Text(error)
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.Colors.error)
                                        Spacer()
                                        Button {
                                            applyError = nil
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10))
                                                .foregroundColor(Theme.Colors.textMuted)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.Colors.errorMuted)
                                    )
                                }

                                // Action buttons
                                HStack(spacing: 12) {
                                    Button {
                                        Task {
                                            await discardAllChanges()
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.uturn.backward")
                                                .font(.system(size: 11))
                                            Text("Discard")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(isApplyingChanges)

                                    Spacer()

                                    Button {
                                        applyAllChanges()
                                    } label: {
                                        HStack(spacing: 6) {
                                            if isApplyingChanges {
                                                ProgressView()
                                                    .controlSize(.mini)
                                                    .frame(width: 12, height: 12)
                                            } else {
                                                Image(systemName: "checkmark.circle")
                                                    .font(.system(size: 11))
                                            }
                                            Text(isApplyingChanges ? "Applying..." : "Apply Changes")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(isApplyingChanges)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Theme.Colors.warningMuted)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.Colors.warning.opacity(0.5), lineWidth: 1.5)
                            )
                        }

                        Picker("Provider", selection: Binding(
                            get: { effectiveSelectedProvider == .localMLX ? "local-mlx" : "openai" },
                            set: { newValue in
                                // Only update pending state - don't apply immediately
                                pendingProvider = (newValue == "local-mlx") ? .localMLX : .openAICompatible
                            }
                        )) {
                            Text("Local (MLX)").tag("local-mlx")
                            Text("OpenAI API").tag("openai")
                        }
                        .pickerStyle(.segmented)

                        Text(providerDescription)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Colors.textMuted)
                    }
                }

                // Model Selection Section (for local provider)
                if effectiveSelectedProvider == .localMLX {
                    // Embedding info section
                    SettingsSection(title: "Embeddings", icon: "text.magnifyingglass") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Theme.Colors.success)
                                    .font(.system(size: 14))
                                Text("Built-in macOS Embeddings")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Theme.Colors.textPrimary)
                            }
                            Text("Uses Apple's NaturalLanguage framework for text embeddings. No download required.")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // Chat Model Section
                    SettingsSection(title: "Chat Model", icon: "sparkles") {
                        VStack(alignment: .leading, spacing: 12) {
                            // Header with explanation
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.primary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Select and activate a model for AI chat")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(Theme.Colors.textSecondary)
                                    Text("Models are downloaded from Hugging Face. Larger models provide better quality but require more memory.")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.Colors.textMuted)
                                }
                            }
                            .padding(.bottom, 4)

                            // Legend
                            HStack(spacing: 12) {
                                legendItem(color: Theme.Colors.success, text: "Active")
                                legendItem(color: Theme.Colors.secondary, text: "Sleeping")
                                legendItem(color: Theme.Colors.secondary.opacity(0.6), text: "Downloaded")
                                legendItem(color: Theme.Colors.textMuted, text: "Not Downloaded")
                            }
                            .padding(.bottom, 8)

                            // Model list
                            ForEach(availableModels) { model in
                                modelRow(model)
                            }
                        }
                    }
                }

                // OpenAI Configuration Section
                if effectiveSelectedProvider == .openAICompatible {
                    SettingsSection(title: "OpenAI Configuration", icon: "key") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("API Key")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                SecureField("sk-...", text: $pendingOpenAIKey)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.Colors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(pendingOpenAIKey != aiService.openAIKey ? Theme.Colors.warning : Theme.Colors.border, lineWidth: 1)
                                    )
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Base URL (optional)")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                TextField("https://api.openai.com/v1", text: $pendingOpenAIBaseURL)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.Colors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(pendingOpenAIBaseURL != aiService.openAIBaseURL ? Theme.Colors.warning : Theme.Colors.border, lineWidth: 1)
                                    )

                                Text("Leave empty for default OpenAI endpoint")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Model")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                TextField("gpt-4o-mini", text: $pendingOpenAIModel)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.Colors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(pendingOpenAIModel != aiService.openAIModel ? Theme.Colors.warning : Theme.Colors.border, lineWidth: 1)
                                    )
                            }

                            temperatureSlider

                            // Test connection button (tests with pending values)
                            HStack(spacing: 8) {
                                Button {
                                    testConnectionWithPendingValues()
                                } label: {
                                    if aiService.isTestingConnection {
                                        HStack(spacing: 6) {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(width: 14, height: 14)
                                            Text("Testing...")
                                        }
                                    } else {
                                        HStack(spacing: 6) {
                                            Image(systemName: "antenna.radiowaves.left.and.right")
                                                .font(.system(size: 12))
                                            Text("Test Connection")
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(pendingOpenAIKey.isEmpty || aiService.isTestingConnection)

                                Text("Tests with your entered values (before applying)")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }

                            // Connection test result feedback
                            if let result = aiService.connectionTestResult {
                                connectionTestResultView(result)
                            }
                        }
                    }
                }

                // Indexing Section
                SettingsSection(title: "Indexing", icon: "doc.text.magnifyingglass") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: "Auto-index new transcripts",
                            subtitle: "Automatically index transcripts for AI search when created",
                            isOn: $autoIndexTranscripts
                        )

                        Divider()

                        SettingsToggle(
                            title: "Auto-generate summary",
                            subtitle: "Automatically create AI summary when transcript is ready",
                            isOn: $autoGenerateSummary
                        )

                        Divider()

                        SettingsToggle(
                            title: "Auto-generate action items",
                            subtitle: "Automatically extract action items when transcript is ready",
                            isOn: $autoGenerateActionItems
                        )

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Indexed Recordings")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)
                                if aiService.isIndexingLoading {
                                    HStack(spacing: 4) {
                                        ProgressView()
                                            .controlSize(.mini)
                                        Text("Loading index...")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.Colors.textMuted)
                                    }
                                } else {
                                    Text("\(aiService.indexedCount) recordings indexed for AI search")
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.Colors.textMuted)
                                }
                            }

                            Spacer()

                            Button {
                                rebuildIndex()
                            } label: {
                                if isRebuildingIndex {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Rebuild")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isRebuildingIndex)
                        }
                    }
                }

                // Memory Management Section (only for local MLX)
                if effectiveSelectedProvider == .localMLX {
                    memoryManagementSection
                }

                // Storage Section
                SettingsSection(title: "Model Storage", icon: "internaldrive") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Storage location
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Storage Location")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)
                                Text(modelStoragePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.Colors.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Button("Reveal") {
                                revealModelStorage()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Divider()

                        // Clear models row
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Downloaded Models")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)
                                Text(aiService.cachedModelsSizeFormatted)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }

                            Spacer()

                            Button {
                                showClearModelsConfirmation = true
                            } label: {
                                if aiService.isClearingModels {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Clear All")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(Theme.Colors.error)
                            .disabled(aiService.isClearingModels || aiService.cachedModelsSize == 0)
                        }

                        // Success message after clearing
                        if let message = clearedBytesMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Theme.Colors.success)
                                    .font(.system(size: 12))
                                Text(message)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.success)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.Colors.background)
        .alert("Clear All AI Models?", isPresented: $showClearModelsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                clearAllModels()
            }
        } message: {
            Text("This will delete all downloaded AI models (\(aiService.cachedModelsSizeFormatted)) and free up disk space. You can download models again anytime.")
        }
        .task {
            await initializePendingState()
        }
        .onChange(of: aiService.openAIKey) { _, newValue in
            // Keep pending state in sync if not explicitly changed by user
            if !hasLoadedInitial {
                pendingOpenAIKey = newValue
            }
        }
        .onChange(of: aiService.openAIBaseURL) { _, newValue in
            if !hasLoadedInitial {
                pendingOpenAIBaseURL = newValue
            }
        }
        .onChange(of: aiService.openAIModel) { _, newValue in
            if !hasLoadedInitial {
                pendingOpenAIModel = newValue
            }
        }
        .onChange(of: aiService.openAITemperature) { _, newValue in
            if !hasLoadedInitial {
                pendingOpenAITemperature = newValue
            }
        }
    }

    // MARK: - Temperature Slider

    @ViewBuilder
    private var temperatureSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Temperature")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.textPrimary)
                Spacer()
                Text(String(format: "%.1f", pendingOpenAITemperature))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(pendingOpenAITemperature != aiService.openAITemperature ? Theme.Colors.warning : Theme.Colors.textSecondary)
            }

            Slider(value: $pendingOpenAITemperature, in: 0.0...2.0, step: 0.1)
                .tint(pendingOpenAITemperature != aiService.openAITemperature ? Theme.Colors.warning : Theme.Colors.primary)

            Text("Lower = more deterministic, higher = more creative (default: 1.0)")
                .font(.system(size: 11))
                .foregroundColor(Theme.Colors.textMuted)
        }
    }

    // MARK: - Memory Management Section

    @ViewBuilder
    private var memoryManagementSection: some View {
        SettingsSection(title: "Memory Management", icon: "memorychip") {
            VStack(alignment: .leading, spacing: 12) {
                // Auto-unload toggle
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-unload Model When Idle")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.Colors.textPrimary)
                        Text("Free ~3GB of memory when AI isn't being used")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Colors.textMuted)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { aiService.autoUnloadEnabled },
                        set: { newValue in
                            aiService.setAutoUnload(enabled: newValue, minutes: aiService.autoUnloadMinutes)
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(Theme.Colors.primary)
                    .labelsHidden()
                }

                // Timeout picker (only shown when auto-unload is enabled)
                if aiService.autoUnloadEnabled {
                    Divider()

                    HStack {
                        Text("Unload After")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.Colors.textPrimary)

                        Spacer()

                        Picker("", selection: Binding(
                            get: { aiService.autoUnloadMinutes },
                            set: { newValue in
                                aiService.setAutoUnload(enabled: aiService.autoUnloadEnabled, minutes: newValue)
                            }
                        )) {
                            Text("2 minutes").tag(2)
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                            Text("30 minutes").tag(30)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)
                    }

                    Text("The model will reload automatically when you use AI features.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Colors.textMuted)
                }

                // Current status indicator
                if case .unloadedToSaveMemory(let modelName) = aiService.status {
                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundColor(Theme.Colors.primary)
                            .font(.system(size: 14))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Model is sleeping")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.Colors.textPrimary)
                            Text("\(modelName) was unloaded to save memory")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.Colors.primaryMuted)
                    )
                }
            }
        }
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        SettingsSection(title: "Status", icon: "info.circle") {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(aiService.statusColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Colors.textPrimary)
                    Text(aiService.statusText)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Colors.textMuted)
                }

                Spacer()

                // Action button based on status
                if case .error = aiService.status {
                    Button("Retry") {
                        aiService.setupModel(aiService.selectedModelId)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var statusTitle: String {
        switch aiService.status {
        case .notConfigured:
            return "Not Configured"
        case .unloadedToSaveMemory:
            return "Sleeping"
        case .downloading:
            return "Downloading"
        case .loading:
            return "Loading"
        case .ready:
            return "Ready"
        case .error:
            return "Error"
        }
    }

    // MARK: - Legend Item

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(Theme.Colors.textMuted)
        }
    }

    // MARK: - Tier Badge

    private func tierBadge(_ tier: ModelRegistry.Tier) -> some View {
        let (color, bgColor): (Color, Color) = {
            switch tier {
            case .tiny:
                return (Theme.Colors.textSecondary, Theme.Colors.surface)
            case .light:
                return (Theme.Colors.secondary, Theme.Colors.secondaryMuted)
            case .standard:
                return (Theme.Colors.primary, Theme.Colors.primaryMuted)
            case .pro:
                return (Theme.Colors.warning, Theme.Colors.warningMuted)
            }
        }()

        return Text(tier.rawValue)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(bgColor)
            )
    }

    // MARK: - Model Row

    private func modelRow(_ model: ModelRegistry.ModelInfo) -> some View {
        let isCurrentModel = aiService.selectedModelId == model.id
        let isCached = aiService.isModelCached(model.id)
        let isActive = isCurrentModel && aiService.isReady
        let isSleeping = isCurrentModel && aiService.isUnloadedToSaveMemory
        let isPendingSelection = pendingMLXModel == model.id && model.id != aiService.selectedModelId
        // Include "pending initial load" state: when service is initializing and this cached model will be auto-loaded
        // isIndexingLoading is true when service is not initialized or currently initializing
        let isPendingInitialLoad = isCurrentModel && isCached && aiService.isIndexingLoading && !aiService.isReady
        let isCurrentlyLoading = isCurrentModel && aiService.isLoading || isPendingInitialLoad

        return HStack(spacing: 12) {
            // Radio button style indicator
            ZStack {
                Circle()
                    .stroke(isActive ? Theme.Colors.success :
                           (isSleeping ? Theme.Colors.secondary :
                           (isPendingSelection ? Theme.Colors.warning :
                           (isCached ? Theme.Colors.secondary : Theme.Colors.textMuted))), lineWidth: 2)
                    .frame(width: 18, height: 18)

                if isActive {
                    Circle()
                        .fill(Theme.Colors.success)
                        .frame(width: 10, height: 10)
                } else if isSleeping {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 8))
                        .foregroundColor(Theme.Colors.secondary)
                } else if isPendingSelection {
                    Circle()
                        .fill(Theme.Colors.warning)
                        .frame(width: 10, height: 10)
                } else if isCurrentlyLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                }
            }

            // Model info
            VStack(alignment: .leading, spacing: 4) {
                // First row: Name + badges
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: isActive || isSleeping || isPendingSelection ? .semibold : .medium))
                        .foregroundColor(isActive ? Theme.Colors.success :
                                        (isSleeping ? Theme.Colors.secondary :
                                        (isPendingSelection ? Theme.Colors.warning : Theme.Colors.textPrimary)))

                    tierBadge(model.tier)

                    if model.isDefault {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text("Default")
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Theme.Colors.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Theme.Colors.primaryMuted)
                        )
                    }

                    if isActive {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8))
                            Text("Active")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Theme.Colors.success)
                        )
                    }

                    if isSleeping {
                        HStack(spacing: 2) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 8))
                            Text("Sleeping")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Theme.Colors.secondary)
                        )
                    }

                    if isPendingSelection {
                        HStack(spacing: 2) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 8))
                            Text("Pending")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Theme.Colors.warning)
                        )
                    }
                }

                // Second row: Description
                Text(model.description)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Colors.textMuted)
                    .lineLimit(1)

                // Third row: Size, Memory, Download status
                HStack(spacing: 12) {
                    // Size info
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 9))
                        Text(model.sizeString)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Colors.textMuted)

                    // Memory requirement
                    HStack(spacing: 4) {
                        Image(systemName: "memorychip")
                            .font(.system(size: 9))
                        Text(String(format: "%.1f GB RAM", model.memoryGB))
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Colors.textMuted)

                    // Download status indicator
                    if isCached {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                            Text("Downloaded")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.Colors.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 9))
                            Text("Not Downloaded")
                        }
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.textMuted)
                    }
                }
            }

            Spacer()

            // Action buttons
            if isActive {
                // Already active - show status
                VStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.Colors.success)
                    Text("In Use")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.Colors.success)
                }
            } else if isSleeping {
                // Sleeping - show status with wake button
                VStack(spacing: 2) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.Colors.secondary)
                    Text("Sleeping")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.Colors.secondary)
                }
            } else if isPendingSelection {
                // Pending selection - show undo option
                Button {
                    pendingMLXModel = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 12))
                        Text("Undo")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Theme.Colors.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .stroke(Theme.Colors.warning, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Cancel selection")
            } else if isCurrentlyLoading {
                // Currently loading this model
                VStack(spacing: 2) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.Colors.textMuted)
                }
            } else if aiService.isLoading {
                // Loading a different model - disable buttons
                EmptyView()
            } else if isCached {
                // Downloaded but not active - show Select button (activates immediately)
                Button {
                    // Activate the cached model immediately for better UX
                    pendingMLXModel = model.id
                    aiService.setupModel(model.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12))
                        Text("Activate")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Theme.Colors.primary)
                    )
                }
                .buttonStyle(.plain)
                .help("Activate this model")
            } else {
                // Not downloaded - show Download button (downloads immediately, then sets pending)
                Button {
                    // For non-cached models, we need to download first
                    // Set pending and start download
                    pendingMLXModel = model.id
                    aiService.setupModel(model.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12))
                        Text("Download")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Theme.Colors.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .stroke(Theme.Colors.primary, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Download and select this model (\(model.sizeString))")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Theme.Colors.success.opacity(0.08) :
                      (isSleeping ? Theme.Colors.secondary.opacity(0.08) :
                      (isPendingSelection ? Theme.Colors.warning.opacity(0.08) :
                      (isCached ? Theme.Colors.secondary.opacity(0.05) : Theme.Colors.background))))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Theme.Colors.success.opacity(0.4) :
                        (isSleeping ? Theme.Colors.secondary.opacity(0.5) :
                        (isPendingSelection ? Theme.Colors.warning.opacity(0.5) :
                        (isCached ? Theme.Colors.secondary.opacity(0.2) : Theme.Colors.borderSubtle))),
                        lineWidth: isActive || isSleeping || isPendingSelection ? 2 : 1)
        )
    }

    // MARK: - Computed Properties

    private var providerDescription: String {
        switch effectiveSelectedProvider {
        case .localMLX:
            return "Uses Apple's MLX framework for on-device AI. Best for Apple Silicon Macs. Your data stays private."
        case .openAICompatible:
            return "Uses OpenAI's API. Requires internet connection and API key. Faster but data is sent to OpenAI."
        }
    }

    private var modelStoragePath: String {
        // MLX models are cached in ~/.cache/huggingface/hub
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cache/huggingface/hub").path
    }

    // MARK: - Views

    @ViewBuilder
    private func connectionTestResultView(_ result: AIServiceObservable.ConnectionTestResult) -> some View {
        HStack(spacing: 6) {
            switch result {
            case .success(let modelCount):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
                if modelCount > 0 {
                    Text("Connected! (\(modelCount) models available)")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                } else {
                    Text("Connected!")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                }
            case .failure(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 14))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    /// Initialize pending state from current service values
    /// Reads directly from AIService.shared.currentConfig to avoid race condition
    /// with AIServiceObservable's async loadFromService()
    private func initializePendingState() async {
        guard !hasLoadedInitial else { return }
        let config = await AIService.shared.currentConfig
        pendingOpenAIKey = config.openAIKey
        pendingOpenAIBaseURL = config.openAIBaseURL
        pendingOpenAIModel = config.openAIModel
        pendingOpenAITemperature = config.openAITemperature
        pendingProvider = nil
        pendingMLXModel = nil
        hasLoadedInitial = true
        logToFile("[Settings] Initialized pending state from service config: key=\(config.openAIKey.isEmpty ? "(empty)" : "(set)"), baseURL=\(config.openAIBaseURL.isEmpty ? "(empty)" : config.openAIBaseURL), model=\(config.openAIModel)")
    }

    /// Discard all pending changes and reset to current values
    /// Reads directly from AIService.shared.currentConfig for consistency
    private func discardAllChanges() async {
        let config = await AIService.shared.currentConfig
        pendingProvider = nil
        pendingMLXModel = nil
        pendingOpenAIKey = config.openAIKey
        pendingOpenAIBaseURL = config.openAIBaseURL
        pendingOpenAIModel = config.openAIModel
        pendingOpenAITemperature = config.openAITemperature
        applyError = nil
        aiService.clearConnectionTestResult()
        logToFile("[Settings] Discarded all pending changes")
    }

    /// Description of what changes are pending
    private var unsavedChangesDescription: String {
        var changes: [String] = []

        if let pending = pendingProvider, pending != aiService.provider {
            changes.append("Provider: \(pending == .localMLX ? "Local MLX" : "OpenAI API")")
        }

        if effectiveSelectedProvider == .openAICompatible {
            if pendingOpenAIKey != aiService.openAIKey {
                changes.append("API Key")
            }
            if pendingOpenAIBaseURL != aiService.openAIBaseURL {
                changes.append("Base URL")
            }
            if pendingOpenAIModel != aiService.openAIModel {
                changes.append("Model: \(pendingOpenAIModel)")
            }
            if pendingOpenAITemperature != aiService.openAITemperature {
                changes.append("Temperature: \(String(format: "%.1f", pendingOpenAITemperature))")
            }
        }

        if effectiveSelectedProvider == .localMLX {
            if let pending = pendingMLXModel, pending != aiService.selectedModelId {
                if let modelInfo = ModelRegistry.model(for: pending) {
                    changes.append("Model: \(modelInfo.displayName)")
                } else {
                    changes.append("Model changed")
                }
            }
        }

        return changes.isEmpty ? "Configuration changes" : changes.joined(separator: ", ")
    }

    /// Apply all pending changes at once
    private func applyAllChanges() {
        logToFile("[Settings] applyAllChanges called")
        isApplyingChanges = true
        applyError = nil

        Task {
            do {
                let targetProvider = pendingProvider ?? aiService.provider

                // 1. If provider changed, switch provider first
                if let newProvider = pendingProvider, newProvider != aiService.provider {
                    logToFile("[Settings] Switching provider to \(newProvider.rawValue)")
                    try await AIService.shared.setProvider(newProvider)
                }

                // 2. Configure OpenAI when using OpenAI provider with a key
                // Always call configureOpenAI() to ensure backend is properly initialized
                if targetProvider == .openAICompatible && !pendingOpenAIKey.isEmpty {
                    logToFile("[Settings] Configuring OpenAI with settings (temperature: \(pendingOpenAITemperature))")
                    try await AIService.shared.configureOpenAI(
                        apiKey: pendingOpenAIKey,
                        baseURL: pendingOpenAIBaseURL.isEmpty ? nil : pendingOpenAIBaseURL,
                        model: pendingOpenAIModel,
                        temperature: pendingOpenAITemperature
                    )
                    // Explicitly ensure provider is set to OpenAI after successful configuration
                    // This guarantees the provider change is saved even if setProvider() used old config values
                    logToFile("[Settings] Ensuring provider is set to openAICompatible after configureOpenAI")
                    try await AIService.shared.setProvider(.openAICompatible)
                }

                // 3. If MLX model changed (and using local MLX)
                if targetProvider == .localMLX {
                    if let newModel = pendingMLXModel, newModel != aiService.selectedModelId {
                        logToFile("[Settings] Setting up MLX model: \(newModel)")
                        try await AIService.shared.setupModel(newModel)
                    }
                }

                // Success - reset pending state
                await MainActor.run {
                    pendingProvider = nil
                    pendingMLXModel = nil
                    // Update pending OpenAI values to match what was saved
                    pendingOpenAIKey = aiService.openAIKey
                    pendingOpenAIBaseURL = aiService.openAIBaseURL
                    pendingOpenAIModel = aiService.openAIModel
                    pendingOpenAITemperature = aiService.openAITemperature
                    isApplyingChanges = false
                    aiService.clearConnectionTestResult()
                    logToFile("[Settings] applyAllChanges completed successfully")
                }
            } catch {
                await MainActor.run {
                    applyError = error.localizedDescription
                    isApplyingChanges = false
                    logToFile("[Settings] applyAllChanges failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Test OpenAI connection with pending values (not saved values)
    /// This does NOT modify aiService state - it only tests with the provided values
    private func testConnectionWithPendingValues() {
        guard !pendingOpenAIKey.isEmpty else {
            return
        }

        aiService.clearConnectionTestResult()

        // Test with pending values directly without modifying aiService state
        // This prevents the service from being left in a broken/polluted state
        aiService.testOpenAIConnectionWith(apiKey: pendingOpenAIKey, baseURL: pendingOpenAIBaseURL)
    }

    private func rebuildIndex() {
        isRebuildingIndex = true
        logToFile("[Settings] Rebuild button clicked")
        Task {
            do {
                logToFile("[Settings] Calling AIService.rebuildIndex...")
                try await AIService.shared.rebuildIndex()
                logToFile("[Settings] Rebuild completed successfully")
            } catch {
                logToFile("[Settings] Rebuild failed: \(error.localizedDescription)")
                print("Failed to rebuild index: \(error.localizedDescription)")
            }
            await MainActor.run {
                isRebuildingIndex = false
            }
        }
    }

    private func logToFile(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("engram_rag.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func revealModelStorage() {
        let url = URL(fileURLWithPath: modelStoragePath)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    private func clearAllModels() {
        clearedBytesMessage = nil
        Task {
            do {
                let bytesCleared = try await aiService.clearAllModels()
                await MainActor.run {
                    let formatter = ByteCountFormatter()
                    formatter.countStyle = .file
                    clearedBytesMessage = "Cleared \(formatter.string(fromByteCount: bytesCleared))"

                    // Clear message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        clearedBytesMessage = nil
                    }
                }
                logToFile("[Settings] Cleared \(bytesCleared) bytes of AI models")
            } catch {
                logToFile("[Settings] Failed to clear models: \(error.localizedDescription)")
            }
        }
    }
}

struct AboutSettingsView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon and name
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [Theme.Colors.primary, Theme.Colors.secondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)

                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                }
                .shadow(color: Theme.Colors.primary.opacity(0.3), radius: 10, y: 3)

                VStack(spacing: 4) {
                    Text("Engram")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.Colors.textPrimary)

                    Text("Version \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Colors.textMuted)
                }
            }

            Spacer().frame(height: 20)

            // Description
            VStack(spacing: 6) {
                Text("Your meetings, remembered.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Colors.textSecondary)
                    .italic()

                Text("Privacy-first meeting recorder with\nlocal AI transcription")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Colors.textMuted)
                    .multilineTextAlignment(.center)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 24)

            // Links
            HStack(spacing: 16) {
                AboutLink(title: "Website", icon: "globe", urlString: "https://balakumar.dev")
                AboutLink(title: "GitHub", icon: "chevron.left.forwardslash.chevron.right", urlString: "https://github.com/nickkumara")
            }

            Spacer()

            // Developer attribution - more prominent
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("Crafted by")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Colors.textMuted)

                    Text("Bala Kumar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Colors.textSecondary)
                }

                Button(action: {
                    if let url = URL(string: "https://balakumar.dev") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 10))
                        Text("balakumar.dev")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Theme.Colors.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)

            // Footer
            Text("© 2024-2026 Bala Kumar. All rights reserved.")
                .font(.system(size: 10))
                .foregroundColor(Theme.Colors.textMuted)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
    }
}

struct AboutLink: View {
    let title: String
    let icon: String
    let urlString: String?

    @State private var isHovered = false

    init(title: String, icon: String, urlString: String? = nil) {
        self.title = title
        self.icon = icon
        self.urlString = urlString
    }

    var body: some View {
        Button {
            if let urlString = urlString, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundColor(isHovered ? Theme.Colors.primary : Theme.Colors.textSecondary)
            .frame(width: 64, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Theme.Colors.surfaceHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Settings Helpers

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Colors.primary)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Colors.textMuted)
                    .tracking(0.5)
            }

            // Section content
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.Colors.borderSubtle, lineWidth: 1)
                )
        }
    }
}

struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Theme.Colors.primary)
                .labelsHidden()
        }
    }
}
