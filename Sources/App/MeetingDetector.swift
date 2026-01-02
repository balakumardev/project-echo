import Foundation
import AppKit
import AudioEngine
import os.log

// Debug file logging (disabled in release builds)
#if DEBUG
func debugLog(_ message: String) {
    let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projectecho_debug.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}
#else
@inline(__always) func debugLog(_ message: String) {}
#endif

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

        // Window title detection settings
        public var enableWindowTitleDetection: Bool = true
        public var windowTitlePollingInterval: TimeInterval = 1.0

        // Microphone detection settings
        public var enableMicrophoneDetection: Bool = true
        public var microphonePollingInterval: TimeInterval = 1.0

        public init(
            sustainedAudioDuration: TimeInterval = 2.0,
            silenceDurationToEnd: TimeInterval = 45.0,
            silenceThresholdDB: Float = -40.0,
            audioThresholdDB: Float = -35.0,
            enabledApps: Set<String> = ["zoom", "teams", "meet", "slack", "discord"],
            checkOnWake: Bool = true,
            enableWindowTitleDetection: Bool = true,
            windowTitlePollingInterval: TimeInterval = 1.0,
            enableMicrophoneDetection: Bool = true,
            microphonePollingInterval: TimeInterval = 1.0
        ) {
            self.sustainedAudioDuration = sustainedAudioDuration
            self.silenceDurationToEnd = silenceDurationToEnd
            self.silenceThresholdDB = silenceThresholdDB
            self.audioThresholdDB = audioThresholdDB
            self.enabledApps = enabledApps
            self.checkOnWake = checkOnWake
            self.enableWindowTitleDetection = enableWindowTitleDetection
            self.windowTitlePollingInterval = windowTitlePollingInterval
            self.enableMicrophoneDetection = enableMicrophoneDetection
            self.microphonePollingInterval = microphonePollingInterval
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

    /// Browser bundle ID prefixes that might be used for web-based meetings
    /// Note: Browsers spawn helper processes with different bundle IDs (e.g., com.google.Chrome.helper)
    /// so we check for prefix matches, not exact matches
    public static let browserBundleIDPrefixes: [String] = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.apple.WebKit",        // Safari uses WebKit processes
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi"
    ]

    /// Check if a bundle ID belongs to a known browser (including helper processes)
    public static func isBrowserBundleID(_ bundleID: String) -> Bool {
        return browserBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Get the main browser bundle ID from a helper process bundle ID
    /// e.g., "com.microsoft.edgemac.helper" -> "com.microsoft.edgemac"
    public static func getMainBrowserBundleID(_ bundleID: String) -> String {
        for prefix in browserBundleIDPrefixes {
            if bundleID.hasPrefix(prefix) {
                return prefix
            }
        }
        return bundleID
    }

    /// All meeting app bundle IDs for quick lookup
    public static let meetingAppBundleIDs: Set<String> = Set(
        supportedApps.compactMap { $0.bundleId.isEmpty ? nil : $0.bundleId }
    )

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.projectecho.app", category: "MeetingDetector")

    private var configuration: Configuration
    private var currentState: State = .idle
    private var isRunning = false

    // Components
    private var audioLevelMonitor: AudioLevelMonitor?
    private var windowTitleMonitor: WindowTitleMonitor?
    private var detectionCoordinator: DetectionCoordinator?
    private var mediaDeviceMonitor: MediaDeviceMonitor?
    private var appObservers: [NSObjectProtocol] = []

    // State tracking
    private var currentRecordingURL: URL?
    private var audioMonitorTask: Task<Void, Never>?
    private var windowMonitorTask: Task<Void, Never>?
    private var mediaDeviceMonitorTask: Task<Void, Never>?
    private var appCheckTask: Task<Void, Never>?
    private var currentDetectionSource: DetectionSource?
    private var runningMeetingApps: Set<String> = []  // Track ALL running meeting apps
    private var currentMeetingTitle: String?  // The detected meeting title from window
    private var currentRecordingBundleID: String?  // Bundle ID for screen recording

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
        self.detectionCoordinator = DetectionCoordinator()
        // Window title monitor will be initialized in start() after checking accessibility
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
            debugLog("MeetingDetector already running")
            return
        }

        debugLog("Starting MeetingDetector with config: enabledApps=\(configuration.enabledApps), windowTitleDetection=\(configuration.enableWindowTitleDetection)")
        isRunning = true

        // Setup window title monitor if enabled and accessibility is trusted
        if configuration.enableWindowTitleDetection {
            let isTrusted = await MainActor.run { WindowTitleMonitor.isAccessibilityTrusted(prompt: false) }
            debugLog("Accessibility trusted: \(isTrusted)")
            if isTrusted {
                windowTitleMonitor = WindowTitleMonitor(configuration: WindowTitleMonitor.Configuration(
                    pollingInterval: configuration.windowTitlePollingInterval
                ))
                debugLog("Window title monitor initialized")
            } else {
                debugLog("Window title detection disabled - accessibility not trusted")
            }
        }

        // Setup microphone usage monitor if enabled
        if configuration.enableMicrophoneDetection {
            mediaDeviceMonitor = MediaDeviceMonitor(configuration: MediaDeviceMonitor.Configuration(
                pollingInterval: configuration.microphonePollingInterval
            ))
            debugLog("Microphone usage monitor initialized")
        }

        // Setup app activation observers
        await setupAppObservers()
        debugLog("App observers set up")

        // Start periodic check for running meeting apps
        startAppCheckLoop()
        debugLog("App check loop started")

        debugLog("MeetingDetector started successfully")
    }

    /// Stop the detector
    public func stop() async {
        guard isRunning else { return }

        logger.info("Stopping MeetingDetector")
        isRunning = false

        // Stop audio monitoring
        await stopAudioMonitoring()

        // Stop window title monitoring
        await stopWindowTitleMonitoring()

        // Stop microphone monitoring
        await stopMicrophoneMonitoring()

        // Cancel tasks
        audioMonitorTask?.cancel()
        audioMonitorTask = nil
        windowMonitorTask?.cancel()
        windowMonitorTask = nil
        mediaDeviceMonitorTask?.cancel()
        mediaDeviceMonitorTask = nil
        appCheckTask?.cancel()
        appCheckTask = nil

        // Reset detection coordinator
        await detectionCoordinator?.reset()
        currentDetectionSource = nil
        currentRecordingBundleID = nil

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

        // Update window title monitor configuration
        await windowTitleMonitor?.updateConfiguration(WindowTitleMonitor.Configuration(
            pollingInterval: newConfig.windowTitlePollingInterval
        ))

        // Handle window title detection enable/disable
        if newConfig.enableWindowTitleDetection && windowTitleMonitor == nil {
            let isTrusted = await MainActor.run { WindowTitleMonitor.isAccessibilityTrusted(prompt: false) }
            if isTrusted {
                windowTitleMonitor = WindowTitleMonitor(configuration: WindowTitleMonitor.Configuration(
                    pollingInterval: newConfig.windowTitlePollingInterval
                ))
                logger.info("Window title detection enabled")
            }
        } else if !newConfig.enableWindowTitleDetection && windowTitleMonitor != nil {
            await stopWindowTitleMonitoring()
            windowTitleMonitor = nil
            logger.info("Window title detection disabled")
        }
    }

    /// Get current state
    public func getState() -> State {
        return currentState
    }

    /// Get list of enabled meeting apps
    public func getEnabledApps() -> [MeetingApp] {
        return Self.supportedApps.filter { configuration.enabledApps.contains($0.id) }
    }

    /// Get the bundle ID detected for the current recording (used for screen recording)
    public func getCurrentRecordingBundleID() -> String? {
        return currentRecordingBundleID
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
        // Check if this is a monitored app - trigger a full check to update running apps set
        if isMonitoredApp(appName: appName, bundleId: bundleId) {
            debugLog("Monitored app activated: \(appName)")
            await checkForActiveMeetingApps()
        }
    }

    private func handleAppTermination(appName: String, bundleId: String?) async {
        // Check if this was a monitored app - trigger a full check to update running apps set
        if isMonitoredApp(appName: appName, bundleId: bundleId) {
            debugLog("Monitored app terminated: \(appName)")
            await checkForActiveMeetingApps()
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
        let runningApps = NSWorkspace.shared.runningApplications

        // Collect running meeting apps by their clean display name (e.g., "Zoom" not "zoom.us Web Content")
        var foundAppIds: Set<String> = []
        for app in runningApps {
            guard let appName = app.localizedName, let bundleId = app.bundleIdentifier else { continue }

            // Skip browsers - we'll handle Google Meet separately
            if configuration.browserApps.contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
                continue
            }

            // Find which meeting app this matches and use its ID
            if let matchedApp = getMatchingMeetingApp(appName: appName, bundleId: bundleId) {
                foundAppIds.insert(matchedApp.id)
            }
        }

        // Convert IDs to display names for the running apps set
        var foundApps: Set<String> = []
        for appId in foundAppIds {
            if let meetingApp = Self.supportedApps.first(where: { $0.id == appId }) {
                foundApps.insert(meetingApp.displayName)
            }
        }

        // Check if running apps changed
        let previousApps = runningMeetingApps
        runningMeetingApps = foundApps

        debugLog("checkForActiveMeetingApps: found \(foundApps.count) meeting apps: \(foundApps), previous: \(previousApps)")

        // If we found meeting apps and weren't monitoring before, start monitoring
        if !foundApps.isEmpty, case .idle = currentState {
            let appList = foundApps.sorted().joined(separator: ", ")
            debugLog("Starting to monitor apps: \(appList)")
            await startMonitoringSystemAudio(for: appList)
        }

        // If Zoom was newly detected while already monitoring, start window title monitoring
        // This handles the case where Slack starts first, then Zoom opens later
        let zoomWasAdded = foundApps.contains(where: { isZoomApp($0) }) &&
                          !previousApps.contains(where: { isZoomApp($0) })
        if zoomWasAdded && windowMonitorTask == nil {
            debugLog("Zoom newly detected while monitoring, starting window title monitoring...")
            await startWindowTitleMonitoring(for: "zoom.us")
        }

        // If all meeting apps closed while we were monitoring/recording
        if foundApps.isEmpty && !previousApps.isEmpty {
            debugLog("All meeting apps closed")
            if case .recording = currentState {
                try? await requestStopRecording()
            }
            await stopAudioMonitoring()
            await stopWindowTitleMonitoring()
            await stopMicrophoneMonitoring()
            await detectionCoordinator?.reset()
            currentDetectionSource = nil
            currentRecordingBundleID = nil
            await updateState(.idle)
        }
    }

    /// Find the matching MeetingApp for a given app name and bundle ID
    private func getMatchingMeetingApp(appName: String, bundleId: String?) -> MeetingApp? {
        for meetingApp in Self.supportedApps {
            guard configuration.enabledApps.contains(meetingApp.id) else { continue }

            // Check bundle ID match (most reliable)
            if let bundleId = bundleId, !meetingApp.bundleId.isEmpty {
                // For Zoom, match any bundle that starts with "us.zoom"
                if meetingApp.id == "zoom" && bundleId.hasPrefix("us.zoom") {
                    return meetingApp
                }
                if bundleId == meetingApp.bundleId {
                    return meetingApp
                }
            }

            // Check name match for non-Zoom apps
            if meetingApp.id != "zoom" {
                if appName.localizedCaseInsensitiveContains(meetingApp.processName) ||
                   appName.localizedCaseInsensitiveContains(meetingApp.displayName) {
                    return meetingApp
                }
            }
        }
        return nil
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

    /// Start monitoring system audio for all meeting apps
    private func startMonitoringSystemAudio(for appNames: String) async {
        guard case .idle = currentState else {
            debugLog("startMonitoringSystemAudio: not idle, skipping")
            return
        }

        debugLog("Starting system audio monitoring for: \(appNames)")
        await updateState(.monitoring(app: appNames))

        // Reset detection coordinator for new monitoring session
        await detectionCoordinator?.reset()
        currentDetectionSource = nil

        // Start window title monitoring FIRST if Zoom is running
        // This works independently of audio monitoring
        if runningMeetingApps.contains(where: { isZoomApp($0) }) {
            debugLog("Zoom is running, starting window title monitoring...")
            await startWindowTitleMonitoring(for: "zoom.us")
        }

        // Start microphone usage monitoring (works for all apps including browsers)
        if configuration.enableMicrophoneDetection {
            await startMicrophoneMonitoring()
        }

        // Start system-wide audio level monitoring
        do {
            debugLog("Starting system audio monitoring...")
            try await audioLevelMonitor?.startMonitoringSystemAudio()
            debugLog("System audio monitoring started successfully")
            startAudioStateMonitoring()
        } catch {
            debugLog("ERROR: Failed to start system audio monitoring: \(error)")
            await notifyError(error)
            // Don't return - window title monitoring can still work
            // Only reset to idle if window title monitoring also isn't running
            if windowMonitorTask == nil {
                await updateState(.idle)
            }
        }
    }

    /// Legacy method for single-app monitoring (kept for compatibility)
    private func startMonitoringApp(_ appName: String) async {
        await startMonitoringSystemAudio(for: appName)
    }

    /// Check if the app is Zoom (supports window title detection)
    private func isZoomApp(_ appName: String) -> Bool {
        let zoomApp = Self.supportedApps.first { $0.id == "zoom" }
        guard let zoom = zoomApp else { return false }
        return appName.localizedCaseInsensitiveContains(zoom.displayName) ||
               appName.localizedCaseInsensitiveContains(zoom.processName)
    }

    private func stopAudioMonitoring() async {
        audioMonitorTask?.cancel()
        audioMonitorTask = nil
        await audioLevelMonitor?.stopMonitoring()
    }

    private func stopWindowTitleMonitoring() async {
        windowMonitorTask?.cancel()
        windowMonitorTask = nil
        await windowTitleMonitor?.stopMonitoring()
    }

    // MARK: - Microphone Monitoring

    private func startMicrophoneMonitoring() async {
        guard let monitor = mediaDeviceMonitor else { return }

        debugLog("Starting microphone usage monitoring...")
        logger.info("Starting microphone usage monitoring")

        await monitor.startMonitoring()
        startMicrophoneEventMonitoring()
    }

    private func stopMicrophoneMonitoring() async {
        mediaDeviceMonitorTask?.cancel()
        mediaDeviceMonitorTask = nil
        await mediaDeviceMonitor?.stopMonitoring()
    }

    private func startMicrophoneEventMonitoring() {
        mediaDeviceMonitorTask = Task {
            guard let monitor = mediaDeviceMonitor else { return }

            for await event in await monitor.eventStream() {
                guard !Task.isCancelled else { break }
                await handleMicrophoneEvent(event)
            }
        }
    }

    private func handleMicrophoneEvent(_ event: MediaDeviceMonitor.MicrophoneEvent) async {
        switch event {
        case .microphoneActivated(let usage):
            await handleMicrophoneActivated(usage)

        case .microphoneDeactivated(let usage):
            await handleMicrophoneDeactivated(usage)

        case .noChange:
            break
        }
    }

    private func handleMicrophoneActivated(_ usage: MediaDeviceMonitor.MicrophoneUsage) async {
        guard let bundleID = usage.bundleID else {
            debugLog("Mic activated but no bundle ID available")
            return
        }

        debugLog("handleMicrophoneActivated: bundleID=\(bundleID), app=\(usage.appName ?? "unknown")")

        // Check if this is a meeting app or browser (including helper processes)
        let isMeetingApp = Self.meetingAppBundleIDs.contains(bundleID)
        let isBrowser = Self.isBrowserBundleID(bundleID)

        guard isMeetingApp || isBrowser else {
            debugLog("Ignoring mic activation from non-meeting app: \(bundleID)")
            return
        }

        // For browsers, get the main bundle ID (not the helper process)
        let recordingBundleID = isBrowser ? Self.getMainBrowserBundleID(bundleID) : bundleID
        let appDescription = isBrowser ? "browser (\(usage.appName ?? bundleID))" : (usage.appName ?? bundleID)
        debugLog("MEETING APP/BROWSER using microphone: \(appDescription), recordingBundleID=\(recordingBundleID)")
        logger.info("Meeting-related app using microphone: \(appDescription)")

        // Register detection with coordinator
        let event = DetectionCoordinator.DetectionEvent(
            source: .microphoneActive,
            appName: usage.appName ?? bundleID,
            metadata: ["bundleID": recordingBundleID, "type": isBrowser ? "browser" : "native"]
        )

        guard let coordinator = detectionCoordinator else { return }
        let shouldTrigger = await coordinator.registerDetection(event)

        // If this should trigger recording, start it
        if shouldTrigger {
            switch currentState {
            case .idle:
                // Shouldn't happen - we should be in monitoring state
                break

            case .monitoring:
                // Trigger recording for this specific app (use main bundle ID for browsers)
                debugLog("Triggering recording for: \(recordingBundleID)")
                await triggerMeetingDetection(source: .microphoneActive, app: usage.appName ?? recordingBundleID, bundleID: recordingBundleID)

            case .meetingDetected, .recording, .endingMeeting:
                // Already handling a meeting
                break
            }
        }
    }

    private func handleMicrophoneDeactivated(_ usage: MediaDeviceMonitor.MicrophoneUsage) async {
        guard let bundleID = usage.bundleID else { return }

        debugLog("handleMicrophoneDeactivated: bundleID=\(bundleID)")

        // Only care if it was a meeting app or browser (including helper processes)
        let isMeetingApp = Self.meetingAppBundleIDs.contains(bundleID)
        let isBrowser = Self.isBrowserBundleID(bundleID)

        guard isMeetingApp || isBrowser else { return }

        logger.info("Meeting-related app stopped using microphone: \(bundleID)")
        await detectionCoordinator?.removeDetection(source: .microphoneActive)

        // Check if we should stop recording
        if await detectionCoordinator?.hasActiveDetection() == false {
            switch currentState {
            case .recording(let app):
                debugLog("No active detection sources, ending meeting for: \(app)")
                await updateState(.endingMeeting(app: app))
                await handleAllDetectionsEnded()
            default:
                break
            }
        }
    }

    /// Trigger meeting detection with specific bundle ID for screen recording
    private func triggerMeetingDetection(source: DetectionSource, app: String, bundleID: String) async {
        debugLog("triggerMeetingDetection: source=\(source), app=\(app), bundleID=\(bundleID)")

        // Store the bundle ID for screen recording
        currentRecordingBundleID = bundleID
        currentMeetingTitle = app  // Use app name as meeting title for filename

        await updateState(.meetingDetected(app: app))
        currentDetectionSource = source

        // Request recording start with the specific bundle ID
        do {
            try await requestStartRecording(for: app)
            await updateState(.recording(app: app))
            debugLog("Recording started successfully for \(app) (\(bundleID))")
        } catch {
            debugLog("ERROR: Failed to start recording: \(error)")
            await notifyError(error)
            await updateState(.monitoring(app: app))
        }
    }

    private func startWindowTitleMonitoring(for appName: String) async {
        guard let monitor = windowTitleMonitor else { return }

        do {
            // Get Zoom bundle ID
            let zoomBundleId = Self.supportedApps.first { $0.id == "zoom" }?.bundleId ?? "us.zoom.xos"
            try await monitor.startMonitoring(for: zoomBundleId)
            startWindowTitleStateMonitoring()
            logger.info("Window title monitoring started for Zoom")
        } catch {
            logger.error("Failed to start window title monitoring: \(error.localizedDescription)")
            // Continue without window title monitoring - audio detection will still work
        }
    }

    private func startWindowTitleStateMonitoring() {
        windowMonitorTask = Task {
            guard let monitor = windowTitleMonitor else { return }

            for await state in await monitor.stateStream() {
                guard !Task.isCancelled else { break }
                await handleWindowTitleStateChange(state)
            }
        }
    }

    private func handleWindowTitleStateChange(_ windowState: WindowTitleMonitor.MonitoringState) async {
        debugLog("handleWindowTitleStateChange: \(windowState), currentState=\(currentState)")

        switch windowState {
        case .meetingDetected(let app, let title):
            debugLog("Window title detected meeting: \(title)")
            logger.info("Window title detected meeting: \(title)")

            // Store the meeting title for use in recording name
            currentMeetingTitle = title

            // Register with coordinator
            let event = DetectionCoordinator.DetectionEvent(
                source: .windowTitle,
                appName: app,
                metadata: ["title": title]
            )

            guard let coordinator = detectionCoordinator else { return }
            let shouldTrigger = await coordinator.registerDetection(event)

            // If this is the first detection source and we're in monitoring state, start recording
            if shouldTrigger {
                switch currentState {
                case .monitoring:
                    // Use the meeting title as the recording name
                    await triggerMeetingDetection(source: .windowTitle, app: title)
                case .idle, .meetingDetected, .recording, .endingMeeting:
                    break
                }
            }

        case .meetingEnded:
            logger.info("Window title indicates meeting ended")
            currentMeetingTitle = nil
            await detectionCoordinator?.removeDetection(source: .windowTitle)

            // Only stop recording if no other detection sources are active
            if await detectionCoordinator?.hasActiveDetection() == false {
                await handleAllDetectionsEnded()
            }

        case .idle, .monitoring:
            break
        }
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
        debugLog("handleAudioStateChange: audioState=\(audioState), currentState=\(currentState)")

        switch (currentState, audioState) {
        case (.monitoring(let app), .audioDetected):
            // Sustained audio detected - register with coordinator
            debugLog("AUDIO DETECTED! Starting recording for: \(app)")

            let event = DetectionCoordinator.DetectionEvent(
                source: .audio,
                appName: app
            )

            guard let coordinator = detectionCoordinator else {
                // Fallback to direct trigger if no coordinator
                let recordingName = currentMeetingTitle ?? runningMeetingApps.first ?? app
                await triggerMeetingDetection(source: .audio, app: recordingName)
                return
            }

            let shouldTrigger = await coordinator.registerDetection(event)

            // If this is the first detection source, start recording
            if shouldTrigger {
                // Use meeting title if available, otherwise use first running app name
                let recordingName = currentMeetingTitle ?? runningMeetingApps.first ?? app
                await triggerMeetingDetection(source: .audio, app: recordingName)
            }

        case (.recording(let app), .silence):
            // Sustained silence - remove audio detection
            logger.info("Silence detected during recording for: \(app)")
            await detectionCoordinator?.removeDetection(source: .audio)

            // Only end meeting if no other detection sources are active
            if await detectionCoordinator?.hasActiveDetection() == false {
                await updateState(.endingMeeting(app: app))
                await handleAllDetectionsEnded()
            } else {
                logger.info("Audio silent but other detection source still active, continuing recording")
            }

        case (.endingMeeting(let app), .audioDetected):
            // Audio resumed - re-register and continue recording
            logger.info("Audio resumed for: \(app)")

            let event = DetectionCoordinator.DetectionEvent(
                source: .audio,
                appName: app
            )
            _ = await detectionCoordinator?.registerDetection(event)

            await updateState(.recording(app: app))

        default:
            break
        }
    }

    /// Unified method for triggering meeting detection from any source
    private func triggerMeetingDetection(source: DetectionSource, app: String) async {
        currentDetectionSource = source
        logger.info("Meeting detection triggered via \(source.displayName) for: \(app)")
        await updateState(.meetingDetected(app: app))

        // Start recording
        do {
            try await requestStartRecording(for: app)
            await updateState(.recording(app: app))
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            await notifyError(error)
        }
    }

    /// Handle when all detection sources indicate meeting has ended
    private func handleAllDetectionsEnded() async {
        guard case .recording(let app) = currentState else {
            if case .endingMeeting(let app) = currentState {
                // Already in ending state, proceed
                do {
                    try await requestStopRecording()
                    await stopAudioMonitoring()
                    await stopWindowTitleMonitoring()
                    await stopMicrophoneMonitoring()
                    await detectionCoordinator?.reset()
                    currentDetectionSource = nil
                    currentRecordingBundleID = nil
                    await updateState(.idle)

                    // Check if app is still running, restart monitoring if so
                    if isAppStillRunning(app) {
                        await startMonitoringApp(app)
                    }
                } catch {
                    logger.error("Failed to stop recording: \(error.localizedDescription)")
                    await notifyError(error)
                }
            }
            return
        }

        // Transition to ending state
        await updateState(.endingMeeting(app: app))

        do {
            try await requestStopRecording()
            await stopAudioMonitoring()
            await stopWindowTitleMonitoring()
            await stopMicrophoneMonitoring()
            await detectionCoordinator?.reset()
            currentDetectionSource = nil
            currentRecordingBundleID = nil
            await updateState(.idle)

            // Check if app is still running, restart monitoring if so
            if isAppStillRunning(app) {
                await startMonitoringApp(app)
            }
        } catch {
            logger.error("Failed to stop recording: \(error.localizedDescription)")
            await notifyError(error)
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
