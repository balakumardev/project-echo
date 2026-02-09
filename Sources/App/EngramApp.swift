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
import Darwin  // For signal handlers (SIGTERM, SIGINT)

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
    static let openAIChatPanel = Notification.Name("dev.balakumar.engram.openAIChatPanel")
}

// MARK: - Window Action Holder
// Allows AppDelegate to trigger SwiftUI window actions
@MainActor
enum WindowActions {
    static var openLibrary: (() -> Void)?
    static var openSettings: (() -> Void)?
    static var openAIChatPanel: (() -> Void)?
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

        // Observe AI chat panel request — opens library + shows chat panel
        NotificationCenter.default.addObserver(
            forName: .openAIChatPanel,
            object: nil,
            queue: .main
        ) { [self] _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "library")
                UserDefaults.standard.set(true, forKey: "showChatPanel_v2")
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

            // AI Chat menu item — opens library + shows chat panel
            CommandGroup(after: .windowList) {
                Button("AI Chat") {
                    openWindow(id: "library")
                    UserDefaults.standard.set(true, forKey: "showChatPanel_v2")
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            }
        }

        // Settings window
        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gear") }
                TranscriptionSettingsView()
                    .tabItem { Label("Transcription", systemImage: "waveform") }
                AISettingsView()
                    .tabItem { Label("AI", systemImage: "sparkles") }
                AboutSettingsView()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
            .frame(width: 620, height: 750)
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
        WindowActions.openAIChatPanel = { [openWindow] in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "library")
            UserDefaults.standard.set(true, forKey: "showChatPanel_v2")
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

        // Register as transcription settings delegate (for UI → App module communication)
        SettingsEnvironment.transcriptionDelegate = self

        // Setup menu bar
        menuBarController = MenuBarController()
        menuBarController.delegate = self

        // Setup Meeting Detection
        setupMeetingDetection()

        // Setup signal handlers for graceful termination
        setupSignalHandlers()

        logger.info("Engram ready")
    }

    /// Setup signal handlers for SIGTERM and SIGINT to attempt graceful recording finalization
    private func setupSignalHandlers() {
        // SIGTERM - sent by `kill` command or system shutdown
        signal(SIGTERM) { _ in
            FileLogger.shared.debug("SIGTERM received - requesting app termination")
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }

        // SIGINT - sent by Ctrl+C in terminal
        signal(SIGINT) { _ in
            FileLogger.shared.debug("SIGINT received - requesting app termination")
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }

        logger.info("Signal handlers configured for graceful termination")
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

        // Set up notification observers for UI requests
        setupProcessingNotificationObservers()
    }

    /// Set up notification observers for UI-initiated processing requests
    private func setupProcessingNotificationObservers() {
        // Handle transcription requests from UI (e.g., "Generate Transcript" button)
        NotificationCenter.default.addObserver(
            forName: .transcriptionRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let recordingId = userInfo["recordingId"] as? Int64,
                  let audioURL = userInfo["audioURL"] as? URL else {
                FileLogger.shared.debug("[ProcessingQueue] Invalid transcription request notification")
                return
            }

            FileLogger.shared.debug("[ProcessingQueue] Received transcription request for recording \(recordingId)")

            Task {
                let result = await ProcessingQueue.shared.queueTranscription(
                    recordingId: recordingId,
                    audioURL: audioURL
                )

                switch result {
                case .queued:
                    FileLogger.shared.debug("[ProcessingQueue] Transcription queued for recording \(recordingId)")
                case .alreadyInProgress:
                    FileLogger.shared.debug("[ProcessingQueue] Transcription already in progress for recording \(recordingId)")
                case .alreadyQueued:
                    FileLogger.shared.debug("[ProcessingQueue] Transcription already queued for recording \(recordingId)")
                }
            }
        }

        // Handle processing status requests from UI (e.g., when loading a recording)
        NotificationCenter.default.addObserver(
            forName: .processingStatusRequested,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let recordingId = userInfo["recordingId"] as? Int64 else {
                return
            }

            Task {
                let isTranscribing = await ProcessingQueue.shared.isTranscribingRecording(recordingId)

                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .processingStatusResponse,
                        object: nil,
                        userInfo: [
                            "recordingId": recordingId,
                            "isTranscribing": isTranscribing
                        ]
                    )
                }
            }
        }

        FileLogger.shared.debug("Processing notification observers configured")
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
        let currentProvider = await transcriptionEngine.currentConfig.provider
        FileLogger.shared.debug("[Init] TranscriptionEngine created, provider: \(currentProvider.rawValue)")

        // Load Whisper model if using local provider
        // Also attempt load for Gemini users as fallback
        let engine = transcriptionEngine
        let log = logger
        do {
            try await engine?.loadModel()
            FileLogger.shared.debug("[Init] Whisper model loaded successfully")
            log.info("Whisper model loaded")
        } catch {
            FileLogger.shared.debugError("[Init] Failed to load Whisper model", error: error)
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
                    _ = await ProcessingQueue.shared.queueTranscription(recordingId: recordingId, audioURL: url)
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
        if let action = WindowActions.openAIChatPanel {
            action()
        } else {
            // Fallback: Post notification to open library + chat panel
            logger.info("Using notification fallback to open AI chat panel")
            NotificationCenter.default.post(name: .openAIChatPanel, object: nil)
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

    /// Push transcription settings from UserDefaults to the running TranscriptionEngine,
    /// and reload the Whisper model if needed. Called via SettingsEnvironment.transcriptionDelegate.
    func applyTranscriptionConfig() async throws {
        let oldConfig = await transcriptionEngine.currentConfig
        let newConfig = TranscriptionConfig.load()
        await transcriptionEngine.setConfig(newConfig)
        FileLogger.shared.debug("[Settings] Transcription config pushed to engine: provider=\(newConfig.provider.rawValue), geminiModel=\(newConfig.geminiModel.rawValue)")
        logger.info("Transcription config updated on running engine: provider=\(newConfig.provider.rawValue)")

        // Reload Whisper model if the model changed and we're using local provider
        if newConfig.provider == .local && newConfig.whisperModel != oldConfig.whisperModel {
            logger.info("Reloading Whisper model due to settings change...")
            FileLogger.shared.debug("[Settings] Whisper model changed from \(oldConfig.whisperModel) to \(newConfig.whisperModel), reloading...")
            try await transcriptionEngine.reloadModel()
            let modelName = await transcriptionEngine.currentModelVariant
            logger.info("Whisper model reloaded: \(modelName)")
            FileLogger.shared.debug("[Settings] Whisper model reloaded: \(modelName)")
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
            // Log detailed error info for debugging
            let errorDetail: String
            if let txError = error as? TranscriptionEngine.TranscriptionError {
                switch txError {
                case .modelNotLoaded:
                    errorDetail = "modelNotLoaded - Whisper model not loaded. Restart the app or check Settings."
                case .audioConversionFailed:
                    errorDetail = "audioConversionFailed - Failed to convert audio file."
                case .transcriptionFailed:
                    errorDetail = "transcriptionFailed - Transcription produced no results."
                case .configurationError(let msg):
                    errorDetail = "configurationError - \(msg)"
                case .geminiError(let msg):
                    errorDetail = "geminiError - \(msg)"
                }
            } else {
                errorDetail = "\(type(of: error)): \(error.localizedDescription)"
            }
            FileLogger.shared.debug("[transcribeRecording] FAILED for recording \(id) | \(errorDetail)")
            logger.error("Auto-transcription failed for recording \(id): \(errorDetail)")

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
            _ = await ProcessingQueue.shared.queueTranscription(recordingId: recordingId, audioURL: url)
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

    // MARK: - App Termination Handling

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application will terminate - attempting graceful recording shutdown")
        FileLogger.shared.debug("applicationWillTerminate called - finalizing recordings")

        // Use a semaphore to block until finalization completes (or timeout)
        let semaphore = DispatchSemaphore(value: 0)
        let timeout = DispatchTime.now() + .seconds(5)

        Task {
            await finalizeActiveRecordings()
            semaphore.signal()
        }

        // Wait for finalization (with timeout to avoid hanging)
        let result = semaphore.wait(timeout: timeout)
        if result == .timedOut {
            logger.warning("Recording finalization timed out during app termination")
            FileLogger.shared.debug("applicationWillTerminate: finalization timed out after 5s")
        } else {
            FileLogger.shared.debug("applicationWillTerminate: finalization completed")
        }
    }

    /// Emergency finalization of any active recordings
    /// Called during app termination to save as much data as possible
    private func finalizeActiveRecordings() async {
        // Check if we have active recordings
        guard currentRecordingURL != nil || currentVideoRecordingURL != nil else {
            FileLogger.shared.debug("finalizeActiveRecordings: no active recordings to finalize")
            return
        }

        logger.info("Finalizing active recordings...")
        FileLogger.shared.debug("finalizeActiveRecordings: starting emergency finalization")

        // Stop audio recording
        if currentRecordingURL != nil {
            do {
                _ = try await audioEngine.stopRecording()
                FileLogger.shared.debug("finalizeActiveRecordings: audio recording finalized")
            } catch {
                logger.error("Failed to finalize audio recording: \(error.localizedDescription)")
                FileLogger.shared.debug("finalizeActiveRecordings: audio finalization failed: \(error)")
            }
        }

        // Stop video recording
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
}

// MARK: - Meeting Detector Error

enum MeetingDetectorError: Error {
    case delegateNotAvailable
}

// MARK: - TranscriptionSettingsDelegate Conformance

@available(macOS 14.0, *)
extension AppDelegate: TranscriptionSettingsDelegate {}

