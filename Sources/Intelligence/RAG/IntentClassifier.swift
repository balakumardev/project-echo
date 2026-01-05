import Foundation

/// Fast intent classification using keyword matching
/// No LLM call - just pattern matching for speed
public struct IntentClassifier: Sendable {

    // MARK: - Keyword Lists

    private static let summaryKeywords: Set<String> = [
        "summarize", "summarise", "summary", "overview", "recap",
        "brief", "briefing", "tldr", "tl;dr", "gist",
        "main points", "key points", "highlights", "takeaways",
        "what happened", "what was discussed", "what did we discuss",
        "give me a summary", "can you summarize", "summarize this",
        "meeting summary", "transcript summary"
    ]

    private static let actionItemKeywords: Set<String> = [
        "action items", "action points", "actionable",
        "to-do", "todo", "todos", "to do", "tasks",
        "follow up", "follow-up", "followup", "follow ups",
        "next steps", "assignments", "deliverables",
        "what do i need to do", "what should i do",
        "who needs to do what", "responsibilities"
    ]

    private static let topicKeywords: Set<String> = [
        "topics", "themes", "subjects", "agenda",
        "what topics", "which topics", "main topics",
        "what was covered", "what did we cover",
        "areas discussed", "discussion points"
    ]

    // MARK: - Classification

    public init() {}

    /// Classify a query into an intent category
    /// - Parameter query: The user's query string
    /// - Returns: Classification result with intent and confidence
    public func classify(_ query: String) -> IntentClassification {
        let lowercased = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Check summary patterns (highest priority for summary-type queries)
        for keyword in Self.summaryKeywords {
            if lowercased.contains(keyword) {
                let type: QueryIntent.SummaryType
                if lowercased.contains("brief") || lowercased.contains("quick") {
                    type = .brief
                } else if lowercased.contains("detailed") || lowercased.contains("comprehensive") {
                    type = .detailed
                } else {
                    type = .keyPoints  // Default summary type
                }
                return IntentClassification(intent: .summary(type), confidence: 0.95)
            }
        }

        // Check action items patterns
        for keyword in Self.actionItemKeywords {
            if lowercased.contains(keyword) {
                return IntentClassification(intent: .actionItems, confidence: 0.95)
            }
        }

        // Check topic patterns
        for keyword in Self.topicKeywords {
            if lowercased.contains(keyword) {
                return IntentClassification(intent: .topicExtraction, confidence: 0.90)
            }
        }

        // Default to specific question - use RAG search
        return IntentClassification(intent: .specificQuestion, confidence: 0.70)
    }
}

