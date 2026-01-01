import Foundation
import AppKit
import os.log

/// Monitors running applications to trigger auto-recording
public actor AppMonitor {

    // MARK: - Types

    public enum AppEvent: Sendable {
        case launched(appName: String, bundleIdentifier: String?)
        case terminated(appName: String, bundleIdentifier: String?)
        case activated(appName: String, bundleIdentifier: String?)
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.projectecho.app", category: "AppMonitor")
    private var monitoredApps: Set<String> = []
    private var isMonitoring = false
    private var checkTimer: Task<Void, Never>?
    private var eventContinuation: AsyncStream<AppEvent>.Continuation?

    // Default apps to monitor
    public static let defaultMonitoredApps = [
        "zoom.us",
        "Microsoft Teams",
        "Google Meet",
        "Slack",
        "Discord",
        "Webex",
        "Skype"
    ]

    // MARK: - Initialization

    public init() {}

    // MARK: - Control

    /// Start monitoring for specific apps
    public func startMonitoring(apps: [String]) {
        self.monitoredApps = Set(apps)

        guard !isMonitoring else {
            logger.info("Updated monitored apps list: \(apps)")
            return
        }

        isMonitoring = true
        logger.info("Started app monitoring for: \(apps)")
    }

    public func stopMonitoring() {
        isMonitoring = false
        checkTimer?.cancel()
        checkTimer = nil
        eventContinuation?.finish()
        eventContinuation = nil
        logger.info("Stopped app monitoring")
    }

    /// Update the list of monitored apps
    public func updateMonitoredApps(_ apps: [String]) {
        self.monitoredApps = Set(apps)
        logger.info("Updated monitored apps: \(apps)")
    }

    // MARK: - App Event Stream

    /// Stream of app events (launched, terminated, activated)
    public func appEventStream() -> AsyncStream<AppEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation

            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.clearEventContinuation() }
            }
        }
    }

    private func clearEventContinuation() {
        eventContinuation = nil
    }

    /// Emit an app event (called from notification handlers)
    public func emitEvent(_ event: AppEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - Query Methods

    /// Check if any monitored app is currently active (frontmost)
    /// Returns: The name of the detected app, or nil
    public func checkForActiveMeetingApp() -> String? {
        let ws = NSWorkspace.shared
        let runningApps = ws.runningApplications

        for app in runningApps {
            guard let name = app.localizedName else { continue }

            if monitoredApps.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                return name
            }
        }

        return nil
    }

    /// Get all currently running apps from the monitored list
    public func getRunningMonitoredApps() -> [(name: String, bundleId: String?)] {
        let ws = NSWorkspace.shared
        let runningApps = ws.runningApplications

        var results: [(name: String, bundleId: String?)] = []

        for app in runningApps {
            guard let name = app.localizedName else { continue }

            if monitoredApps.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                results.append((name: name, bundleId: app.bundleIdentifier))
            }
        }

        return results
    }

    /// Check if a specific app is running
    public func isAppRunning(named appName: String) -> Bool {
        let ws = NSWorkspace.shared
        return ws.runningApplications.contains { app in
            guard let name = app.localizedName else { return false }
            return name.localizedCaseInsensitiveContains(appName)
        }
    }

    /// Get the frontmost app if it's a monitored app
    public func getFrontmostMonitoredApp() -> (name: String, bundleId: String?)? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let name = frontmost.localizedName else {
            return nil
        }

        if monitoredApps.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
            return (name: name, bundleId: frontmost.bundleIdentifier)
        }

        return nil
    }
}
