import Foundation

/// Represents the detected intent of a user query
public enum QueryIntent: Sendable, Equatable {
    /// User wants a summary of the meeting/transcript
    case summary(SummaryType)

    /// User wants specific information (who said what, specific topic)
    case specificQuestion

    /// User wants action items extracted
    case actionItems

    /// User wants topics/themes identified
    case topicExtraction

    public enum SummaryType: Sendable, Equatable {
        case brief      // 1-2 paragraphs
        case detailed   // Comprehensive
        case keyPoints  // Bullet points
    }
}

/// Result of intent classification
public struct IntentClassification: Sendable {
    public let intent: QueryIntent
    public let confidence: Float  // 0.0-1.0

    public init(intent: QueryIntent, confidence: Float) {
        self.intent = intent
        self.confidence = confidence
    }
}

