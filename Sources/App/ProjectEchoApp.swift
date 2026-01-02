import SwiftUI
import AppKit
import Combine
import AudioEngine
import Intelligence
import Database
import UI
import os.log

// Import Theme from UI module
@_exported import enum UI.Theme

// Note: debugLog is defined in MeetingDetector.swift and is available here

// MARK: - Window Action Holder
// Allows AppDelegate to trigger SwiftUI window actions
@MainActor
enum WindowActions {
    static var openLibrary: (() -> Void)?
    static var openSettings: (() -> Void)?
}

@main
@available(macOS 14.0, *)
struct ProjectEchoApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "projectecho" else { return }

        // Activate app and bring to front
        NSApp.activate(ignoringOtherApps: true)

        // Open the library window via SwiftUI
        openWindow(id: "library")
    }

    var body: some Scene {
        // Library window
        WindowGroup("Project Echo Library", id: "library") {
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
        }

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
    }
}

// MARK: - App Delegate

@MainActor
@available(macOS 14.0, *)
class AppDelegate: NSObject, NSApplicationDelegate, MenuBarDelegate {

    private let logger = Logger(subsystem: "com.projectecho.app", category: "App")

    // Core engines
    private var audioEngine: AudioCaptureEngine!
    private var screenRecorder: ScreenRecorder!
    private var mediaMuxer: MediaMuxer!
    private var transcriptionEngine: TranscriptionEngine!
    private var database: DatabaseManager!

    // UI
    private var menuBarController: MenuBarController!

    // Meeting Detection (new)
    private var meetingDetector: MeetingDetector!
    private var systemEventHandler: SystemEventHandler!
    private var systemEventTask: Task<Void, Never>?

    // Auto Recording Settings
    @AppStorage("autoRecord") private var autoRecordEnabled = true
    @AppStorage("enabledMeetingApps") private var enabledMeetingAppsRaw = "zoom,teams,meet,slack,discord"
    @AppStorage("autoRecordOnWake") private var autoRecordOnWake: Bool = true

    // Legacy (kept for migration)
    @AppStorage("monitoredApps") private var monitoredAppsRaw = "Zoom,Microsoft Teams,Google Chrome,FaceTime"

    // State
    private var currentRecordingURL: URL?
    private var currentVideoRecordingURL: URL?
    private var outputDirectory: URL!
    private var currentRecordingApp: String?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Project Echo starting...")

        // Hide dock icon (menu bar only app)
        NSApp.setActivationPolicy(.accessory)

        // Setup output directory
        setupOutputDirectory()

        // Initialize components
        Task {
            await initializeComponents()
        }

        // Setup menu bar
        menuBarController = MenuBarController()
        menuBarController.delegate = self

        // Setup Meeting Detection
        setupMeetingDetection()

        logger.info("Project Echo ready")
    }

    // MARK: - URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "projectecho" else { continue }
            logger.info("Handling URL: \(url.absoluteString)")

            // Activate and let SwiftUI's handlesExternalEvents handle the window
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    private func setupOutputDirectory() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputDirectory = documentsURL.appendingPathComponent("ProjectEcho/Recordings")
        
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

        // Load Whisper model in background
        let engine = transcriptionEngine
        let log = logger
        Task.detached(priority: .background) {
            do {
                try await engine?.loadModel()
                log.info("Whisper model loaded")
            } catch {
                log.error("Failed to load Whisper model: \(error.localizedDescription)")
            }
        }

        // Database
        do {
            database = try await DatabaseManager()
            logger.info("Database initialized")
        } catch {
            logger.error("Database initialization failed: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func showPermissionAlert() {
        let appPath = Bundle.main.bundlePath
        
        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = """
Project Echo needs Screen Recording and Microphone permissions.

For ad-hoc signed apps, you must manually add them:

1. Open System Settings → Privacy & Security
2. Go to Screen Recording → Click '+' → Add this app
3. Go to Microphone → Click '+' → Add this app
4. Restart Project Echo

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
                
                // Save to database
                if let url = currentRecordingURL {
                    let title = url.deletingPathExtension().lastPathComponent
                    let recordingId = try await database.saveRecording(
                        title: title,
                        date: Date(),
                        duration: metadata.duration,
                        fileURL: url,
                        fileSize: metadata.fileSize,
                        appName: detectActiveApp()
                    )
                    
                    logger.info("Recording saved to database: ID \(recordingId)")
                    
                    // Auto-transcribe in background
                    Task { [weak self] in
                        await self?.transcribeRecording(id: recordingId, url: url)
                    }
                }
                
                currentRecordingURL = nil
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
            // Fallback: Open via URL scheme (triggers handlesExternalEvents)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if let url = URL(string: "projectecho://library") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func menuBarDidRequestOpenSettings() {
        if let action = WindowActions.openSettings {
            // Use SwiftUI's openSettings if available
            action()
        } else {
            // Fallback: Use NSApp selector for settings
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // Try the macOS 14+ settings action
            if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                // Fallback for older versions
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
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
    
    private func transcribeRecording(id: Int64, url: URL) async {
        logger.info("Starting auto-transcription for recording \(id)")
        
        do {
            let result = try await transcriptionEngine.transcribe(audioURL: url)
            
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
            
            _ = try await database.saveTranscript(
                recordingId: id,
                fullText: result.text,
                language: result.language,
                processingTime: result.processingTime,
                segments: segments
            )
            
            logger.info("Transcription completed for recording \(id)")
        } catch {
            logger.error("Auto-transcription failed: \(error.localizedDescription)")
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
            debugLog("autoRecordEnabled = \(autoRecordEnabled)")
            if autoRecordEnabled {
                debugLog("Calling meetingDetector.start()...")
                await meetingDetector.start()
                debugLog("meetingDetector.start() completed")
                logger.info("Meeting detector started")
            } else {
                debugLog("Auto-record is DISABLED, not starting detector")
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
        if let bundleID = screenRecordBundleID {
            // Extract base filename from audio URL to keep timestamps synchronized
            let baseFilename = url.deletingPathExtension().lastPathComponent
            Task {
                do {
                    // First, try automatic detection using heuristics
                    let videoURL = try await screenRecorder.startRecording(
                        bundleId: bundleID,
                        outputDirectory: outputDirectory,
                        baseFilename: baseFilename
                    )
                    await MainActor.run {
                        currentVideoRecordingURL = videoURL
                    }
                    logger.info("Video recording started for \(bundleID): \(videoURL.lastPathComponent)")
                } catch ScreenRecorder.RecorderError.windowNotFound {
                    // Heuristics failed - fall back to window selector
                    logger.info("No clear meeting window found, checking for candidates...")

                    do {
                        let candidates = try await screenRecorder.getCandidateWindows(bundleId: bundleID)

                        if candidates.isEmpty {
                            logger.warning("No windows found for \(bundleID), skipping video recording")
                            return
                        }

                        let videoURL: URL
                        if candidates.count == 1 {
                            // Single window - auto-select
                            logger.info("Single candidate window, auto-selecting: \(candidates[0].title)")
                            videoURL = try await screenRecorder.startRecordingWindow(
                                windowId: candidates[0].id,
                                bundleId: bundleID,
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
                                bundleId: bundleID,
                                outputDirectory: outputDirectory,
                                baseFilename: baseFilename
                            )
                        }

                        await MainActor.run {
                            currentVideoRecordingURL = videoURL
                        }
                        logger.info("Video recording started for \(bundleID): \(videoURL.lastPathComponent)")
                    } catch {
                        logger.warning("Failed to get candidate windows: \(error.localizedDescription)")
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

            // Auto-transcribe in background
            Task { [weak self] in
                await self?.transcribeRecording(id: recordingId, url: url)
            }
        }

        currentRecordingURL = nil
        currentRecordingApp = nil
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
                    PrivacySettingsView()
                case 2:
                    AdvancedSettingsView()
                case 3:
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
    @AppStorage("whisperModel") private var whisperModel = "base.en"
    @AppStorage("storageLocation") private var storageLocation = "~/Documents/ProjectEcho"
    @AppStorage("autoRecordOnWake") private var autoRecordOnWake: Bool = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
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
                            Text("Small").tag("small.en")
                            Text("Medium").tag("medium.en")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text("Larger models are more accurate but use more resources")
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

                        Text("Project Echo processes all audio locally on your device.\nNo data is ever sent to external servers.")
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
        UserDefaults.standard.removeObject(forKey: "sampleRate")
        UserDefaults.standard.removeObject(forKey: "audioQuality")
        UserDefaults.standard.removeObject(forKey: "enabledMeetingApps")
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
                    Text("Project Echo")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.Colors.textPrimary)

                    Text("Version \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Colors.textMuted)
                }
            }

            Spacer().frame(height: 20)

            // Description
            Text("Privacy-first meeting recorder with\nlocal AI transcription")
                .font(.system(size: 13))
                .foregroundColor(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 24)

            // Links
            HStack(spacing: 16) {
                AboutLink(title: "Website", icon: "globe", urlString: "https://github.com/anthropics/project-echo")
                AboutLink(title: "GitHub", icon: "chevron.left.forwardslash.chevron.right", urlString: "https://github.com/anthropics/project-echo")
                AboutLink(title: "License", icon: "doc.text", urlString: "https://github.com/anthropics/project-echo/blob/main/LICENSE")
            }

            Spacer()

            // Footer
            Text("Made with privacy in mind")
                .font(.system(size: 11))
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
