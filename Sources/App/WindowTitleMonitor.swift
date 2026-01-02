import Foundation
import AppKit
import ApplicationServices
import os.log

// Debug logging for window title monitor (disabled in release builds)
#if DEBUG
private func windowTitleLog(_ message: String) {
    let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projectecho_debug.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [WindowTitle] \(message)\n"
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
@inline(__always) private func windowTitleLog(_ message: String) {}
#endif

/// Monitors Zoom window titles using Accessibility APIs to detect active meetings
@available(macOS 14.0, *)
public actor WindowTitleMonitor {

    // MARK: - Types

    public enum MonitoringState: Sendable, Equatable {
        case idle
        case monitoring(app: String)
        case meetingDetected(app: String, title: String)
        case meetingEnded
    }

    public struct WindowInfo: Sendable {
        public let title: String
        public let bundleId: String
        public let processId: pid_t
        public let timestamp: Date

        public init(title: String, bundleId: String, processId: pid_t) {
            self.title = title
            self.bundleId = bundleId
            self.processId = processId
            self.timestamp = Date()
        }
    }

    public struct Configuration: Sendable {
        public var pollingInterval: TimeInterval = 1.0
        public var zoomBundleId: String = "us.zoom.xos"

        // Patterns that indicate an active meeting (must contain one of these)
        public var meetingTitlePatterns: [String] = [
            "Zoom Meeting",
            "Meeting ID:",
            "Zoom Webinar",
            "Waiting Room"
        ]

        // Patterns that indicate lobby/no meeting (exclude these)
        public var lobbyTitlePatterns: [String] = [
            "Zoom Cloud Meetings",
            "Home - Zoom",
            "Zoom Workplace",
            "Settings",
            "Schedule Meeting",
            "Join Meeting",
            "Host a Meeting",
            "Sign In",
            "Sign Up"
        ]

        // If title ends with these patterns AND contains "Meeting" somewhere, it's a meeting
        // e.g., "Weekly Standup - Zoom" where the meeting name might not have "Meeting" in it
        public var meetingWindowSuffixes: [String] = [
            " - Zoom",
            " | Zoom"
        ]

        public init(
            pollingInterval: TimeInterval = 1.0,
            zoomBundleId: String = "us.zoom.xos"
        ) {
            self.pollingInterval = pollingInterval
            self.zoomBundleId = zoomBundleId
        }
    }

    public enum MonitorError: Error, LocalizedError {
        case accessibilityNotTrusted
        case processNotFound
        case windowNotAccessible
        case alreadyMonitoring

        public var errorDescription: String? {
            switch self {
            case .accessibilityNotTrusted:
                return "Accessibility permission is required for window title monitoring"
            case .processNotFound:
                return "Target application process not found"
            case .windowNotAccessible:
                return "Unable to access window information"
            case .alreadyMonitoring:
                return "Already monitoring window titles"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.projectecho.app", category: "WindowTitleMonitor")
    private var configuration: Configuration
    private var isMonitoring = false
    private var currentState: MonitoringState = .idle
    private var pollingTask: Task<Void, Never>?
    private var lastDetectedTitle: String?
    private var monitoredBundleId: String?

    private var stateContinuation: AsyncStream<MonitoringState>.Continuation?

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Static Methods

    /// Check if accessibility is trusted (required for AXUIElement APIs)
    @MainActor
    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        // Use the string value directly to avoid concurrency warnings with the C constant
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: prompt as CFBoolean] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Public API

    /// Start monitoring window titles for Zoom
    public func startMonitoring(for bundleId: String? = nil) async throws {
        let isTrusted = await MainActor.run { Self.isAccessibilityTrusted(prompt: false) }
        windowTitleLog("startMonitoring called, accessibility trusted: \(isTrusted)")
        guard isTrusted else {
            windowTitleLog("ERROR: Accessibility not trusted")
            throw MonitorError.accessibilityNotTrusted
        }

        guard !isMonitoring else {
            windowTitleLog("Already monitoring, skipping")
            throw MonitorError.alreadyMonitoring
        }

        let targetBundleId = bundleId ?? configuration.zoomBundleId
        monitoredBundleId = targetBundleId

        windowTitleLog("Starting window title monitoring for: \(targetBundleId)")
        logger.info("Starting window title monitoring for: \(targetBundleId)")
        isMonitoring = true
        currentState = .monitoring(app: targetBundleId)
        stateContinuation?.yield(currentState)

        startPolling(bundleId: targetBundleId)
    }

    /// Stop monitoring window titles
    public func stopMonitoring() async {
        guard isMonitoring else { return }

        logger.info("Stopping window title monitoring")

        pollingTask?.cancel()
        pollingTask = nil
        isMonitoring = false
        currentState = .idle
        lastDetectedTitle = nil
        monitoredBundleId = nil

        stateContinuation?.yield(.idle)

        // Finish continuation to release consumers
        stateContinuation?.finish()
        stateContinuation = nil
    }

    /// Get current monitoring state
    public func getState() -> MonitoringState {
        return currentState
    }

    /// Check if currently monitoring
    public func isCurrentlyMonitoring() -> Bool {
        return isMonitoring
    }

    /// Stream of state changes
    public func stateStream() -> AsyncStream<MonitoringState> {
        // Cancel any existing continuation before creating a new one
        stateContinuation?.finish()

        return AsyncStream { continuation in
            self.stateContinuation = continuation
            continuation.yield(currentState)

            // Capture the continuation we just set, so we only clear if it matches
            let capturedContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.clearStateContinuationIfMatches(capturedContinuation) }
            }
        }
    }

    private func clearStateContinuationIfMatches(_ continuation: AsyncStream<MonitoringState>.Continuation) {
        // Only clear if it's still the same continuation (prevents race condition)
        // We can't directly compare continuations, so we just don't clear on termination
        // The new stateStream() call will replace it anyway
    }

    /// Update configuration
    public func updateConfiguration(_ newConfig: Configuration) {
        self.configuration = newConfig
    }

    /// Get last detected window title
    public func getLastDetectedTitle() -> String? {
        return lastDetectedTitle
    }

    // MARK: - Private Methods


    private func startPolling(bundleId: String) {
        pollingTask = Task {
            while !Task.isCancelled && isMonitoring {
                await checkWindowTitle(bundleId: bundleId)
                try? await Task.sleep(nanoseconds: UInt64(configuration.pollingInterval * 1_000_000_000))
            }
        }
    }

    private func checkWindowTitle(bundleId: String) async {
        // Find the running Zoom app
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).first else {
            windowTitleLog("No app found with bundleId: \(bundleId)")
            // App not running - if we were in meeting, it ended
            if case .meetingDetected = currentState {
                await transitionToMeetingEnded()
            }
            return
        }

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Get windows
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            windowTitleLog("No windows accessible for \(bundleId), AX result: \(result.rawValue)")
            return
        }

        // Check all windows for meeting indicators
        // Zoom often has multiple windows; the meeting window may not be first
        var foundMeetingTitle: String?
        var allTitles: [String] = []

        for window in windows {
            var titleRef: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)

            guard titleResult == .success, let title = titleRef as? String, !title.isEmpty else {
                continue
            }

            allTitles.append(title)

            if isMeetingTitle(title) {
                foundMeetingTitle = title
                break
            }
        }

        windowTitleLog("Found \(windows.count) windows, titles: \(allTitles), meeting: \(foundMeetingTitle ?? "none")")
        await processWindowTitle(foundMeetingTitle, bundleId: bundleId)
    }

    private func processWindowTitle(_ title: String?, bundleId: String) async {
        let isMeetingActive = title != nil

        windowTitleLog("processWindowTitle: title=\(title ?? "nil"), currentState=\(currentState), isMeetingActive=\(isMeetingActive)")

        switch (currentState, isMeetingActive) {
        case (.monitoring, true):
            // Transition to meeting detected
            let meetingTitle = title!
            windowTitleLog("TRANSITIONING to meetingDetected: \(meetingTitle)")
            currentState = .meetingDetected(app: bundleId, title: meetingTitle)
            lastDetectedTitle = meetingTitle
            stateContinuation?.yield(currentState)
            windowTitleLog("Yielded meetingDetected state, continuation exists: \(stateContinuation != nil)")
            logger.info("Meeting detected via window title: \(meetingTitle)")

        case (.meetingDetected, false):
            // Meeting ended - window title no longer indicates meeting
            await transitionToMeetingEnded()

        case (.meetingDetected(let app, let oldTitle), true):
            // Still in meeting, check if title changed
            let newTitle = title!
            if oldTitle != newTitle {
                currentState = .meetingDetected(app: app, title: newTitle)
                lastDetectedTitle = newTitle
                stateContinuation?.yield(currentState)
                logger.debug("Meeting title changed: \(newTitle)")
            }

        default:
            break
        }
    }

    private func transitionToMeetingEnded() async {
        guard case .meetingDetected = currentState else { return }

        logger.info("Meeting ended (window title changed to lobby)")
        currentState = .meetingEnded
        stateContinuation?.yield(.meetingEnded)

        // Reset to monitoring state if still monitoring
        if isMonitoring, let bundleId = monitoredBundleId {
            currentState = .monitoring(app: bundleId)
            stateContinuation?.yield(currentState)
        }
    }

    /// Determine if a window title indicates an active meeting
    private func isMeetingTitle(_ title: String) -> Bool {
        // First, check if it matches any lobby patterns (not a meeting)
        for lobbyPattern in configuration.lobbyTitlePatterns {
            if title == lobbyPattern || title.localizedCaseInsensitiveContains(lobbyPattern) {
                return false
            }
        }

        // If title is just "Zoom" alone, it's the lobby
        if title == "Zoom" {
            return false
        }

        // Check if it matches explicit meeting patterns (highest confidence)
        for pattern in configuration.meetingTitlePatterns {
            if title.localizedCaseInsensitiveContains(pattern) {
                return true
            }
        }

        // Check for meeting window suffix patterns (e.g., "Weekly Standup - Zoom")
        // These indicate an active meeting window with the meeting name as prefix
        for suffix in configuration.meetingWindowSuffixes {
            if title.hasSuffix(suffix) || title.localizedCaseInsensitiveContains(suffix) {
                // Has a meeting suffix - this is likely an active meeting
                // The window title format is "[Meeting Name] - Zoom" or "[Meeting Name] | Zoom"
                return true
            }
        }

        return false
    }
}
