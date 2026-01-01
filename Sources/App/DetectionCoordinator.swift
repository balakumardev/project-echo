import Foundation
import os.log

/// Represents the source of a meeting detection event
public enum DetectionSource: Sendable, Equatable, Hashable {
    case audio           // Detected via sustained audio activity
    case windowTitle     // Detected via Zoom window title change
    case manual          // User manually triggered recording

    var displayName: String {
        switch self {
        case .audio: return "Audio Detection"
        case .windowTitle: return "Window Title Detection"
        case .manual: return "Manual"
        }
    }

    /// Priority for detection (lower = higher priority)
    var priority: Int {
        switch self {
        case .manual: return 0      // Highest - user intent
        case .windowTitle: return 1 // High - definitive signal
        case .audio: return 2       // Lower - can have false positives
        }
    }
}

/// Tracks active detection sources and manages coordination to prevent overlap
@available(macOS 14.0, *)
public actor DetectionCoordinator {

    // MARK: - Types

    public struct DetectionEvent: Sendable {
        public let source: DetectionSource
        public let appName: String
        public let timestamp: Date
        public let metadata: [String: String]

        public init(source: DetectionSource, appName: String, metadata: [String: String] = [:]) {
            self.source = source
            self.appName = appName
            self.timestamp = Date()
            self.metadata = metadata
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.projectecho.app", category: "DetectionCoordinator")
    private var activeSources: Set<DetectionSource> = []
    private var primarySource: DetectionSource?
    private var currentApp: String?
    private var detectionTimestamps: [DetectionSource: Date] = [:]

    // MARK: - Initialization

    public init() {}

    // MARK: - Public API

    /// Register a detection event from a source
    /// Returns true if this source should trigger recording (is becoming primary)
    public func registerDetection(_ event: DetectionEvent) -> Bool {
        let wasEmpty = activeSources.isEmpty
        activeSources.insert(event.source)
        detectionTimestamps[event.source] = event.timestamp

        logger.info("Detection registered: \(event.source.displayName) for \(event.appName)")

        // If no primary source yet, this becomes primary
        guard let current = primarySource else {
            primarySource = event.source
            currentApp = event.appName
            logger.info("Primary detection source set: \(event.source.displayName)")
            return true
        }

        // If new source has higher priority (lower number), it becomes primary
        if event.source.priority < current.priority {
            primarySource = event.source
            currentApp = event.appName
            logger.info("Primary detection source upgraded to: \(event.source.displayName)")
            // Don't return true - recording already started
            return false
        }

        // Already have a primary source with equal or higher priority
        // This adds redundancy but doesn't trigger new recording
        return wasEmpty
    }

    /// Remove a detection source (e.g., when audio goes silent or window title changes to lobby)
    public func removeDetection(source: DetectionSource) {
        activeSources.remove(source)
        detectionTimestamps.removeValue(forKey: source)

        logger.info("Detection removed: \(source.displayName), remaining: \(self.activeSources.count)")

        // If primary source was removed, promote next best
        if primarySource == source {
            primarySource = activeSources.min(by: { $0.priority < $1.priority })
            if let newPrimary = primarySource {
                logger.info("Primary detection source demoted to: \(newPrimary.displayName)")
            } else {
                logger.info("No active detection sources remaining")
                currentApp = nil
            }
        }
    }

    /// Check if any detection source is active
    public func hasActiveDetection() -> Bool {
        return !activeSources.isEmpty
    }

    /// Get the current primary detection source
    public func getPrimarySource() -> DetectionSource? {
        return primarySource
    }

    /// Get all active detection sources
    public func getActiveSources() -> Set<DetectionSource> {
        return activeSources
    }

    /// Get the current app being monitored
    public func getCurrentApp() -> String? {
        return currentApp
    }

    /// Check if a specific source is active
    public func isSourceActive(_ source: DetectionSource) -> Bool {
        return activeSources.contains(source)
    }

    /// Reset all detection state
    public func reset() {
        activeSources.removeAll()
        primarySource = nil
        currentApp = nil
        detectionTimestamps.removeAll()
        logger.info("Detection coordinator reset")
    }

    /// Get debug info about current state
    public func debugInfo() -> String {
        let sources = activeSources.map { $0.displayName }.joined(separator: ", ")
        return "Active: [\(sources)], Primary: \(primarySource?.displayName ?? "none"), App: \(currentApp ?? "none")"
    }
}
