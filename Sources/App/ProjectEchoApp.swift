import SwiftUI
import AppKit
import Combine
import AudioEngine
import Intelligence
import Database
import UI
import os.log

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

    // Auto Recording
    private var appMonitor: AppMonitor!
    @AppStorage("autoRecord") private var autoRecordEnabled = true
    @AppStorage("monitoredApps") private var monitoredAppsRaw = "Zoom,Microsoft Teams,Google Chrome,FaceTime"
    private var lastActiveApp: String?

    // State
    private var currentRecordingURL: URL?
    private var outputDirectory: URL!
    
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

        // Setup App Monitor
        setupAppMonitoring()

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
    
    // MARK: - Auto Recording Logic
    
    private func setupAppMonitoring() {
        appMonitor = AppMonitor()
        
        // Parse monitored apps
        let apps = monitoredAppsRaw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        Task {
            await appMonitor.startMonitoring(apps: apps)
        }
        
        // Listen for app activation
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        
        // Listen for app termination
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }
    
    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let appName = app.localizedName,
              autoRecordEnabled else { return }
        
        // Check if we should record this app
        let targetApps = monitoredAppsRaw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        
        if targetApps.contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
            logger.info("Detected monitored app activation: \(appName)")
            
            if currentRecordingURL == nil {
                startAutoRecording(for: appName)
            }
        }
    }
    
    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let appName = app.localizedName else { return }
        
        // If the app we were recording closed, stop recording
        // Note: This logic assumes we only record one thing at a time
        if let current = detectActiveApp(), current == appName {
             // Logic to stop if necessary, but usually we prefer manual stop or stop when meeting ends (hard to detect)
             // For now, let's keep recording running until user stops or we implement silence detection
        }
    }
    
    private func startAutoRecording(for appName: String) {
        logger.info("Auto-starting recording for \(appName)")
        // We reuse the existing start logic but need to be careful about not blocking main thread
        // or showing alerts in a way that disrupts the user
        
        let engine = audioEngine
        let dir = outputDirectory
        
        Task {
            do {
                // Ensure output directory exists (captured safely?)
                // outputDirectory is a var, so capturing it is tricky if we are in MainActor context it is fine?
                // Yes, we are MainActor isolated.
                
                // Let's use the property directly since we are in Task inheriting MainActor
                currentRecordingURL = try await engine?.startRecording(targetApp: appName, outputDirectory: dir!)
                logger.info("Auto-recording started for \(appName)")
                
                // Update Menu Bar
                menuBarController.setRecording(true)
                
            } catch {
                logger.error("Failed to auto-start recording: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("autoRecord") private var autoRecord = true
    @AppStorage("autoTranscribe") private var autoTranscribe = true
    @AppStorage("whisperModel") private var whisperModel = "base.en"
    @AppStorage("storageLocation") private var storageLocation = "~/Documents/ProjectEcho"
    
    var body: some View {
        TabView {
            GeneralSettingsView(
                autoRecord: $autoRecord,
                autoTranscribe: $autoTranscribe,
                whisperModel: $whisperModel,
                storageLocation: $storageLocation
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }
            
            PrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }
            
            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    @Binding var autoRecord: Bool
    @Binding var autoTranscribe: Bool
    @Binding var whisperModel: String
    @Binding var storageLocation: String
    
    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Auto-record Configured Apps", isOn: $autoRecord)
                    .help("Automatically start recording when Zoom, Teams, etc. are launched")
                
                Toggle("Auto-transcribe recordings", isOn: $autoTranscribe)
                    .help("Automatically transcribe recordings when they finish")
            }
            
            Section("Transcription") {
                Picker("Whisper Model", selection: $whisperModel) {
                    Text("Tiny (fastest)").tag("tiny.en")
                    Text("Base (recommended)").tag("base.en")
                    Text("Small (better quality)").tag("small.en")
                    Text("Medium (slow)").tag("medium.en")
                }
                .help("Larger models are more accurate but slower")
            }
            
            Section("Storage") {
                HStack {
                    TextField("Location", text: $storageLocation)
                    Button("Choose...") {
                        // TODO: Show folder picker
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct PrivacySettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Privacy First")
                .font(.headline)
            
            Text("Project Echo processes all audio locally on your device. No data is sent to external servers.")
                .foregroundColor(.secondary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Label("Audio stored locally", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Label("Transcription via on-device AI", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Label("No cloud uploads", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Label("No analytics or tracking", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .padding()
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("sampleRate") private var sampleRate = 48000
    @AppStorage("audioQuality") private var audioQuality = "high"
    
    var body: some View {
        Form {
            Section("Audio Quality") {
                Picker("Sample Rate", selection: $sampleRate) {
                    Text("44.1 kHz").tag(44100)
                    Text("48 kHz (recommended)").tag(48000)
                }
                
                Picker("Quality", selection: $audioQuality) {
                    Text("Standard").tag("standard")
                    Text("High").tag("high")
                    Text("Maximum").tag("maximum")
                }
            }
            
            Section("Performance") {
                Text("CPU usage optimization and buffer settings will be added here")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
