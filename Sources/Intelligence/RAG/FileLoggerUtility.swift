import Foundation

// Shared file logger for the Intelligence module
// Writes to ~/Library/Logs/Engram/rag.log to match the format used by FileLogger in the App module

private let ragLogQueue = DispatchQueue(label: "dev.balakumar.engram.intelligence.raglog", qos: .utility)
private let ragDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

/// Log a RAG/AI operation message to the shared RAG log file
/// This is a standalone function for Intelligence module that writes to the same location as FileLogger
public func fileRagLog(_ message: String, file: String = #file, line: Int = #line) {
    ragLogQueue.async {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Engram")
        let logFile = logDir.appendingPathComponent("rag.log")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let timestamp = ragDateFormatter.string(from: Date())
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let logLine = "[\(timestamp)] [DEBUG] [\(fileName):\(line)] \(message)\n"

        guard let data = logLine.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

/// Log an agent-specific message to the RAG log file (prefixed with [Agent])
/// This matches the FileLogger.shared.agent() format
public func fileAgentLog(_ message: String, file: String = #file, line: Int = #line) {
    fileRagLog("[Agent] \(message)", file: file, line: line)
}

/// Log an AI service message to the RAG log file (prefixed with [AIService])
/// This matches the FileLogger.shared.aiService() format
public func fileAIServiceLog(_ message: String, file: String = #file, line: Int = #line) {
    fileRagLog("[AIService] \(message)", file: file, line: line)
}
