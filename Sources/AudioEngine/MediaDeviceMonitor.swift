import Foundation
import CoreAudio
import AppKit
import os.log

// Debug logging for MediaDeviceMonitor
#if DEBUG
private func mediaDeviceLog(_ message: String) {
    let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("engram_debug.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [MediaDevice] \(message)\n"
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
@inline(__always) private func mediaDeviceLog(_ message: String) {}
#endif

/// Monitors system microphone usage to detect which apps are actively using the mic.
/// Uses macOS 14+ CoreAudio APIs (kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyBundleID).
@available(macOS 14.0, *)
public actor MediaDeviceMonitor {

    // MARK: - Types

    /// Information about a process using the microphone
    public struct MicrophoneUsage: Sendable, Equatable {
        public let pid: pid_t
        public let bundleID: String?
        public let appName: String?
        public let isUsingMicInput: Bool

        public init(pid: pid_t, bundleID: String?, appName: String?, isUsingMicInput: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.appName = appName
            self.isUsingMicInput = isUsingMicInput
        }
    }

    /// State change events
    public enum MicrophoneEvent: Sendable, Equatable {
        case microphoneActivated(MicrophoneUsage)   // An app started using the mic
        case microphoneDeactivated(MicrophoneUsage) // An app stopped using the mic
        case noChange                                // Polling found no changes
    }

    public struct Configuration: Sendable {
        public var pollingInterval: TimeInterval = 1.0

        public init(pollingInterval: TimeInterval = 1.0) {
            self.pollingInterval = pollingInterval
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "MediaDeviceMonitor")
    private var configuration: Configuration
    private var pollingTask: Task<Void, Never>?
    private var isMonitoring = false

    // Track previous state to detect changes
    private var previousMicUsers: Set<String> = []  // Set of bundleIDs using mic

    // AsyncStream continuation
    private var eventContinuation: AsyncStream<MicrophoneEvent>.Continuation?

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Start monitoring microphone usage
    public func startMonitoring() {
        guard !isMonitoring else {
            mediaDeviceLog("Already monitoring, skipping")
            return
        }

        mediaDeviceLog("Starting microphone usage monitoring")
        logger.info("Starting microphone usage monitoring")
        isMonitoring = true
        previousMicUsers = []

        pollingTask = Task {
            while !Task.isCancelled && isMonitoring {
                await pollMicrophoneUsage()
                try? await Task.sleep(nanoseconds: UInt64(configuration.pollingInterval * 1_000_000_000))
            }
        }
    }

    /// Stop monitoring
    public func stopMonitoring() {
        guard isMonitoring else { return }

        mediaDeviceLog("Stopping microphone usage monitoring")
        logger.info("Stopping microphone usage monitoring")

        pollingTask?.cancel()
        pollingTask = nil
        isMonitoring = false
        previousMicUsers = []

        eventContinuation?.finish()
        eventContinuation = nil
    }

    /// Get stream of microphone events
    public func eventStream() -> AsyncStream<MicrophoneEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation

            continuation.onTermination = { @Sendable _ in
                Task { await self.clearEventContinuation() }
            }
        }
    }

    /// Get current processes using microphone (one-shot query)
    public func getProcessesUsingMicrophone() -> [MicrophoneUsage] {
        return queryMicrophoneUsers()
    }

    /// Check if monitoring is active
    public func isCurrentlyMonitoring() -> Bool {
        return isMonitoring
    }

    // MARK: - Private Methods

    private func clearEventContinuation() {
        eventContinuation = nil
    }

    private func pollMicrophoneUsage() async {
        let currentUsers = queryMicrophoneUsers()
        let currentBundleIDs = Set(currentUsers.compactMap { $0.bundleID })

        // Detect new mic users (apps that just started using mic)
        let newUsers = currentBundleIDs.subtracting(previousMicUsers)
        for bundleID in newUsers {
            if let usage = currentUsers.first(where: { $0.bundleID == bundleID }) {
                mediaDeviceLog("NEW MIC USER: \(bundleID) (\(usage.appName ?? "unknown"))")
                logger.info("Microphone activated by: \(bundleID)")
                eventContinuation?.yield(.microphoneActivated(usage))
            }
        }

        // Detect stopped mic users (apps that stopped using mic)
        let stoppedUsers = previousMicUsers.subtracting(currentBundleIDs)
        for bundleID in stoppedUsers {
            mediaDeviceLog("MIC USER STOPPED: \(bundleID)")
            logger.info("Microphone deactivated by: \(bundleID)")
            // Create a minimal usage struct for the stopped app
            let usage = MicrophoneUsage(pid: 0, bundleID: bundleID, appName: nil, isUsingMicInput: false)
            eventContinuation?.yield(.microphoneDeactivated(usage))
        }

        // Update state
        previousMicUsers = currentBundleIDs

        // Log current state periodically (every 10 polls)
        if Int(Date().timeIntervalSince1970) % 10 == 0 && !currentUsers.isEmpty {
            let userList = currentUsers.map { "\($0.bundleID ?? "?")" }.joined(separator: ", ")
            mediaDeviceLog("Current mic users: [\(userList)]")
        }
    }

    /// Query CoreAudio for all processes currently using microphone input
    private func queryMicrophoneUsers() -> [MicrophoneUsage] {
        var results: [MicrophoneUsage] = []

        // Get list of all audio process objects
        guard let processObjectIDs = getAudioProcessObjectList() else {
            return results
        }

        for processObjectID in processObjectIDs {
            // Check if this process is using microphone input
            guard isProcessUsingMicInput(processObjectID) else {
                continue
            }

            // Get process details
            let pid = getProcessPID(processObjectID)
            let bundleID = getProcessBundleID(processObjectID)

            // Get app name from NSRunningApplication
            var appName: String? = nil
            if pid > 0, let runningApp = NSRunningApplication(processIdentifier: pid) {
                appName = runningApp.localizedName
            }

            // Skip our own process
            if bundleID == Bundle.main.bundleIdentifier {
                continue
            }

            let usage = MicrophoneUsage(
                pid: pid,
                bundleID: bundleID,
                appName: appName,
                isUsingMicInput: true
            )
            results.append(usage)
        }

        return results
    }

    // MARK: - CoreAudio API Wrappers

    /// Get list of all audio process objects from CoreAudio
    private func getAudioProcessObjectList() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize
        )

        guard status == noErr, dataSize > 0 else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize,
            &processIDs
        )

        guard status == noErr else {
            return nil
        }

        return processIDs.filter { $0 != kAudioObjectUnknown }
    }

    /// Check if a process is using microphone input
    private func isProcessUsingMicInput(_ processObjectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunningInput: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            processObjectID,
            &address,
            0, nil,
            &dataSize,
            &isRunningInput
        )

        return status == noErr && isRunningInput != 0
    }

    /// Get the PID of a process object
    private func getProcessPID(_ processObjectID: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var pid: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)

        let status = AudioObjectGetPropertyData(
            processObjectID,
            &address,
            0, nil,
            &dataSize,
            &pid
        )

        return status == noErr ? pid : 0
    }

    /// Get the bundle identifier of a process object
    private func getProcessBundleID(_ processObjectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            processObjectID,
            &address,
            0, nil,
            &dataSize
        )

        guard status == noErr, dataSize > 0 else {
            return nil
        }

        var bundleID: CFString?
        status = AudioObjectGetPropertyData(
            processObjectID,
            &address,
            0, nil,
            &dataSize,
            &bundleID
        )

        guard status == noErr, let result = bundleID else {
            return nil
        }

        return result as String
    }
}
