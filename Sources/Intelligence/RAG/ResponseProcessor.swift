import Foundation

/// Processes LLM responses to handle think tags and formatting
/// 
/// Handles:
/// - Stripping `<think>...</think>` tags and their content
/// - Emitting "thinking" status while model is in think mode
/// - Cleaning up response formatting
public actor ResponseProcessor {
    
    /// State of the processor
    public enum State: Sendable {
        case normal
        case thinking
    }
    
    /// Output from processing a token
    public struct ProcessedOutput: Sendable {
        /// The cleaned token to display (may be empty if inside think tags)
        public let displayToken: String
        /// Whether the model is currently "thinking"
        public let isThinking: Bool
        /// Status message to show (e.g., "Thinking...")
        public let statusMessage: String?
        
        public init(displayToken: String, isThinking: Bool, statusMessage: String? = nil) {
            self.displayToken = displayToken
            self.isThinking = isThinking
            self.statusMessage = statusMessage
        }
    }
    
    private var state: State = .normal
    private var buffer: String = ""
    private var hasEmittedThinkingStatus: Bool = false
    
    public init() {}
    
    /// Reset the processor state for a new response
    public func reset() {
        state = .normal
        buffer = ""
        hasEmittedThinkingStatus = false
    }
    
    /// Process a single token from the LLM stream
    /// - Parameter token: The raw token from the LLM
    /// - Returns: Processed output with display token and status
    public func processToken(_ token: String) -> ProcessedOutput {
        buffer += token
        
        // Check for think tag transitions
        switch state {
        case .normal:
            // Look for opening think tag
            if let thinkStart = buffer.range(of: "<think>", options: .caseInsensitive) {
                // Extract any content before the think tag
                let beforeThink = String(buffer[..<thinkStart.lowerBound])
                buffer = String(buffer[thinkStart.lowerBound...])
                state = .thinking
                hasEmittedThinkingStatus = false
                
                // Return content before think tag (if any)
                if !beforeThink.isEmpty {
                    return ProcessedOutput(displayToken: beforeThink, isThinking: false)
                } else {
                    return ProcessedOutput(displayToken: "", isThinking: true, statusMessage: "Thinking...")
                }
            }
            
            // No think tag found, but might be partial - keep last 7 chars in buffer
            if buffer.count > 7 {
                let safeToEmit = String(buffer.dropLast(7))
                buffer = String(buffer.suffix(7))
                return ProcessedOutput(displayToken: safeToEmit, isThinking: false)
            }
            
            return ProcessedOutput(displayToken: "", isThinking: false)
            
        case .thinking:
            // Look for closing think tag
            if let thinkEnd = buffer.range(of: "</think>", options: .caseInsensitive) {
                // Discard think content, keep anything after
                buffer = String(buffer[thinkEnd.upperBound...])
                state = .normal
                
                // Emit thinking status if we haven't yet
                if !hasEmittedThinkingStatus {
                    hasEmittedThinkingStatus = true
                    return ProcessedOutput(displayToken: "", isThinking: false, statusMessage: nil)
                }
                return ProcessedOutput(displayToken: "", isThinking: false)
            }
            
            // Still thinking - emit status once
            if !hasEmittedThinkingStatus {
                hasEmittedThinkingStatus = true
                return ProcessedOutput(displayToken: "", isThinking: true, statusMessage: "Thinking...")
            }
            
            // Keep buffering, don't emit content
            return ProcessedOutput(displayToken: "", isThinking: true)
        }
    }
    
    /// Flush any remaining content in the buffer
    /// Call this when the stream ends
    public func flush() -> ProcessedOutput {
        let remaining = buffer
        buffer = ""
        
        // If we're still in thinking mode at the end, something went wrong
        // Just return empty and reset
        if state == .thinking {
            state = .normal
            return ProcessedOutput(displayToken: "", isThinking: false)
        }
        
        return ProcessedOutput(displayToken: remaining, isThinking: false)
    }
    
    /// Post-process a complete response for better formatting
    /// - Parameter response: The complete response text
    /// - Returns: Cleaned and formatted response
    public static func formatResponse(_ response: String) -> String {
        var result = response

        // Remove any remaining think tags (shouldn't happen, but just in case)
        result = result.replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>",
            with: "",
            options: .regularExpression
        )

        // Remove thinking indicator patterns that may have been emitted as text
        result = stripThinkingPatterns(result)

        // Clean up excessive whitespace
        result = result.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        // Trim leading/trailing whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ensure bullet points are formatted consistently
        result = result.replacingOccurrences(of: "•", with: "-")
        result = result.replacingOccurrences(of: "◦", with: "  -")

        // Clean up numbered lists (ensure space after number)
        result = result.replacingOccurrences(
            of: "([0-9]+)\\.([^ ])",
            with: "$1. $2",
            options: .regularExpression
        )

        return result
    }

    /// Strip thinking-related patterns from text
    /// This removes any "Thinking...", "*Thinking...*", "Analyzing..." patterns that
    /// may have been inadvertently included in responses
    /// - Parameter text: The text to clean
    /// - Returns: Text with thinking patterns removed
    public static func stripThinkingPatterns(_ text: String) -> String {
        var result = text

        // Common thinking indicator patterns (with optional markdown formatting)
        let patterns = [
            // Markdown italic: *Thinking...* or _Thinking..._
            "\\*Thinking\\.{0,3}\\*\\s*\\n*",
            "_Thinking\\.{0,3}_\\s*\\n*",
            // Plain text: Thinking...
            "^Thinking\\.{0,3}\\s*\\n*",
            // Analyzing patterns (for map-reduce)
            "\\*Analyzing \\d+ sections of the transcript\\.{0,3}\\*\\s*\\n*",
            "_Analyzing \\d+ sections of the transcript\\.{0,3}_\\s*\\n*",
            // Generic status patterns
            "\\*Processing\\.{0,3}\\*\\s*\\n*",
            "_Processing\\.{0,3}_\\s*\\n*"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }

        return result
    }
}

