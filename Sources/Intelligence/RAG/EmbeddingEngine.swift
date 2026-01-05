import Foundation
import NaturalLanguage
import VecturaNLKit
import os.log

/// Generates vector embeddings for transcript segments and queries using Apple's NLContextualEmbedding
/// via VecturaNLKit. This actor provides thread-safe embedding operations for the RAG feature.
@available(macOS 14.0, *)
public actor EmbeddingEngine {

    // MARK: - Types

    /// Errors that can occur during embedding operations
    public enum EmbeddingError: Error, LocalizedError {
        case embeddingFailed(String)
        case modelNotLoaded
        case emptyInput

        public var errorDescription: String? {
            switch self {
            case .embeddingFailed(let reason):
                return "Embedding failed: \(reason)"
            case .modelNotLoaded:
                return "Embedding model is not loaded. Call loadModel() first."
            case .emptyInput:
                return "Cannot embed empty text"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "EmbeddingEngine")

    /// The cached embedder instance from VecturaNLKit
    private var embedder: NLContextualEmbedder?

    /// Tracks whether the model has been successfully loaded
    private var modelLoaded = false

    /// The language for embeddings (defaults to English)
    private let language: NLLanguage

    // MARK: - Initialization

    /// Creates an EmbeddingEngine with the specified language
    /// - Parameter language: The natural language for embeddings. Defaults to English.
    public init(language: NLLanguage = .english) {
        self.language = language
    }

    // MARK: - Public Interface

    /// Whether the embedding model is currently loaded and ready for use
    public var isModelLoaded: Bool {
        return modelLoaded
    }

    /// Load the embedding model. Call this once before using embed operations.
    /// This method is idempotent - calling it multiple times has no effect if already loaded.
    public func loadModel() async throws {
        guard !modelLoaded else {
            logger.debug("Model already loaded, skipping")
            return
        }

        logger.info("Loading NLContextualEmbedder model for language: \(self.language.rawValue)...")
        let startTime = Date()

        do {
            embedder = try await NLContextualEmbedder(language: language)
            modelLoaded = true

            let loadTime = Date().timeIntervalSince(startTime)
            logger.info("NLContextualEmbedder loaded in \(String(format: "%.2f", loadTime))s")
        } catch {
            logger.error("Failed to load NLContextualEmbedder: \(error.localizedDescription)")
            throw EmbeddingError.embeddingFailed("Model initialization failed: \(error.localizedDescription)")
        }
    }

    /// Generate an embedding vector for a single text string
    /// - Parameter text: The text to embed
    /// - Returns: A vector of Float values representing the text embedding
    /// - Throws: EmbeddingError if model not loaded or embedding fails
    public func embed(_ text: String) async throws -> [Float] {
        guard modelLoaded, let embedder = embedder else {
            throw EmbeddingError.modelNotLoaded
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw EmbeddingError.emptyInput
        }

        do {
            let vector = try await embedder.embed(text: trimmedText)
            logger.debug("Generated embedding with \(vector.count) dimensions for text of length \(trimmedText.count)")
            return vector
        } catch {
            logger.error("Embedding failed for text: \(error.localizedDescription)")
            throw EmbeddingError.embeddingFailed(error.localizedDescription)
        }
    }

    /// Generate embedding vectors for multiple texts in batch
    /// - Parameter texts: Array of texts to embed
    /// - Returns: Array of embedding vectors, one for each input text
    /// - Throws: EmbeddingError if model not loaded or any embedding fails
    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard modelLoaded, let embedder = embedder else {
            throw EmbeddingError.modelNotLoaded
        }

        guard !texts.isEmpty else {
            return []
        }

        logger.info("Batch embedding \(texts.count) texts...")
        let startTime = Date()

        // Filter out empty texts and track their indices
        let validTexts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .enumerated()
            .filter { !$0.element.isEmpty }
            .map { (index: $0.offset, text: $0.element) }

        if validTexts.isEmpty {
            logger.warning("All texts were empty, returning empty embeddings")
            return texts.map { _ in [] }
        }

        do {
            // Use the batch API from NLContextualEmbedder
            let batchTexts = validTexts.map { $0.text }
            let batchEmbeddings = try await embedder.embed(texts: batchTexts)

            // Reconstruct the result array with empty vectors for empty inputs
            var embeddings: [[Float]] = Array(repeating: [], count: texts.count)
            for (resultIndex, validItem) in validTexts.enumerated() {
                embeddings[validItem.index] = batchEmbeddings[resultIndex]
            }

            let processingTime = Date().timeIntervalSince(startTime)
            let avgTime = processingTime / Double(validTexts.count)
            logger.info("Batch embedding complete: \(validTexts.count) texts in \(String(format: "%.2f", processingTime))s (avg: \(String(format: "%.3f", avgTime))s/text)")

            return embeddings
        } catch {
            logger.error("Batch embedding failed: \(error.localizedDescription)")
            throw EmbeddingError.embeddingFailed(error.localizedDescription)
        }
    }

    /// Unload the model to free memory
    /// After calling this, loadModel() must be called again before embedding
    public func unloadModel() {
        embedder = nil
        modelLoaded = false
        logger.info("NLContextualEmbedder model unloaded")
    }
}
