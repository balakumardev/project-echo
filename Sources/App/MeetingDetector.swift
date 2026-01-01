import Foundation
import AppKit
import AudioEngine
import os.log

/// Delegate protocol for meeting detection events
@available(macOS 14.0, *)
@MainActor
public protocol MeetingDetectorDelegate: AnyObject {
    /// Called when the detector state changes
    func meetingDetector(_ detector: MeetingDetector, didChangeState state: MeetingDetector.State)

    /// Called when recording should start - returns the recording URL
    func meetingDetectorDidRequestStartRecording(_ detector: MeetingDetector, for app: String) async throws -> URL

    /// Called when recording should stop
    func meetingDetectorDidRequestStopRecording(_ detector: MeetingDetector) async throws

    /// Called when an error occurs
    func meetingDetector(_ detector: MeetingDetector, didEncounterError error: Error)
}

/// Orchestrates app monitoring and audio level detection to automatically record meetings
@available(macOS 14.0, *)
public actor MeetingDetector {

    // MARK: - Types

    public enum State: Sendable, Equatable {
        case idle
        case monitoring(app: String)      // Monitored app is active, checking for audio
        case meetingDetected(app: String) // Audio detected, about to start recording
        case recording(app: String)       // Actively recording
        case endingMeeting(app: String)   // Silence detected, grace period before stopping
    }

    public struct Configuration: Sendable {
        public var sustainedAudioDuration: TimeInterval = 2.0    // Start after 2s audio
        public var silenceDurationToEnd: TimeInterval = 45.0     // End after 45s silence
        public var silenceThresholdDB: Float = -40.0             // dB threshold for "silence"
        public var audioThresholdDB: Float = -35.0               // dB threshold for "activity"
        public var enabledApps: Set<String> = ["zoom", "teams", "meet", "slack", "discord"]
        public var browserApps: Set<String> = ["Google Chrome", "Safari", "Microsoft Edge", "Firefox", "Arc"]
        public var checkOnWake: Bool = true

        public init(
            sustainedAudioDuration: TimeInterval = 2.0,
            silenceDurationToEnd: TimeInterval = 45.0,
            silenceThresholdDB: Float = -40.0,
            audioThresholdDB: Float = -35.0,
            enabledApps: Set<String> = ["zoom", "teams", "meet", "slack", "discord"],
            checkOnWake: Bool = true
        ) {
            self.sustainedAudioDuration = sustainedAudioDuration
            self.silenceDurationToEnd = silenceDurationToEnd
            self.silenceThresholdDB = silenceThresholdDB
            self.audioThresholdDB = audioThresholdDB
            self.enabledApps = enabledApps
            self.checkOnWake = checkOnWake
        }
    }

    /// Represents a supported meeting app
    public struct MeetingApp: Sendable, Identifiable, Equatable {
        public let id: String           // e.g. "zoom"
        public let displayName: String  // e.g. "Zoom"
        public let bundleId: String     // e.g. "us.zoom.xos"
        public let processName: String  // e.g. "zoom.us"
        public let icon: String         // SF Symbol
        public let browserBased: Bool   // true for Google Meet

        public init(id: String, displayName: String, bundleId: String, processName: String, icon: String, browserBased: Bool) {
            self.id = id
            self.displayName = displayName
            self.bundleId = bundleId
            self.processName = processName
            self.icon = icon
            self.browserBased = browserBased
        }
    }

    /// All supported meeting apps
    public static let supportedApps: [MeetingApp] = [
        MeetingApp(id: "zoom", displayName: "Zoom", bundleId: "us.zoom.xos", processName: "zoom.us", icon: "video.fill", browserBased: false),
        MeetingApp(id: "teams", displayName: "Microsoft Teams", bundleId: "com.microsoft.teams2", processName: "Microsoft Teams", icon: "person.3.fill", browserBased: false),
        MeetingApp(id: "meet", displayName: "Google Meet", bundleId: "", processName: "", icon: "globe", browserBased: true),
        MeetingApp(id: "slack", displayName: "Slack", bundleId: "com.tinyspeck.slackmacgap", processName: "Slack", icon: "bubble.left.fill", browserBased: false),
        MeetingApp(id: "discord", displayName: "Discord", bundleId: "com.hnc.Discord", processName: "Discord", icon: "headphones", browserBased: false),
        MeetingApp(id: "webex", displayName: "Webex", bundleId: "com.cisco.webexmeetingsapp", processName: "Webex", icon: "video.fill", browserBased: false),
        MeetingApp(id: "facetime", displayName: "FaceTime", bundleId: "com.apple.FaceTime", processName: "FaceTime", icon: "video.fill", browserBased: false),
        MeetingApp(id: "skype", displayName: "Skype", bundleId: "com.skype.skype", processName: "Skype", icon: "phone.fill", browserBased: false),
    ]

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.projectecho.app", category: "MeetingDetector")

    private var configuration: Configuration
    private var currentState: State = .idle
    private var isRunning = false

    // Components
    private var audioLevelMonitor: AudioLevelMonitor?
    private var appObservers: [NSObjectProtocol] = []

    // State tracking
    private var currentRecordingURL: URL?
    private var audioMonitorTask: Task<Void, Never>?
    private var appCheckTask: Task<Void, Never>?

    // Delegate (stored as weak reference via MainActor callback)
    private var delegateCallback: (@MainActor (MeetingDetector, State) -> Void)?
    private var startRecordingCallback: (@MainActor (MeetingDetector, String) async throws -> URL)?
    private var stopRecordingCallback: (@MainActor (MeetingDetector) async throws -> Void)?
    private var errorCallback: (@MainActor (MeetingDetector, Error) -> Void)?

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.audioLevelMonitor = AudioLevelMonitor(configuration: AudioLevelMonitor.Configuration(
            silenceThresholdDB: configuration.silenceThresholdDB,
            activityThresholdDB: configuration.audioThresholdDB,
            sustainedActivityDuration: configuration.sustainedAudioDuration,
            sustainedSilenceDuration: configuration.silenceDurationToEnd
        ))
    }

    // MARK: - Public API

    /// Set the delegate callbacks
    public func setDelegate(
        stateChanged: @escaping @MainActor (MeetingDetector, State) -> Void,
        startRecording: @escaping @MainActor (MeetingDetector, String) async throws -> URL,
        stopRecording: @escaping @MainActor (MeetingDetector) async throws -> Void,
        error: @escaping @MainActor (MeetingDetector, Error) -> Void
    ) {
        self.delegateCallback = stateChanged
        self.startRecordingCallback = startRecording
        self.stopRecordingCallback = stopRecording
        self.errorCallback = error
    }

    /// Start the detector
    public func start() async {
        guard !isRunning else {
            logger.info("MeetingDetector already running")
            return
        }

        logger.info("Starting MeetingDetector")
        isRunning = true

        // Setup app activation observers
        await setupAppObservers()

        // Start periodic check for running meeting apps
        startAppCheckLoop()

        logger.info("MeetingDetector started")
    }

    /// Stop the detector
    public func stop() async {
        guard isRunning else { return }

        logger.info("Stopping MeetingDetector")
        isRunning = false

        // Stop audio monitoring
        await stopAudioMonitoring()

        // Cancel tasks
        audioMonitorTask?.cancel()
        audioMonitorTask = nil
        appCheckTask?.cancel()
        appCheckTask = nil

        // Remove observers
        await removeAppObservers()

        // Update state
        await updateState(.idle)

        logger.info("MeetingDetector stopped")
    }

    /// Handle system wake event
    public func handleSystemWake() async {
        guard isRunning && configuration.checkOnWake else { return }

        logger.info("System woke - checking for active meetings")

        // Small delay to let apps reconnect
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Check for any running meeting apps
        await checkForActiveMeetingApps()
    }

    /// Handle system sleep event
    public func handleSystemSleep() async {
        logger.info("System sleeping")
        // Could optionally pause monitoring here
    }

    /// Force start recording (manual override)
    public func forceStartRecording(for appName: String) async throws {
        guard isRunning else { return }
        try await requestStartRecording(for: appName)
    }

    /// Force stop recording (manual override)
    public func forceStopRecording() async throws {
        guard isRunning else { return }
        try await requestStopRecording()
    }

    /// Update configuration
    public func updateConfiguration(_ newConfig: Configuration) async {
        self.configuration = newConfig

        // Update audio monitor configuration
        await audioLevelMonitor?.updateConfiguration(AudioLevelMonitor.Configuration(
            silenceThresholdDB: newConfig.silenceThresholdDB,
            activityThresholdDB: newConfig.audioThresholdDB,
            sustainedActivityDuration: newConfig.sustainedAudioDuration,
            sustainedSilenceDuration: newConfig.silenceDurationToEnd
        ))
    }

    /// Get current state
    public func getState() -> State {
        return currentState
    }

    /// Get list of enabled meeting apps
    public func getEnabledApps() -> [MeetingApp] {
        return Self.supportedApps.filter { configuration.enabledApps.contains($0.id) }
    }

    // MARK: - Private Methods

    private func setupAppObservers() async {
        let nc = NSWorkspace.shared.notificationCenter

        // App activation observer
        let activateObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract Sendable values from notification before passing to actor
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let appName = app.localizedName else { return }
            let bundleId = app.bundleIdentifier

            Task { await self?.handleAppActivation(appName: appName, bundleId: bundleId) }
        }
        appObservers.append(activateObserver)

        // App termination observer
        let terminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract Sendable values from notification before passing to actor
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let appName = app.localizedName else { return }
            let bundleId = app.bundleIdentifier

            Task { await self?.handleAppTermination(appName: appName, bundleId: bundleId) }
        }
        appObservers.append(terminateObserver)

        logger.info("App observers set up")
    }

    private func removeAppObservers() async {
        for observer in appObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        appObservers.removeAll()
    }

    private func handleAppActivation(appName: String, bundleId: String?) async {
        // Check if this is a monitored app
        if isMonitoredApp(appName: appName, bundleId: bundleId) {
            logger.info("Monitored app activated: \(appName)")
            await startMonitoringApp(appName)
        }
    }

    private func handleAppTermination(appName: String, bundleId: String?) async {
        // Check if this was the app we're monitoring/recording
        switch currentState {
        case .monitoring(let monitoredApp), .meetingDetected(let monitoredApp),
             .recording(let monitoredApp), .endingMeeting(let monitoredApp):
            if appName.localizedCaseInsensitiveContains(monitoredApp) ||
               monitoredApp.localizedCaseInsensitiveContains(appName) {
                logger.info("Monitored app terminated: \(appName)")

                // If recording, stop it
                if case .recording = currentState {
                    try? await requestStopRecording()
                }

                await stopAudioMonitoring()
                await updateState(.idle)
            }
        case .idle:
            break
        }
    }

    private func startAppCheckLoop() {
        appCheckTask = Task {
            while !Task.isCancelled && isRunning {
                await checkForActiveMeetingApps()
                try? await Task.sleep(nanoseconds: 5_000_000_000) // Check every 5 seconds
            }
        }
    }

    private func checkForActiveMeetingApps() async {
        guard case .idle = currentState else { return }

        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            guard let appName = app.localizedName else { continue }

            if isMonitoredApp(appName: appName, bundleId: app.bundleIdentifier) {
                logger.info("Found running monitored app: \(appName)")
                await startMonitoringApp(appName)
                break
            }
        }
    }

    private func isMonitoredApp(appName: String, bundleId: String?) -> Bool {
        // Check against enabled apps
        for meetingApp in Self.supportedApps {
            guard configuration.enabledApps.contains(meetingApp.id) else { continue }

            // Check bundle ID match
            if let bundleId = bundleId, !meetingApp.bundleId.isEmpty {
                if bundleId == meetingApp.bundleId {
                    return true
                }
            }

            // Check name match (case-insensitive)
            if appName.localizedCaseInsensitiveContains(meetingApp.processName) ||
               appName.localizedCaseInsensitiveContains(meetingApp.displayName) {
                return true
            }
        }

        // Check if it's a browser (for Google Meet detection)
        if configuration.enabledApps.contains("meet") {
            if configuration.browserApps.contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
                // Browser is running - we'll monitor it for audio
                // Note: We can't easily detect if Google Meet is open without accessibility APIs
                return true
            }
        }

        return false
    }

    private func startMonitoringApp(_ appName: String) async {
        guard case .idle = currentState else { return }

        logger.info("Starting to monitor app: \(appName)")
        await updateState(.monitoring(app: appName))

        // Start audio level monitoring
        do {
            try await audioLevelMonitor?.startMonitoring(for: appName)
            startAudioStateMonitoring()
        } catch {
            logger.error("Failed to start audio monitoring: \(error.localizedDescription)")
            await notifyError(error)
            await updateState(.idle)
        }
    }

    private func stopAudioMonitoring() async {
        audioMonitorTask?.cancel()
        audioMonitorTask = nil
        await audioLevelMonitor?.stopMonitoring()
    }

    private func startAudioStateMonitoring() {
        audioMonitorTask = Task {
            guard let monitor = audioLevelMonitor else { return }

            for await state in await monitor.stateStream() {
                guard !Task.isCancelled else { break }
                await handleAudioStateChange(state)
            }
        }
    }

    private func handleAudioStateChange(_ audioState: AudioLevelMonitor.MonitoringState) async {
        switch (currentState, audioState) {
        case (.monitoring(let app), .audioDetected):
            // Sustained audio detected - meeting in progress
            logger.info("Meeting detected for: \(app)")
            await updateState(.meetingDetected(app: app))

            // Start recording
            do {
                try await requestStartRecording(for: app)
                await updateState(.recording(app: app))
            } catch {
                logger.error("Failed to start recording: \(error.localizedDescription)")
                await notifyError(error)
            }

        case (.recording(let app), .silence):
            // Sustained silence - meeting may be ending
            logger.info("Silence detected during recording for: \(app)")
            await updateState(.endingMeeting(app: app))

            // Wait for confirmation (audio might resume)
            // The audio monitor already handles the sustained silence duration
            do {
                try await requestStopRecording()
                await stopAudioMonitoring()
                await updateState(.idle)

                // Check if app is still running, restart monitoring if so
                if isAppStillRunning(app) {
                    await startMonitoringApp(app)
                }
            } catch {
                logger.error("Failed to stop recording: \(error.localizedDescription)")
                await notifyError(error)
            }

        case (.endingMeeting(let app), .audioDetected):
            // Audio resumed - continue recording
            logger.info("Audio resumed for: \(app)")
            await updateState(.recording(app: app))

        default:
            break
        }
    }

    private func isAppStillRunning(_ appName: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let name = app.localizedName else { return false }
            return name.localizedCaseInsensitiveContains(appName) ||
                   appName.localizedCaseInsensitiveContains(name)
        }
    }

    private func requestStartRecording(for appName: String) async throws {
        guard let callback = startRecordingCallback else { return }

        // Call the MainActor callback directly (it's already marked @MainActor)
        currentRecordingURL = try await callback(self, appName)
        logger.info("Recording started: \(self.currentRecordingURL?.lastPathComponent ?? "unknown")")
    }

    private func requestStopRecording() async throws {
        guard let callback = stopRecordingCallback else { return }

        // Call the MainActor callback directly (it's already marked @MainActor)
        try await callback(self)
        currentRecordingURL = nil
        logger.info("Recording stopped")
    }

    private func updateState(_ newState: State) async {
        guard currentState != newState else { return }

        let oldState = currentState
        currentState = newState

        logger.info("State changed: \(String(describing: oldState)) -> \(String(describing: newState))")

        // Notify delegate
        if let callback = delegateCallback {
            await MainActor.run {
                callback(self, newState)
            }
        }
    }

    private func notifyError(_ error: Error) async {
        if let callback = errorCallback {
            await MainActor.run {
                callback(self, error)
            }
        }
    }
}
