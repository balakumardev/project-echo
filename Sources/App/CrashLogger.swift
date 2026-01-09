import Foundation
import os.log

/// Persistent crash and error logger that works in both debug and release builds.
/// Logs are written to a file that can be shared for debugging.
public final class CrashLogger {

    // MARK: - Singleton

    public static let shared = CrashLogger()

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "CrashLogger")
    private let logFileURL: URL
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "dev.balakumar.engram.crashlogger", qos: .utility)
    private let maxLogSize: Int64 = 5 * 1024 * 1024 // 5MB max log size
    private let dateFormatter: DateFormatter

    // MARK: - Initialization

    private init() {
        // Setup date formatter
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // Create log directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDirectory = appSupport.appendingPathComponent("Engram").appendingPathComponent("Logs")

        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            print("[CrashLogger] Failed to create log directory: \(error)")
        }

        // Create/open log file
        logFileURL = logDirectory.appendingPathComponent("engram_errors.log")

        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        // Open file handle for appending
        do {
            fileHandle = try FileHandle(forWritingTo: logFileURL)
            fileHandle?.seekToEndOfFile()
        } catch {
            print("[CrashLogger] Failed to open log file: \(error)")
            fileHandle = nil
        }

        // Setup crash handlers
        setupCrashHandlers()

        // Log startup
        logInfo("Engram started - Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "unknown")")
    }

    deinit {
        try? fileHandle?.close()
    }

    // MARK: - Crash Handlers

    private func setupCrashHandlers() {
        // Handle uncaught exceptions
        NSSetUncaughtExceptionHandler { exception in
            CrashLogger.shared.logCrash(
                type: "UncaughtException",
                name: exception.name.rawValue,
                reason: exception.reason ?? "Unknown reason",
                stackTrace: exception.callStackSymbols.joined(separator: "\n")
            )
        }

        // Handle signals (SIGABRT, SIGSEGV, SIGBUS, etc.)
        signal(SIGABRT) { signal in
            CrashLogger.shared.logCrash(type: "Signal", name: "SIGABRT", reason: "Abort signal received", stackTrace: Thread.callStackSymbols.joined(separator: "\n"))
        }
        signal(SIGSEGV) { signal in
            CrashLogger.shared.logCrash(type: "Signal", name: "SIGSEGV", reason: "Segmentation fault", stackTrace: Thread.callStackSymbols.joined(separator: "\n"))
        }
        signal(SIGBUS) { signal in
            CrashLogger.shared.logCrash(type: "Signal", name: "SIGBUS", reason: "Bus error", stackTrace: Thread.callStackSymbols.joined(separator: "\n"))
        }
        signal(SIGILL) { signal in
            CrashLogger.shared.logCrash(type: "Signal", name: "SIGILL", reason: "Illegal instruction", stackTrace: Thread.callStackSymbols.joined(separator: "\n"))
        }
        signal(SIGFPE) { signal in
            CrashLogger.shared.logCrash(type: "Signal", name: "SIGFPE", reason: "Floating point exception", stackTrace: Thread.callStackSymbols.joined(separator: "\n"))
        }
        signal(SIGTRAP) { signal in
            CrashLogger.shared.logCrash(type: "Signal", name: "SIGTRAP", reason: "Trace trap (Swift runtime error)", stackTrace: Thread.callStackSymbols.joined(separator: "\n"))
        }
    }

    // MARK: - Public Logging API

    /// Log an informational message
    public func logInfo(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: "INFO", message: message, file: file, function: function, line: line)
    }

    /// Log a warning message
    public func logWarning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: "WARN", message: message, file: file, function: function, line: line)
        logger.warning("\(message)")
    }

    /// Log an error message
    public func logError(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        var fullMessage = message
        if let error = error {
            fullMessage += " | Error: \(error.localizedDescription)"
            if let nsError = error as NSError? {
                fullMessage += " | Domain: \(nsError.domain), Code: \(nsError.code)"
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                    fullMessage += " | Underlying: \(underlying.localizedDescription)"
                }
            }
        }
        log(level: "ERROR", message: fullMessage, file: file, function: function, line: line)
        logger.error("\(message)")
    }

    /// Log a crash event
    public func logCrash(type: String, name: String, reason: String, stackTrace: String, file: String = #file, function: String = #function, line: Int = #line) {
        let crashMessage = """

        ════════════════════════════════════════════════════════════════
        CRASH DETECTED
        ════════════════════════════════════════════════════════════════
        Type: \(type)
        Name: \(name)
        Reason: \(reason)
        Location: \(URL(fileURLWithPath: file).lastPathComponent):\(line) in \(function)

        Stack Trace:
        \(stackTrace)
        ════════════════════════════════════════════════════════════════

        """
        log(level: "CRASH", message: crashMessage, file: file, function: function, line: line)
        logger.critical("CRASH: \(type) - \(name): \(reason)")

        // Force flush to disk
        queue.sync {
            try? fileHandle?.synchronize()
        }
    }

    /// Log a caught exception with context
    public func logException(_ error: Error, context: String, file: String = #file, function: String = #function, line: Int = #line) {
        let stackTrace = Thread.callStackSymbols.joined(separator: "\n")
        let message = """
        Exception caught in \(context)
        Error: \(error.localizedDescription)
        Type: \(type(of: error))
        Stack:
        \(stackTrace)
        """
        log(level: "EXCEPTION", message: message, file: file, function: function, line: line)
    }

    // MARK: - Log File Management

    /// Get the path to the log file for sharing
    public var logFilePath: String {
        logFileURL.path
    }

    /// Get the log file URL for sharing
    public var logFileURLForSharing: URL {
        logFileURL
    }

    /// Get the contents of the log file
    public func getLogContents() -> String {
        do {
            return try String(contentsOf: logFileURL, encoding: .utf8)
        } catch {
            return "Failed to read log file: \(error.localizedDescription)"
        }
    }

    /// Get the last N lines of the log
    public func getRecentLogs(lines: Int = 100) -> String {
        let contents = getLogContents()
        let allLines = contents.components(separatedBy: "\n")
        let recentLines = allLines.suffix(lines)
        return recentLines.joined(separator: "\n")
    }

    /// Clear old logs (keeps last 1000 lines)
    public func trimLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }

            do {
                let contents = try String(contentsOf: self.logFileURL, encoding: .utf8)
                let lines = contents.components(separatedBy: "\n")

                // Keep last 1000 lines
                if lines.count > 1000 {
                    let trimmedLines = Array(lines.suffix(1000))
                    let trimmedContents = trimmedLines.joined(separator: "\n")
                    try trimmedContents.write(to: self.logFileURL, atomically: true, encoding: .utf8)
                }
            } catch {
                print("[CrashLogger] Failed to trim logs: \(error)")
            }
        }
    }

    /// Check if there are crash logs from a previous session
    public func hasPreviousCrashLogs() -> Bool {
        let contents = getLogContents()
        return contents.contains("CRASH DETECTED") || contents.contains("[CRASH]") || contents.contains("[EXCEPTION]")
    }

    /// Get crash entries from the log
    public func getCrashEntries() -> [String] {
        let contents = getLogContents()
        let lines = contents.components(separatedBy: "\n")
        var crashes: [String] = []
        var currentCrash: [String] = []
        var inCrashBlock = false

        for line in lines {
            if line.contains("CRASH DETECTED") || line.contains("[CRASH]") {
                inCrashBlock = true
                currentCrash = [line]
            } else if inCrashBlock {
                currentCrash.append(line)
                if line.contains("═══════") && currentCrash.count > 3 {
                    crashes.append(currentCrash.joined(separator: "\n"))
                    currentCrash = []
                    inCrashBlock = false
                }
            }
        }

        return crashes
    }

    // MARK: - Private Helpers

    private func log(level: String, message: String, file: String, function: String, line: Int) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let logLine = "[\(timestamp)] [\(level)] [\(fileName):\(line)] \(message)\n"

        queue.async { [weak self] in
            guard let self = self, let handle = self.fileHandle else { return }

            do {
                // Check file size and trim if needed
                let attributes = try FileManager.default.attributesOfItem(atPath: self.logFileURL.path)
                if let size = attributes[.size] as? Int64, size > self.maxLogSize {
                    self.trimLogs()
                }

                // Write log entry
                if let data = logLine.data(using: .utf8) {
                    handle.write(data)
                }
            } catch {
                print("[CrashLogger] Failed to write log: \(error)")
            }
        }
    }
}

// MARK: - Convenience Functions

/// Log an error with context - use this throughout the app
public func logError(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    CrashLogger.shared.logError(message, error: error, file: file, function: function, line: line)
}

/// Log a warning - use this throughout the app
public func logWarning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    CrashLogger.shared.logWarning(message, file: file, function: function, line: line)
}

/// Log an exception that was caught - use this in catch blocks
public func logException(_ error: Error, context: String, file: String = #file, function: String = #function, line: Int = #line) {
    CrashLogger.shared.logException(error, context: context, file: file, function: function, line: line)
}
