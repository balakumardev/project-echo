import SwiftUI
import AppKit
import AudioEngine
import Intelligence
import Database
import UI
import os.log

@main
@available(macOS 14.0, *)
struct ProjectEchoApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Library window (hidden by default, menu bar app)
        WindowGroup("Project Echo Library") {
            LibraryView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        
        // Settings window
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

@available(macOS 14.0, *)
class AppDelegate: NSObject, NSApplicationDelegate, MenuBarDelegate {
    
    private let logger = Logger(subsystem: "com.projectecho.app", category: "App")
    
    // Core engines
    private var audioEngine: AudioCaptureEngine!
    private var transcriptionEngine: TranscriptionEngine!
    private var database: DatabaseManager!
    
    // UI
    private var menuBarController: MenuBarController!
    
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
        
        logger.info("Project Echo ready")
    }
    
    private func setupOutputDirectory() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputDirectory = documentsURL.appendingPathComponent("ProjectEcho/Recordings")
        
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        logger.info("Output directory: \(outputDirectory.path)")
    }
    
    private func initializeComponents() async {
        // Audio Engine
        audioEngine = AudioCaptureEngine()
        
        // Request permissions
        do {
            try await audioEngine.requestPermissions()
            logger.info("Permissions granted")
        } catch {
            logger.error("Permission denied: \(error.localizedDescription)")
            await showPermissionAlert()
        }
        
        // Transcription Engine
        transcriptionEngine = TranscriptionEngine()
        
        // Load Whisper model in background
        Task.detached(priority: .background) { [weak self] in
            do {
                try await self?.transcriptionEngine.loadModel()
                self?.logger.info("Whisper model loaded")
            } catch {
                self?.logger.error("Failed to load Whisper model: \(error.localizedDescription)")
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
        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = "Project Echo needs Screen Recording and Microphone permissions to function. Please grant these in System Settings > Privacy & Security."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else {
            NSApp.terminate(nil)
        }
    }
    
    // MARK: - MenuBarDelegate
    
    func menuBarDidRequestStartRecording() {
        Task {
            do {
                currentRecordingURL = try await audioEngine.startRecording(outputDirectory: outputDirectory)
                logger.info("Recording started: \(currentRecordingURL?.lastPathComponent ?? "unknown")")
            } catch {
                logger.error("Failed to start recording: \(error.localizedDescription)")
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
                    Task.detached(priority: .background) { [weak self] in
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
        Task {
            await audioEngine.insertMarker(label: "User Marker")
            logger.info("Marker inserted")
        }
    }
    
    func menuBarDidRequestOpenLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        
        // Open or focus library window
        if let window = NSApp.windows.first(where: { $0.title == "Project Echo Library" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // SwiftUI will create window automatically
        }
    }
    
    func menuBarDidRequestOpenSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("autoTranscribe") private var autoTranscribe = true
    @AppStorage("whisperModel") private var whisperModel = "base.en"
    @AppStorage("storageLocation") private var storageLocation = "~/Documents/ProjectEcho"
    
    var body: some View {
        TabView {
            GeneralSettingsView(
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
    @Binding var autoTranscribe: Bool
    @Binding var whisperModel: String
    @Binding var storageLocation: String
    
    var body: some View {
        Form {
            Section("Recording") {
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
