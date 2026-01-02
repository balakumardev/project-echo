import Foundation
import AppKit
import os.log

/// Handles macOS system events like sleep/wake for meeting detection
@available(macOS 14.0, *)
public class SystemEventHandler {

    // MARK: - Types

    public enum SystemEvent: Sendable {
        case willSleep
        case didWake
        case screenLocked
        case screenUnlocked
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.projectecho.app", category: "SystemEventHandler")
    private var observers: [NSObjectProtocol] = []
    private var eventContinuation: AsyncStream<SystemEvent>.Continuation?

    // MARK: - Initialization

    public init() {
        setupNotifications()
    }

    deinit {
        removeNotifications()
    }

    // MARK: - Public Methods

    /// Stream of system events
    public func eventStream() -> AsyncStream<SystemEvent> {
        // Finish any existing continuation before creating a new one
        eventContinuation?.finish()

        return AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    /// Manually trigger a wake check (useful for testing)
    public func simulateWake() {
        eventContinuation?.yield(.didWake)
    }

    // MARK: - Private Methods

    private func setupNotifications() {
        let wsNotificationCenter = NSWorkspace.shared.notificationCenter

        // System will sleep
        let willSleepObserver = wsNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("System will sleep")
            self?.eventContinuation?.yield(.willSleep)
        }
        observers.append(willSleepObserver)

        // System did wake
        let didWakeObserver = wsNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("System did wake")
            self?.eventContinuation?.yield(.didWake)
        }
        observers.append(didWakeObserver)

        // Screen locked (via distributed notification center)
        let screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("Screen locked")
            self?.eventContinuation?.yield(.screenLocked)
        }
        observers.append(screenLockedObserver)

        // Screen unlocked (via distributed notification center)
        let screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("Screen unlocked")
            self?.eventContinuation?.yield(.screenUnlocked)
        }
        observers.append(screenUnlockedObserver)

        // Screens did wake (alternative wake notification)
        let screensDidWakeObserver = wsNotificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("Screens did wake")
            // Also send didWake for screens waking
            self?.eventContinuation?.yield(.didWake)
        }
        observers.append(screensDidWakeObserver)

        logger.info("System event observers set up")
    }

    private func removeNotifications() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil

        logger.info("System event observers removed")
    }
}
