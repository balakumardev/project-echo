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
    @AppStorage("silenceTimeoutSeconds") private var silenceTimeout: Double = 45.0
    @AppStorage("audioActivitySeconds") private var audioActivityDuration: Double = 2.0
    @AppStorage("silenceThresholdDB") private var silenceThreshold: Double = -40.0
    @AppStorage("autoRecordOnWake") private var autoRecordOnWake: Bool = true

    // Legacy (kept for migration)
    @AppStorage("monitoredApps") private var monitoredAppsRaw = "Zoom,Microsoft Teams,Google Chrome,FaceTime"

    // State
    private var currentRecordingURL: URL?
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
            sustainedAudioDuration: audioActivityDuration,
            silenceDurationToEnd: silenceTimeout,
            silenceThresholdDB: Float(silenceThreshold),
            audioThresholdDB: Float(silenceThreshold + 5), // Activity threshold slightly above silence
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
            if autoRecordEnabled {
                await meetingDetector.start()
                logger.info("Meeting detector started")
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

        // Start recording
        let url = try await audioEngine.startRecording(targetApp: appName, outputDirectory: outputDirectory)
        currentRecordingURL = url
        currentRecordingApp = appName

        return url
    }

    private func stopMeetingRecording() async throws {
        logger.info("Stopping meeting recording")

        let metadata = try await audioEngine.stopRecording()

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
            // Custom tab bar
            SettingsTabBar(selectedTab: $selectedTab)

            Divider()
                .background(Theme.Colors.border)

            // Content
            TabView(selection: $selectedTab) {
                GeneralSettingsView()
                    .tag(0)

                PrivacySettingsView()
                    .tag(1)

                AdvancedSettingsView()
                    .tag(2)

                AboutSettingsView()
                    .tag(3)
            }
            .tabViewStyle(.automatic)
        }
        .frame(width: 560, height: 480)
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
        HStack(spacing: Theme.Spacing.xs) {
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
        .padding(Theme.Spacing.md)
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
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(Theme.Typography.callout)
                    .fontWeight(.medium)
            }
            .foregroundColor(isSelected ? Theme.Colors.textInverse : (isHovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary))
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
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
    @AppStorage("silenceTimeoutSeconds") private var silenceTimeout: Double = 45.0
    @AppStorage("audioActivitySeconds") private var audioActivityDuration: Double = 2.0
    @AppStorage("autoRecordOnWake") private var autoRecordOnWake: Bool = true

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                // Recording Section
                SettingsSection(title: "Recording", icon: "waveform") {
                    SettingsToggle(
                        title: "Auto-record Meetings",
                        subtitle: "Automatically start recording when audio activity is detected in meeting apps",
                        isOn: $autoRecord
                    )

                    SettingsToggle(
                        title: "Auto-transcribe recordings",
                        subtitle: "Automatically transcribe recordings when they finish",
                        isOn: $autoTranscribe
                    )

                    SettingsToggle(
                        title: "Resume on wake",
                        subtitle: "Check for active meetings when your Mac wakes from sleep",
                        isOn: $autoRecordOnWake
                    )
                }

                // Meeting Apps Section
                if autoRecord {
                    SettingsSection(title: "Meeting Apps", icon: "app.badge.checkmark") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Select which apps to monitor for meetings:")
                                .font(Theme.Typography.caption)
                                .foregroundColor(Theme.Colors.textMuted)

                            MeetingAppsPickerView()
                        }
                    }

                    // Detection Settings
                    SettingsSection(title: "Detection", icon: "waveform.badge.magnifyingglass") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                HStack {
                                    Text("Start recording after")
                                        .font(Theme.Typography.callout)
                                        .foregroundColor(Theme.Colors.textPrimary)
                                    Spacer()
                                    Text("\(Int(audioActivityDuration))s of audio")
                                        .font(Theme.Typography.callout)
                                        .foregroundColor(Theme.Colors.textSecondary)
                                }
                                Slider(value: $audioActivityDuration, in: 1...10, step: 1)
                                    .tint(Theme.Colors.primary)
                                Text("How long audio must be detected before recording starts")
                                    .font(Theme.Typography.caption)
                                    .foregroundColor(Theme.Colors.textMuted)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                HStack {
                                    Text("Stop recording after")
                                        .font(Theme.Typography.callout)
                                        .foregroundColor(Theme.Colors.textPrimary)
                                    Spacer()
                                    Text("\(Int(silenceTimeout))s of silence")
                                        .font(Theme.Typography.callout)
                                        .foregroundColor(Theme.Colors.textSecondary)
                                }
                                Slider(value: $silenceTimeout, in: 15...120, step: 15)
                                    .tint(Theme.Colors.primary)
                                Text("How long silence must continue before recording stops")
                                    .font(Theme.Typography.caption)
                                    .foregroundColor(Theme.Colors.textMuted)
                            }
                        }
                    }
                }

                // Transcription Section
                SettingsSection(title: "Transcription", icon: "text.quote") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Whisper Model")
                            .font(Theme.Typography.callout)
                            .foregroundColor(Theme.Colors.textPrimary)

                        Picker("", selection: $whisperModel) {
                            Text("Tiny (fastest)").tag("tiny.en")
                            Text("Base (recommended)").tag("base.en")
                            Text("Small (better quality)").tag("small.en")
                            Text("Medium (slow)").tag("medium.en")
                        }
                        .pickerStyle(.segmented)

                        Text("Larger models are more accurate but use more resources")
                            .font(Theme.Typography.caption)
                            .foregroundColor(Theme.Colors.textMuted)
                    }
                }

                // Storage Section
                SettingsSection(title: "Storage", icon: "folder") {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.Colors.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Storage Location")
                                .font(Theme.Typography.callout)
                                .foregroundColor(Theme.Colors.textPrimary)
                            Text(storageLocation)
                                .font(Theme.Typography.caption)
                                .foregroundColor(Theme.Colors.textMuted)
                        }

                        Spacer()

                        Button("Change...") {
                            chooseStorageLocation()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(Theme.Spacing.xl)
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
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Privacy hero
                VStack(spacing: Theme.Spacing.lg) {
                    ZStack {
                        Circle()
                            .fill(Theme.Colors.successMuted)
                            .frame(width: 80, height: 80)

                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 36))
                            .foregroundColor(Theme.Colors.success)
                    }

                    VStack(spacing: Theme.Spacing.sm) {
                        Text("Privacy First")
                            .font(Theme.Typography.title2)
                            .foregroundColor(Theme.Colors.textPrimary)

                        Text("Project Echo processes all audio locally on your device.\nNo data is ever sent to external servers.")
                            .font(Theme.Typography.body)
                            .foregroundColor(Theme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, Theme.Spacing.xl)

                // Privacy features
                VStack(spacing: Theme.Spacing.md) {
                    PrivacyFeatureRow(
                        icon: "internaldrive.fill",
                        title: "Audio stored locally",
                        description: "All recordings are saved only on your Mac"
                    )

                    PrivacyFeatureRow(
                        icon: "cpu.fill",
                        title: "On-device AI transcription",
                        description: "WhisperKit runs entirely on your hardware"
                    )

                    PrivacyFeatureRow(
                        icon: "icloud.slash.fill",
                        title: "No cloud uploads",
                        description: "Your audio never leaves your device"
                    )

                    PrivacyFeatureRow(
                        icon: "chart.bar.xaxis",
                        title: "No analytics or tracking",
                        description: "Zero telemetry, no usage data collected"
                    )
                }
                .padding(Theme.Spacing.lg)
                .surfaceBackground()
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Colors.background)
    }
}

struct PrivacyFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(Theme.Colors.success)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.callout)
                    .fontWeight(.medium)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text(description)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(Theme.Colors.success)
        }
        .padding(.vertical, Theme.Spacing.sm)
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("sampleRate") private var sampleRate = 48000
    @AppStorage("audioQuality") private var audioQuality = "high"

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                // Audio Quality Section
                SettingsSection(title: "Audio Quality", icon: "waveform.badge.plus") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Sample Rate")
                                .font(Theme.Typography.callout)
                                .foregroundColor(Theme.Colors.textPrimary)

                            Picker("", selection: $sampleRate) {
                                Text("44.1 kHz").tag(44100)
                                Text("48 kHz (recommended)").tag(48000)
                            }
                            .pickerStyle(.segmented)
                        }

                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Quality Preset")
                                .font(Theme.Typography.callout)
                                .foregroundColor(Theme.Colors.textPrimary)

                            Picker("", selection: $audioQuality) {
                                Text("Standard").tag("standard")
                                Text("High").tag("high")
                                Text("Maximum").tag("maximum")
                            }
                            .pickerStyle(.segmented)

                            Text("Higher quality uses more disk space")
                                .font(Theme.Typography.caption)
                                .foregroundColor(Theme.Colors.textMuted)
                        }
                    }
                }

                // Performance Section
                SettingsSection(title: "Performance", icon: "gauge.with.needle") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack {
                            Image(systemName: "cpu")
                                .foregroundColor(Theme.Colors.secondary)
                            Text("CPU usage optimization and buffer settings")
                                .font(Theme.Typography.callout)
                                .foregroundColor(Theme.Colors.textSecondary)
                        }

                        Text("Coming in a future update")
                            .font(Theme.Typography.caption)
                            .foregroundColor(Theme.Colors.textMuted)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(Theme.Colors.warningMuted)
                            .cornerRadius(Theme.Radius.xs)
                    }
                }

                // Reset Section
                SettingsSection(title: "Reset", icon: "arrow.counterclockwise") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset All Settings")
                                .font(Theme.Typography.callout)
                                .foregroundColor(Theme.Colors.textPrimary)
                            Text("Restore all settings to their defaults")
                                .font(Theme.Typography.caption)
                                .foregroundColor(Theme.Colors.textMuted)
                        }

                        Spacer()

                        Button("Reset") {
                            // Reset settings
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.Colors.error)
                    }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Colors.background)
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            // App icon and name
            VStack(spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [Theme.Colors.primary, Theme.Colors.secondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)

                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                }
                .shadow(color: Theme.Colors.primary.opacity(0.3), radius: 12, y: 4)

                Text("Project Echo")
                    .font(Theme.Typography.title1)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text("Version 1.0.0")
                    .font(Theme.Typography.callout)
                    .foregroundColor(Theme.Colors.textMuted)
            }

            // Description
            Text("Privacy-first meeting recorder with\nlocal AI transcription")
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)

            // Links
            HStack(spacing: Theme.Spacing.lg) {
                AboutLink(title: "Website", icon: "globe")
                AboutLink(title: "GitHub", icon: "chevron.left.forwardslash.chevron.right")
                AboutLink(title: "License", icon: "doc.text")
            }

            Spacer()

            // Footer
            Text("Made with privacy in mind")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textMuted)
        }
        .padding(Theme.Spacing.xl)
        .background(Theme.Colors.background)
    }
}

struct AboutLink: View {
    let title: String
    let icon: String

    @State private var isHovered = false

    var body: some View {
        Button {
            // Open link
        } label: {
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title)
                    .font(Theme.Typography.caption)
            }
            .foregroundColor(isHovered ? Theme.Colors.primary : Theme.Colors.textSecondary)
            .frame(width: 70, height: 50)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
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
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Colors.primary)
                Text(title)
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)
            }

            content
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfaceBackground()
        }
    }
}

struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.callout)
                    .foregroundColor(Theme.Colors.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.Colors.primary)
    }
}
