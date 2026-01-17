import Foundation
import AppKit
import AudioEngine
import os.log
import UI

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

/// Orchestrates app monitoring and microphone detection to automatically record meetings
@available(macOS 14.0, *)
public actor MeetingDetector {

    // MARK: - Types

    public enum State: Sendable, Equatable {
        case idle
        case monitoring(app: String)      // Monitored app is active, waiting for mic
        case meetingDetected(app: String) // Mic detected, about to start recording
        case recording(app: String)       // Actively recording
        case endingMeeting(app: String)   // Mic deactivated, stopping recording
    }

    public struct Configuration: Sendable {
        public var enabledApps: Set<String> = ["zoom", "teams", "meet", "slack", "discord"]
        public var browserApps: Set<String> = ["Google Chrome", "Safari", "Microsoft Edge", "Firefox", "Arc"]
        public var checkOnWake: Bool = true
        public var microphonePollingInterval: TimeInterval = 1.0
        /// Grace period (in seconds) before ending recording when mic is deactivated.
        /// Apps like Zoom may briefly release/reacquire the mic during normal operation.
        public var micDeactivationGracePeriod: TimeInterval = 8.0

        public init(
            enabledApps: Set<String> = ["zoom", "teams", "meet", "slack", "discord"],
            checkOnWake: Bool = true,
            microphonePollingInterval: TimeInterval = 1.0,
            micDeactivationGracePeriod: TimeInterval = 8.0
        ) {
            self.enabledApps = enabledApps
            self.checkOnWake = checkOnWake
            self.microphonePollingInterval = microphonePollingInterval
            self.micDeactivationGracePeriod = micDeactivationGracePeriod
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
    public static let browserBundleIDPrefixes: [String] = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.apple.WebKit",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi"
    ]

    /// Check if a bundle ID belongs to a known browser (including helper processes)
    public static func isBrowserBundleID(_ bundleID: String) -> Bool {
        return browserBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Get the main browser bundle ID from a helper process bundle ID
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

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "MeetingDetector")

    private var configuration: Configuration
    private var currentState: State = .idle
    private var isRunning = false

    // Components
    private var mediaDeviceMonitor: MediaDeviceMonitor?
    private var appObservers: [NSObjectProtocol] = []

    // State tracking
    private var currentRecordingURL: URL?
    private var mediaDeviceMonitorTask: Task<Void, Never>?
    private var appCheckTask: Task<Void, Never>?
    private var runningMeetingApps: Set<String> = []
    private var currentRecordingBundleID: String?

    // Delegate callbacks
    private var delegateCallback: (@MainActor (MeetingDetector, State) -> Void)?
    private var startRecordingCallback: (@MainActor (MeetingDetector, String) async throws -> URL)?
    private var stopRecordingCallback: (@MainActor (MeetingDetector) async throws -> Void)?
    private var errorCallback: (@MainActor (MeetingDetector, Error) -> Void)?

    // Grace period handling for mic deactivation
    private var micDeactivationGraceTask: Task<Void, Never>?
    private var pendingDeactivationApp: String?

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
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
            FileLogger.shared.debug("MeetingDetector already running")
            return
        }

        FileLogger.shared.debug("Starting MeetingDetector with config: enabledApps=\(configuration.enabledApps)")
        isRunning = true

        // Setup microphone usage monitor
        mediaDeviceMonitor = MediaDeviceMonitor(configuration: MediaDeviceMonitor.Configuration(
            pollingInterval: configuration.microphonePollingInterval
        ))
        FileLogger.shared.debug("Microphone usage monitor initialized")

        // Setup app activation observers
        await setupAppObservers()
        FileLogger.shared.debug("App observers set up")

        // Start periodic check for running meeting apps
        startAppCheckLoop()
        FileLogger.shared.debug("App check loop started")

        FileLogger.shared.debug("MeetingDetector started successfully")
    }

    /// Stop the detector
    public func stop() async {
        guard isRunning else { return }

        logger.info("Stopping MeetingDetector")
        isRunning = false

        // Stop microphone monitoring
        await stopMicrophoneMonitoring()

        // Cancel tasks
        mediaDeviceMonitorTask?.cancel()
        mediaDeviceMonitorTask = nil
        appCheckTask?.cancel()
        appCheckTask = nil

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
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Check for any running meeting apps
        await checkForActiveMeetingApps()
    }

    /// Handle system sleep event
    public func handleSystemSleep() async {
        logger.info("System sleeping")
    }

    /// Force start recording (manual override)
    public func forceStartRecording(for appName: String) async throws {
        guard isRunning else { return }
        try await requestStartRecording(for: appName)
    }

    /// Force stop recording (manual override)
    /// After stopping, returns to monitoring state if meeting apps are still running
    /// Note: This calls the delegate to stop recording
    public func forceStopRecording() async throws {
        guard isRunning else { return }

        FileLogger.shared.debug("forceStopRecording called (manual stop)")

        // Cancel any pending grace period
        cancelMicDeactivationGracePeriod()

        // Only stop if we're actually recording
        guard case .recording = currentState else {
            FileLogger.shared.debug("forceStopRecording: not in recording state, ignoring")
            return
        }

        // Stop the recording (this calls the delegate callback)
        try await requestStopRecording()

        // Reset state and return to monitoring
        await resetToMonitoringState()
    }

    /// Reset recording state without stopping (used when recording was already stopped externally)
    /// Call this after manually stopping recording to allow auto-detection to restart
    public func resetRecordingState() async {
        guard isRunning else { return }

        FileLogger.shared.debug("resetRecordingState called")

        // Cancel any pending grace period
        cancelMicDeactivationGracePeriod()

        // Clear recording URL (it's already stopped externally)
        currentRecordingURL = nil

        // Reset state and return to monitoring
        await resetToMonitoringState()
    }

    /// Internal helper to reset state back to monitoring mode
    private func resetToMonitoringState() async {
        currentRecordingBundleID = nil

        if !runningMeetingApps.isEmpty {
            let appList = runningMeetingApps.sorted().joined(separator: ", ")
            FileLogger.shared.debug("Returning to monitoring state for: \(appList)")
            await updateState(.monitoring(app: appList))
            // Note: We don't restart mic monitoring here - it should still be running
            // The next mic activation event will trigger a new recording
        } else {
            FileLogger.shared.debug("No meeting apps running, going to idle")
            await stopMicrophoneMonitoring()
            await updateState(.idle)
        }
    }

    /// Update configuration
    public func updateConfiguration(_ newConfig: Configuration) async {
        self.configuration = newConfig
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
        if isMonitoredApp(appName: appName, bundleId: bundleId) {
            FileLogger.shared.debug("Monitored app activated: \(appName)")
            await checkForActiveMeetingApps()
        }
    }

    private func handleAppTermination(appName: String, bundleId: String?) async {
        if isMonitoredApp(appName: appName, bundleId: bundleId) {
            FileLogger.shared.debug("Monitored app terminated: \(appName)")
            await checkForActiveMeetingApps()
        }
    }

    private func startAppCheckLoop() {
        appCheckTask = Task {
            while !Task.isCancelled && isRunning {
                await checkForActiveMeetingApps()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func checkForActiveMeetingApps() async {
        let runningApps = NSWorkspace.shared.runningApplications

        var foundAppIds: Set<String> = []
        var customAppDisplayNames: [String: String] = [:]  // bundleId -> displayName mapping

        for app in runningApps {
            guard let appName = app.localizedName, let bundleId = app.bundleIdentifier else { continue }

            // Skip browsers - we'll handle Google Meet separately
            if configuration.browserApps.contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
                continue
            }

            if let matchedApp = getMatchingMeetingApp(appName: appName, bundleId: bundleId) {
                foundAppIds.insert(matchedApp.id)
                // Track display name for custom apps (where id == bundleId)
                if matchedApp.id == bundleId {
                    customAppDisplayNames[bundleId] = matchedApp.displayName
                }
            }
        }

        var foundApps: Set<String> = []
        for appId in foundAppIds {
            if let meetingApp = Self.supportedApps.first(where: { $0.id == appId }) {
                // Default app
                foundApps.insert(meetingApp.displayName)
            } else if let displayName = customAppDisplayNames[appId] {
                // Custom app
                foundApps.insert(displayName)
            }
        }

        let previousApps = runningMeetingApps
        runningMeetingApps = foundApps

        FileLogger.shared.debug("checkForActiveMeetingApps: found \(foundApps.count) meeting apps: \(foundApps), previous: \(previousApps)")

        // If we found meeting apps and weren't monitoring before, start monitoring
        if !foundApps.isEmpty, case .idle = currentState {
            let appList = foundApps.sorted().joined(separator: ", ")
            FileLogger.shared.debug("Starting to monitor apps: \(appList)")
            await startMonitoring(for: appList)
        }

        // If all meeting apps closed while we were monitoring/recording
        if foundApps.isEmpty && !previousApps.isEmpty {
            FileLogger.shared.debug("All meeting apps closed")
            if case .recording = currentState {
                try? await requestStopRecording()
            }
            await stopMicrophoneMonitoring()
            currentRecordingBundleID = nil
            await updateState(.idle)
        }
    }

    private func getMatchingMeetingApp(appName: String, bundleId: String?) -> MeetingApp? {
        // Check default apps first
        for meetingApp in Self.supportedApps {
            guard configuration.enabledApps.contains(meetingApp.id) else { continue }

            if let bundleId = bundleId, !meetingApp.bundleId.isEmpty {
                if meetingApp.id == "zoom" && bundleId.hasPrefix("us.zoom") {
                    return meetingApp
                }
                if bundleId == meetingApp.bundleId {
                    return meetingApp
                }
            }

            if meetingApp.id != "zoom" {
                if appName.localizedCaseInsensitiveContains(meetingApp.processName) ||
                   appName.localizedCaseInsensitiveContains(meetingApp.displayName) {
                    return meetingApp
                }
            }
        }

        // Check custom apps (synchronous access for display name lookup)
        if let bundleId = bundleId, configuration.enabledApps.contains(bundleId) {
            // Create a MeetingApp struct for the custom app
            return MeetingApp(
                id: bundleId,
                displayName: appName,
                bundleId: bundleId,
                processName: appName,
                icon: "app.fill",
                browserBased: false
            )
        }

        return nil
    }

    private func isMonitoredApp(appName: String, bundleId: String?) -> Bool {
        // Check default apps
        for meetingApp in Self.supportedApps {
            guard configuration.enabledApps.contains(meetingApp.id) else { continue }

            if let bundleId = bundleId, !meetingApp.bundleId.isEmpty {
                if bundleId == meetingApp.bundleId {
                    return true
                }
            }

            if appName.localizedCaseInsensitiveContains(meetingApp.processName) ||
               appName.localizedCaseInsensitiveContains(meetingApp.displayName) {
                return true
            }
        }

        // Check custom apps
        if let bundleId = bundleId, configuration.enabledApps.contains(bundleId) {
            return true
        }

        // Check if it's a browser (for Google Meet detection)
        if configuration.enabledApps.contains("meet") {
            if configuration.browserApps.contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
                return true
            }
        }

        return false
    }

    private func startMonitoring(for appNames: String) async {
        guard case .idle = currentState else {
            FileLogger.shared.debug("startMonitoring: not idle, skipping")
            return
        }

        FileLogger.shared.debug("Starting monitoring for: \(appNames)")
        await updateState(.monitoring(app: appNames))

        // Start microphone usage monitoring
        await startMicrophoneMonitoring()
    }

    // MARK: - Microphone Monitoring

    private func startMicrophoneMonitoring() async {
        guard let monitor = mediaDeviceMonitor else { return }

        FileLogger.shared.debug("Starting microphone usage monitoring...")
        logger.info("Starting microphone usage monitoring")

        // IMPORTANT: Set up event listener BEFORE starting monitoring
        // to avoid race condition where first poll yields events before listener is ready
        startMicrophoneEventMonitoring()
        
        // Small delay to ensure the event stream is set up
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        await monitor.startMonitoring()
        
        // Check for any meeting apps already using the microphone
        await checkExistingMicUsers()
    }
    
    private func checkExistingMicUsers() async {
        guard let monitor = mediaDeviceMonitor else { return }
        
        let existingUsers = await monitor.getProcessesUsingMicrophone()
        FileLogger.shared.debug("Checking existing mic users: \(existingUsers.count) found")
        
        for usage in existingUsers {
            guard let bundleID = usage.bundleID else { continue }
            
            let isMeetingApp = Self.meetingAppBundleIDs.contains(bundleID)
            let isBrowser = Self.isBrowserBundleID(bundleID)
            let isCustomApp = await MainActor.run {
                CustomMeetingAppsManager.shared.isCustomApp(bundleId: bundleID) &&
                CustomMeetingAppsManager.shared.isEnabled(bundleId: bundleID)
            }
            
            if isMeetingApp || isBrowser || isCustomApp {
                FileLogger.shared.debug("Found existing mic user that is a meeting app: \(bundleID) (\(usage.appName ?? "unknown"))")
                
                // Check if we're in monitoring state and should start recording
                if case .monitoring = currentState {
                    let recordingBundleID = isBrowser ? Self.getMainBrowserBundleID(bundleID) : bundleID
                    FileLogger.shared.debug("Triggering recording for existing mic user: \(recordingBundleID)")
                    await triggerMeetingDetection(app: usage.appName ?? recordingBundleID, bundleID: recordingBundleID)
                    return // Only trigger for the first matching app
                }
            }
        }
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
            FileLogger.shared.debug("Mic activated but no bundle ID available")
            return
        }

        FileLogger.shared.debug("handleMicrophoneActivated: bundleID=\(bundleID), app=\(usage.appName ?? "unknown")")

        let isMeetingApp = Self.meetingAppBundleIDs.contains(bundleID)
        let isBrowser = Self.isBrowserBundleID(bundleID)

        // Check if it's a custom app (requires MainActor access)
        let isCustomApp = await MainActor.run {
            CustomMeetingAppsManager.shared.isCustomApp(bundleId: bundleID) &&
            CustomMeetingAppsManager.shared.isEnabled(bundleId: bundleID)
        }

        guard isMeetingApp || isBrowser || isCustomApp else {
            FileLogger.shared.debug("Ignoring mic activation from non-meeting app: \(bundleID)")
            return
        }

        let recordingBundleID = isBrowser ? Self.getMainBrowserBundleID(bundleID) : bundleID
        let appDescription = isBrowser ? "browser (\(usage.appName ?? bundleID))" : (usage.appName ?? bundleID)
        FileLogger.shared.debug("MEETING APP/BROWSER using microphone: \(appDescription), recordingBundleID=\(recordingBundleID)")
        logger.info("Meeting-related app using microphone: \(appDescription)")

        // Cancel any pending grace period - mic is back!
        cancelMicDeactivationGracePeriod()

        switch currentState {
        case .idle:
            break

        case .monitoring:
            FileLogger.shared.debug("Triggering recording for: \(recordingBundleID)")
            await triggerMeetingDetection(app: usage.appName ?? recordingBundleID, bundleID: recordingBundleID)

        case .meetingDetected, .recording:
            // Mic reactivated while recording - all good, continue recording
            FileLogger.shared.debug("Mic reactivated while in state \(currentState) - continuing")

        case .endingMeeting:
            // This shouldn't happen since we cancel grace period above,
            // but just in case, stay in current state
            break
        }
    }

    private func handleMicrophoneDeactivated(_ usage: MediaDeviceMonitor.MicrophoneUsage) async {
        guard let bundleID = usage.bundleID else { return }

        FileLogger.shared.debug("handleMicrophoneDeactivated: bundleID=\(bundleID)")

        let isMeetingApp = Self.meetingAppBundleIDs.contains(bundleID)
        let isBrowser = Self.isBrowserBundleID(bundleID)

        // Check if it's a custom app
        let isCustomApp = await MainActor.run {
            CustomMeetingAppsManager.shared.isCustomApp(bundleId: bundleID)
        }

        guard isMeetingApp || isBrowser || isCustomApp else { return }

        logger.info("Meeting-related app stopped using microphone: \(bundleID)")

        switch currentState {
        case .recording(let app):
            // Start grace period instead of immediately ending
            // This handles brief mic releases (mute toggle, audio device switch, etc.)
            FileLogger.shared.debug("Mic deactivated for \(app), starting \(configuration.micDeactivationGracePeriod)s grace period")
            await startMicDeactivationGracePeriod(for: app)
        default:
            break
        }
    }

    /// Start a grace period before ending the meeting.
    /// If the mic is reactivated within this period, recording continues uninterrupted.
    private func startMicDeactivationGracePeriod(for app: String) async {
        // Cancel any existing grace period
        micDeactivationGraceTask?.cancel()
        pendingDeactivationApp = app

        let gracePeriod = configuration.micDeactivationGracePeriod

        micDeactivationGraceTask = Task {
            FileLogger.shared.debug("Grace period started: waiting \(gracePeriod)s before ending meeting")

            do {
                // Wait for the grace period
                try await Task.sleep(nanoseconds: UInt64(gracePeriod * 1_000_000_000))

                // If we get here, grace period expired without mic reactivation
                guard !Task.isCancelled else {
                    FileLogger.shared.debug("Grace period was cancelled (mic reactivated)")
                    return
                }

                FileLogger.shared.debug("Grace period expired, ending meeting for: \(app)")
                await updateState(.endingMeeting(app: app))
                await handleMeetingEnded()
            } catch {
                // Task was cancelled (mic was reactivated)
                FileLogger.shared.debug("Grace period interrupted: \(error)")
            }

            pendingDeactivationApp = nil
        }
    }

    /// Cancel the grace period (called when mic is reactivated)
    private func cancelMicDeactivationGracePeriod() {
        if micDeactivationGraceTask != nil {
            FileLogger.shared.debug("Cancelling mic deactivation grace period - mic reactivated")
            micDeactivationGraceTask?.cancel()
            micDeactivationGraceTask = nil
            pendingDeactivationApp = nil
        }
    }

    private func triggerMeetingDetection(app: String, bundleID: String) async {
        FileLogger.shared.debug("triggerMeetingDetection: app=\(app), bundleID=\(bundleID)")

        currentRecordingBundleID = bundleID
        await updateState(.meetingDetected(app: app))

        do {
            try await requestStartRecording(for: app)
            await updateState(.recording(app: app))
            FileLogger.shared.debug("Recording started successfully for \(app) (\(bundleID))")
        } catch {
            FileLogger.shared.debug("ERROR: Failed to start recording: \(error)")
            await notifyError(error)
            await updateState(.monitoring(app: app))
        }
    }

    private func handleMeetingEnded() async {
        guard case .endingMeeting(let app) = currentState else { return }

        do {
            try await requestStopRecording()
            await stopMicrophoneMonitoring()
            currentRecordingBundleID = nil
            await updateState(.idle)

            // Check if app is still running, restart monitoring if so
            if !runningMeetingApps.isEmpty {
                let appList = runningMeetingApps.sorted().joined(separator: ", ")
                await startMonitoring(for: appList)
            }
        } catch {
            logger.error("Failed to stop recording: \(error.localizedDescription)")
            await notifyError(error)
        }
    }

    private func requestStartRecording(for appName: String) async throws {
        guard let callback = startRecordingCallback else { return }
        currentRecordingURL = try await callback(self, appName)
        logger.info("Recording started: \(self.currentRecordingURL?.lastPathComponent ?? "unknown")")
    }

    private func requestStopRecording() async throws {
        guard let callback = stopRecordingCallback else { return }
        try await callback(self)
        currentRecordingURL = nil
        logger.info("Recording stopped")
    }

    private func updateState(_ newState: State) async {
        guard currentState != newState else { return }

        let oldState = currentState
        currentState = newState

        logger.info("State changed: \(String(describing: oldState)) -> \(String(describing: newState))")

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
