import Foundation
import os.log

/// Hybrid file logger that writes to persistent log files alongside OSLog.
/// Provides separate log files for debug and RAG operations with automatic rotation.
/// Thread-safe and designed to work in both debug and release builds.
///
/// Log locations:
/// - Debug: ~/Library/Logs/Engram/debug.log
/// - RAG:   ~/Library/Logs/Engram/rag.log
public final class FileLogger: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = FileLogger()

    // MARK: - Log Categories

    public enum Category: String {
        case debug = "debug"
        case rag = "rag"
    }

    // MARK: - Properties

    private let debugLogger = Logger(subsystem: "dev.balakumar.engram", category: "Debug")
    private let ragLogger = Logger(subsystem: "dev.balakumar.engram", category: "RAG")

    private let logDirectory: URL
    private let debugLogURL: URL
    private let ragLogURL: URL

    private var debugFileHandle: FileHandle?
    private var ragFileHandle: FileHandle?

    private let debugQueue = DispatchQueue(label: "dev.balakumar.engram.filelog.debug", qos: .utility)
    private let ragQueue = DispatchQueue(label: "dev.balakumar.engram.filelog.rag", qos: .utility)

    private let maxLogSize: Int64 = 5 * 1024 * 1024 // 5MB max per log file
    private let maxLines: Int = 2000 // Lines to keep after trimming

    private let dateFormatter: DateFormatter

    // MARK: - Initialization

    private init() {
        // Setup date formatter
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // Create log directory at ~/Library/Logs/Engram/
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        logDirectory = libraryURL.appendingPathComponent("Logs").appendingPathComponent("Engram")

        debugLogURL = logDirectory.appendingPathComponent("debug.log")
        ragLogURL = logDirectory.appendingPathComponent("rag.log")

        // Create directory if needed
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            print("[FileLogger] Failed to create log directory: \(error)")
        }

        // Initialize file handles
        debugFileHandle = openOrCreateLogFile(at: debugLogURL)
        ragFileHandle = openOrCreateLogFile(at: ragLogURL)

        // Log startup
        logInternal(
            category: .debug,
            level: "INFO",
            message: "FileLogger started - Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")"
        )
    }

    deinit {
        try? debugFileHandle?.close()
        try? ragFileHandle?.close()
    }

    // MARK: - File Management

    private func openOrCreateLogFile(at url: URL) -> FileHandle? {
        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        // Open file handle for appending
        do {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            return handle
        } catch {
            print("[FileLogger] Failed to open log file at \(url.path): \(error)")
            return nil
        }
    }

    // MARK: - Public Debug Logging API

    /// Log a debug message (general app debugging, meeting detection, audio capture, etc.)
    public func debug(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        logInternal(category: .debug, level: "DEBUG", message: message, file: file, function: function, line: line)
        #if DEBUG
        debugLogger.debug("\(message)")
        #endif
    }

    /// Log a debug info message
    public func debugInfo(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        logInternal(category: .debug, level: "INFO", message: message, file: file, function: function, line: line)
        debugLogger.info("\(message)")
    }

    /// Log a debug warning message
    public func debugWarning(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        logInternal(category: .debug, level: "WARN", message: message, file: file, function: function, line: line)
        debugLogger.warning("\(message)")
    }

    /// Log a debug error message
    public func debugError(
        _ message: String,
        error: Error? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var fullMessage = message
        if let error = error {
            fullMessage += " | Error: \(error.localizedDescription)"
        }
        logInternal(category: .debug, level: "ERROR", message: fullMessage, file: file, function: function, line: line)
        debugLogger.error("\(message)")
    }

    // MARK: - Public RAG Logging API

    /// Log a RAG/AI operation message (transcription, summarization, agent queries, model loading)
    public func rag(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        logInternal(category: .rag, level: "DEBUG", message: message, file: file, function: function, line: line)
        #if DEBUG
        ragLogger.debug("\(message)")
        #endif
    }

    /// Log a RAG info message
    public func ragInfo(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        logInternal(category: .rag, level: "INFO", message: message, file: file, function: function, line: line)
        ragLogger.info("\(message)")
    }

    /// Log a RAG warning message
    public func ragWarning(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        logInternal(category: .rag, level: "WARN", message: message, file: file, function: function, line: line)
        ragLogger.warning("\(message)")
    }

    /// Log a RAG error message
    public func ragError(
        _ message: String,
        error: Error? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var fullMessage = message
        if let error = error {
            fullMessage += " | Error: \(error.localizedDescription)"
        }
        logInternal(category: .rag, level: "ERROR", message: fullMessage, file: file, function: function, line: line)
        ragLogger.error("\(message)")
    }

    /// Log an agent-specific message (prefixed with [Agent])
    public func agent(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        rag("[Agent] \(message)", file: file, function: function, line: line)
    }

    /// Log an AI service message (prefixed with [AIService])
    public func aiService(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        rag("[AIService] \(message)", file: file, function: function, line: line)
    }

    // MARK: - Log File Access

    /// Get the path to the debug log file
    public var debugLogPath: String {
        debugLogURL.path
    }

    /// Get the path to the RAG log file
    public var ragLogPath: String {
        ragLogURL.path
    }

    /// Get the log directory URL
    public var logDirectoryURL: URL {
        logDirectory
    }

    /// Get contents of the debug log
    public func getDebugLogContents() -> String {
        getLogContents(at: debugLogURL)
    }

    /// Get contents of the RAG log
    public func getRagLogContents() -> String {
        getLogContents(at: ragLogURL)
    }

    /// Get the last N lines of the debug log
    public func getRecentDebugLogs(lines: Int = 100) -> String {
        getRecentLines(from: debugLogURL, count: lines)
    }

    /// Get the last N lines of the RAG log
    public func getRecentRagLogs(lines: Int = 100) -> String {
        getRecentLines(from: ragLogURL, count: lines)
    }

    /// Manually trigger log rotation for both files
    public func rotateLogsIfNeeded() {
        debugQueue.async { [weak self] in
            self?.trimLogIfNeeded(category: .debug)
        }
        ragQueue.async { [weak self] in
            self?.trimLogIfNeeded(category: .rag)
        }
    }

    /// Clear all logs
    public func clearAllLogs() {
        debugQueue.sync { [weak self] in
            self?.clearLog(category: .debug)
        }
        ragQueue.sync { [weak self] in
            self?.clearLog(category: .rag)
        }
    }

    // MARK: - Private Logging Implementation

    private func logInternal(
        category: Category,
        level: String,
        message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let logLine = "[\(timestamp)] [\(level)] [\(fileName):\(line)] \(message)\n"

        switch category {
        case .debug:
            debugQueue.async { [weak self] in
                self?.writeToLog(logLine, category: .debug)
            }
        case .rag:
            ragQueue.async { [weak self] in
                self?.writeToLog(logLine, category: .rag)
            }
        }
    }

    private func writeToLog(_ logLine: String, category: Category) {
        let handle: FileHandle?
        let url: URL

        switch category {
        case .debug:
            handle = debugFileHandle
            url = debugLogURL
        case .rag:
            handle = ragFileHandle
            url = ragLogURL
        }

        guard let fileHandle = handle else { return }

        do {
            // Check file size and trim if needed
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int64, size > maxLogSize {
                trimLog(at: url, category: category)
            }

            // Write log entry
            if let data = logLine.data(using: .utf8) {
                fileHandle.write(data)
            }
        } catch {
            print("[FileLogger] Failed to write to \(category.rawValue) log: \(error)")
        }
    }

    private func trimLogIfNeeded(category: Category) {
        let url: URL
        switch category {
        case .debug:
            url = debugLogURL
        case .rag:
            url = ragLogURL
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int64, size > maxLogSize {
                trimLog(at: url, category: category)
            }
        } catch {
            // File may not exist yet, that's fine
        }
    }

    private func trimLog(at url: URL, category: Category) {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let lines = contents.components(separatedBy: "\n")

            // Keep last maxLines
            if lines.count > maxLines {
                let trimmedLines = Array(lines.suffix(maxLines))
                let trimmedContents = trimmedLines.joined(separator: "\n")

                // Close current handle
                switch category {
                case .debug:
                    try? debugFileHandle?.close()
                case .rag:
                    try? ragFileHandle?.close()
                }

                // Write trimmed contents
                try trimmedContents.write(to: url, atomically: true, encoding: .utf8)

                // Reopen handle
                switch category {
                case .debug:
                    debugFileHandle = openOrCreateLogFile(at: url)
                case .rag:
                    ragFileHandle = openOrCreateLogFile(at: url)
                }

                print("[FileLogger] Trimmed \(category.rawValue) log from \(lines.count) to \(maxLines) lines")
            }
        } catch {
            print("[FileLogger] Failed to trim \(category.rawValue) log: \(error)")
        }
    }

    private func clearLog(category: Category) {
        let url: URL
        switch category {
        case .debug:
            url = debugLogURL
            try? debugFileHandle?.close()
        case .rag:
            url = ragLogURL
            try? ragFileHandle?.close()
        }

        do {
            try "".write(to: url, atomically: true, encoding: .utf8)

            // Reopen handle
            switch category {
            case .debug:
                debugFileHandle = openOrCreateLogFile(at: url)
            case .rag:
                ragFileHandle = openOrCreateLogFile(at: url)
            }
        } catch {
            print("[FileLogger] Failed to clear \(category.rawValue) log: \(error)")
        }
    }

    private func getLogContents(at url: URL) -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "Failed to read log file: \(error.localizedDescription)"
        }
    }

    private func getRecentLines(from url: URL, count: Int) -> String {
        let contents = getLogContents(at: url)
        let allLines = contents.components(separatedBy: "\n")
        let recentLines = allLines.suffix(count)
        return recentLines.joined(separator: "\n")
    }
}

// MARK: - Convenience Global Functions

/// Log a debug message to FileLogger (meeting detection, audio capture, app lifecycle)
public func fileDebugLog(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    FileLogger.shared.debug(message, file: file, function: function, line: line)
}

/// Log a RAG/AI message to FileLogger (transcription, summarization, agent queries)
public func fileRagLog(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    FileLogger.shared.rag(message, file: file, function: function, line: line)
}
