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
                PermissionSetupView()
                    .tabItem { Label("Permissions", systemImage: "lock.shield") }
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

    // Coordinators
    private var recordingCoordinator: RecordingCoordinator!
    private var aiContentCoordinator: AIContentCoordinator!

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

    // Legacy (kept for migration)
    @AppStorage("monitoredApps") private var monitoredAppsRaw = "Zoom,Microsoft Teams,Google Chrome,FaceTime"

    // Permissions
    private let permissionManager = PermissionManager()
    @AppStorage("hasCompletedPermissionSetup") private var hasCompletedPermissionSetup = false

    // State
    private var outputDirectory: URL!
    
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

            // Check permissions on launch — open Settings to Permissions tab if needed
            permissionManager.checkAll()
            if !permissionManager.allRequiredGranted && !hasCompletedPermissionSetup {
                // Short delay to let the menu bar and windows initialize
                try? await Task.sleep(nanoseconds: 500_000_000)
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            } else if permissionManager.allRequiredGranted {
                hasCompletedPermissionSetup = true
            }
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
            await self?.aiContentCoordinator?.autoGenerateAIContent(recordingId: recordingId)
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
        let autoSummaryEnabled = UserDefaults.standard.object(forKey: "autoGenerateSummary") as? Bool ?? true
        let autoActionItemsEnabled = UserDefaults.standard.object(forKey: "autoGenerateActionItems") as? Bool ?? true

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

            // Initialize coordinators now that all dependencies are ready
            recordingCoordinator = RecordingCoordinator(
                audioEngine: audioEngine,
                screenRecorder: screenRecorder,
                mediaMuxer: mediaMuxer,
                database: database,
                outputDirectory: outputDirectory
            )
            recordingCoordinator.onRecordingStateChanged = { [weak self] isRecording in
                self?.menuBarController.setRecording(isRecording)
            }
            recordingCoordinator.onError = { [weak self] message in
                self?.showErrorAlert(message: message)
            }
            recordingCoordinator.onPermissionError = { [weak self] in
                self?.showPermissionAlert()
            }
            recordingCoordinator.onRecordingStopped = { [weak self] in
                await self?.meetingDetector.resetRecordingState()
            }

            aiContentCoordinator = AIContentCoordinator(database: database)

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
            let coordinator = aiContentCoordinator
            Task.detached(priority: .background) {
                do {
                    try await AIService.shared.initialize()
                    aiLog.info("AI Service initialized")

                    // After AI is ready, regenerate titles for recordings with summaries but generic titles
                    await coordinator?.regenerateMissingTitles()
                } catch {
                    aiLog.warning("AI Service initialization failed: \(error.localizedDescription)")
                }
            }
        } else {
            logger.info("AI Service disabled by user preference, skipping initialization")
        }
    }
    
    /// Opens the Settings window to the Permissions tab instead of the old NSAlert
    @MainActor
    private func openPermissionSettings() {
        logger.info("Opening Settings for permission setup")
        if let action = WindowActions.openSettings {
            action()
        } else {
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        }
    }
    
    // MARK: - MenuBarDelegate

    func menuBarDidRequestStartRecording() {
        recordingCoordinator.startManualRecording()
    }

    func menuBarDidRequestStopRecording() {
        recordingCoordinator.stopManualRecording()
    }

    func menuBarDidRequestInsertMarker() {
        recordingCoordinator.insertMarker()
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
                await aiContentCoordinator.autoIndexTranscript(recordingId: id, transcriptId: transcriptId)
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
                    return try await self.recordingCoordinator.startMeetingRecording(
                        for: appName,
                        getMeetingBundleID: { await detector.getCurrentRecordingBundleID() }
                    )
                },
                stopRecording: { [weak self] detector in
                    guard let self = self else { return }
                    try await self.recordingCoordinator.stopMeetingRecording()
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
            recordingCoordinator?.currentRecordingApp = app
        case .endingMeeting(let app):
            logger.info("Meeting ending for: \(app)")
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Menu bar app — keep running when windows are closed
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application will terminate - attempting graceful recording shutdown")
        FileLogger.shared.debug("applicationWillTerminate called - finalizing recordings")

        // Use a semaphore to block until finalization completes (or timeout)
        let semaphore = DispatchSemaphore(value: 0)
        let timeout = DispatchTime.now() + .seconds(5)

        Task {
            await recordingCoordinator?.finalizeActiveRecordings()
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
}

// MARK: - Meeting Detector Error

enum MeetingDetectorError: Error {
    case delegateNotAvailable
}

// MARK: - TranscriptionSettingsDelegate Conformance

@available(macOS 14.0, *)
extension AppDelegate: TranscriptionSettingsDelegate {}

