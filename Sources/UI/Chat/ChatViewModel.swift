import Foundation
import SwiftUI
import Database
import Intelligence

// MARK: - Data Models

/// A message displayed in the chat interface
public struct DisplayMessage: Identifiable, Sendable {
    public let id: String
    public let role: String  // "user" or "assistant"
    public let content: String
    public let citations: [Citation]?
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        role: String,
        content: String,
        citations: [Citation]? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.citations = citations
        self.timestamp = timestamp
    }
}

/// A citation referencing a transcript segment
public struct Citation: Identifiable, Sendable {
    public let id: String
    public let segmentId: Int64
    public let recordingId: Int64
    public let recordingTitle: String
    public let speaker: String
    public let timestamp: TimeInterval
    public let text: String

    public init(
        segmentId: Int64,
        recordingId: Int64,
        recordingTitle: String,
        speaker: String,
        timestamp: TimeInterval,
        text: String
    ) {
        self.id = UUID().uuidString
        self.segmentId = segmentId
        self.recordingId = recordingId
        self.recordingTitle = recordingTitle
        self.speaker = speaker
        self.timestamp = timestamp
        self.text = text
    }
}

// MARK: - RAG Pipeline Protocol

/// Protocol for the RAG pipeline that handles queries
@available(macOS 14.0, *)
public protocol RAGPipelineProtocol: Sendable {
    /// Check if the LLM model is loaded and ready
    var isModelReady: Bool { get async }

    /// Returns the number of indexed recordings
    var indexedRecordingsCount: Int { get async }

    /// Returns the total number of recordings with transcripts that could be indexed
    func totalIndexableRecordings() async -> Int

    /// Query the pipeline with a user question
    /// - Parameters:
    ///   - query: The user's question
    ///   - recordingId: Optional recording ID to scope the search
    ///   - conversationHistory: Previous messages for context
    /// - Returns: An async stream of response tokens and optional citations
    func query(
        _ query: String,
        recordingId: Int64?,
        conversationHistory: [(role: String, content: String)]
    ) -> AsyncThrowingStream<RAGResponse, Error>

    /// Load the models required for RAG
    func loadModels() async throws

    /// Unload models to free memory
    func unloadModels() async
}

/// Response chunk from the RAG pipeline
public struct RAGResponse: Sendable {
    public let token: String?
    public let citations: [Citation]?
    public let isComplete: Bool

    public init(token: String? = nil, citations: [Citation]? = nil, isComplete: Bool = false) {
        self.token = token
        self.citations = citations
        self.isComplete = isComplete
    }
}

// MARK: - Chat View Model

/// ViewModel for the chat interface
/// Now uses AIService.shared directly for AI operations
@MainActor
@available(macOS 14.0, *)
public class ChatViewModel: ObservableObject {

    // MARK: - Published Properties

    /// All messages in the conversation
    @Published public var messages: [DisplayMessage] = []

    /// Current input text
    @Published public var inputText: String = ""

    /// Whether the assistant is currently generating a response
    @Published public var isGenerating: Bool = false

    /// The current streaming response text
    @Published public var streamingResponse: String = ""

    /// Current error message, if any
    @Published public var error: String?

    /// Number of indexed recordings
    @Published public var indexedCount: Int = 0

    /// Whether the indexing count is still loading
    @Published public var isIndexingLoading: Bool = true

    // MARK: - Properties

    /// The recording to scope queries to (nil = global search across all recordings)
    /// This is the initial recording passed at init time
    private let initialRecording: DatabaseManager.Recording?

    /// Public read-only access to the initial recording (for UI display)
    public var recording: DatabaseManager.Recording? { initialRecording }

    /// Whether the view model currently has a recording scope (either initial or dynamic filter)
    public var hasRecordingScope: Bool { recordingFilter != nil }

    /// Dynamic recording filter that can be changed at runtime
    /// When set, queries are scoped to this recording ID
    @Published public var recordingFilter: Int64? {
        didSet {
            // Save current messages for the previous filter
            messagesByRecording[oldValue] = messages
            // Load messages for the new filter (or empty if none)
            messages = messagesByRecording[recordingFilter] ?? []
        }
    }

    /// Session ID for conversation context
    private let sessionId: String

    /// Task for the current generation (for cancellation)
    private var generationTask: Task<Void, Never>?

    /// Pending citations from the current generation
    private var pendingCitations: [Citation] = []

    /// Per-recording message storage - keyed by recording ID (nil = global)
    private var messagesByRecording: [Int64?: [DisplayMessage]] = [:]

    // MARK: - Initialization

    /// Creates a new ChatViewModel
    /// - Parameter recording: Optional recording to scope queries to
    public init(recording: DatabaseManager.Recording? = nil) {
        self.initialRecording = recording
        self.recordingFilter = recording?.id
        self.sessionId = UUID().uuidString

        // Refresh indexing status on init
        Task {
            await refreshIndexingStatus()
        }
    }

    /// Creates a new ChatViewModel with a RAG pipeline (for backward compatibility with previews)
    public init(recording: DatabaseManager.Recording? = nil, ragPipeline: any RAGPipelineProtocol) {
        self.initialRecording = recording
        self.recordingFilter = recording?.id
        self.sessionId = UUID().uuidString
        // ragPipeline is ignored - we use AIService.shared
    }

    // MARK: - Public Methods

    /// Refresh the indexing status
    public func refreshIndexingStatus() async {
        let service = AIService.shared
        indexedCount = await service.indexedRecordingsCount
        let initialized = await service.isInitialized
        let initializing = await service.isInitializing
        isIndexingLoading = !initialized || initializing
    }

    /// Send the current input as a message
    public func sendMessage() async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else { return }
        guard !isGenerating else { return }

        // Clear input and error
        inputText = ""
        error = nil

        // Add user message
        let userMessage = DisplayMessage(
            role: "user",
            content: query
        )
        messages.append(userMessage)

        // Start generating
        isGenerating = true
        streamingResponse = ""
        pendingCitations = []

        // Create generation task
        generationTask = Task {
            do {
                // Use AIService for agentic chat (intelligent intent-based routing)
                // Use recordingFilter which can be dynamically changed via the UI
                let stream = await AIService.shared.agentChat(
                    query: query,
                    sessionId: sessionId,
                    recordingFilter: self.recordingFilter
                )

                var rawResponse = ""
                for try await token in stream {
                    // Check for cancellation
                    if Task.isCancelled { break }

                    // Accumulate the raw response
                    rawResponse += token

                    // Clean thinking patterns for display during streaming
                    // This ensures users don't see "*Thinking...*" while content is generating
                    streamingResponse = ResponseProcessor.stripThinkingPatterns(rawResponse)
                }

                // Add assistant message with final response
                if !Task.isCancelled && !streamingResponse.isEmpty {
                    // Clean up any thinking patterns from the response
                    let cleanedResponse = ResponseProcessor.stripThinkingPatterns(streamingResponse)
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !cleanedResponse.isEmpty {
                        let assistantMessage = DisplayMessage(
                            role: "assistant",
                            content: cleanedResponse,
                            citations: pendingCitations.isEmpty ? nil : pendingCitations
                        )
                        messages.append(assistantMessage)
                    }
                }

            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }

            // Reset state
            isGenerating = false
            streamingResponse = ""
            pendingCitations = []
            generationTask = nil
        }
    }

    /// Stop the current generation
    public func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil

        // Add partial response if any
        if !streamingResponse.isEmpty {
            let assistantMessage = DisplayMessage(
                role: "assistant",
                content: streamingResponse + " [stopped]",
                citations: pendingCitations.isEmpty ? nil : pendingCitations
            )
            messages.append(assistantMessage)
        }

        isGenerating = false
        streamingResponse = ""
        pendingCitations = []
    }

    /// Clear conversation history for the current recording scope
    public func clearHistory() {
        stopGeneration()
        messages.removeAll()
        messagesByRecording[recordingFilter] = nil
        error = nil
    }

    /// Clear all conversation history across all recordings
    public func clearAllHistory() {
        stopGeneration()
        messages.removeAll()
        messagesByRecording.removeAll()
        error = nil
    }
}

// Note: Recording typealias is defined in ViewModels.swift
