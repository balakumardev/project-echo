import Foundation
import Intelligence

/// Shared text cleaning utilities for AI responses and transcript processing
public enum TextCleaning {

    /// Clean up AI response to remove thinking text, empty arrays, and other artifacts.
    /// Returns nil if the cleaned result is empty or indicates no action items.
    public static func cleanActionItemsResponse(_ response: String) -> String? {
        // First, use ResponseProcessor to strip thinking patterns
        var cleaned = ResponseProcessor.stripThinkingPatterns(response)

        // Remove <think>...</think> blocks if present (should be handled by ResponseProcessor but just in case)
        let thinkBlockPattern = #"<think>[\s\S]*?</think>"#
        if let regex = try? NSRegularExpression(pattern: thinkBlockPattern, options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Remove standalone empty arrays "[]"
        cleaned = cleaned.replacingOccurrences(of: "[]", with: "")

        // Remove "No action items" type responses
        let noItemsPatterns = [
            #"(?i)no\s+(clear\s+)?action\s+items"#,
            #"(?i)no\s+action\s+items?\s+(were\s+)?found"#,
            #"(?i)there\s+are\s+no\s+(clear\s+)?action\s+items"#,
            #"(?i)i\s+(could\s+not|couldn't)\s+find\s+any\s+action\s+items"#
        ]
        for pattern in noItemsPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: cleaned, options: [], range: NSRange(cleaned.startIndex..., in: cleaned)) != nil {
                return nil // AI explicitly said no action items
            }
        }

        // Trim whitespace and newlines
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Return nil if empty
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Clean WhisperKit special tokens from text
    public static func cleanWhisperTokens(_ text: String) -> String {
        var cleaned = text

        // Remove special tokens: <|anything|>
        if let regex = try? NSRegularExpression(pattern: "<\\|[^|]*\\|>", options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Remove [BLANK_AUDIO] markers
        cleaned = cleaned.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")

        // Clean up multiple spaces
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clean up AI response to extract just the title
    public static func cleanTitleResponse(_ response: String) -> String? {
        // Strip thinking patterns
        var cleaned = ResponseProcessor.stripThinkingPatterns(response)

        // Remove <think>...</think> blocks
        let thinkBlockPattern = #"<think>[\s\S]*?</think>"#
        if let regex = try? NSRegularExpression(pattern: thinkBlockPattern, options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Remove common prefixes
        let prefixes = ["Title:", "title:", "TITLE:", "Meeting:", "meeting:"]
        for prefix in prefixes {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
            }
        }

        // Remove quotes if present
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))

        // Trim whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Take only the first line (in case AI added explanation)
        if let firstLine = cleaned.components(separatedBy: .newlines).first {
            cleaned = firstLine.trimmingCharacters(in: .whitespaces)
        }

        // Return nil if empty or too long
        if cleaned.isEmpty || cleaned.count > 100 {
            return nil
        }

        return cleaned
    }

    /// Parse markdown string into AttributedString for proper rendering
    public static func markdownAttributedString(from text: String) -> AttributedString {
        do {
            let attributed = try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))
            return attributed
        } catch {
            return AttributedString(text)
        }
    }
}
