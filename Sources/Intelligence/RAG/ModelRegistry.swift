import Foundation

/// Static registry of available AI models
/// All download logic is in AIService - this is just model metadata
@available(macOS 14.0, *)
public struct ModelRegistry {

    // MARK: - Types

    /// Model tier based on size/capability
    public enum Tier: String, Sendable, CaseIterable {
        case tiny = "Tiny"       // < 1GB
        case light = "Light"     // 1-2GB
        case standard = "Standard" // 2-4GB
        case pro = "Pro"         // > 4GB
    }

    /// Information about a model
    public struct ModelInfo: Identifiable, Sendable, Equatable {
        public let id: String           // HuggingFace ID (e.g., "mlx-community/gemma-2-2b-it-4bit")
        public let displayName: String  // Human-readable name
        public let description: String  // Short description
        public let sizeGB: Double       // Approximate download size in GB
        public let memoryGB: Double     // Approximate memory requirement in GB
        public let isDefault: Bool      // Whether this is the default model
        public let tier: Tier

        public init(
            id: String,
            displayName: String,
            description: String,
            sizeGB: Double,
            memoryGB: Double,
            isDefault: Bool = false,
            tier: Tier
        ) {
            self.id = id
            self.displayName = displayName
            self.description = description
            self.sizeGB = sizeGB
            self.memoryGB = memoryGB
            self.isDefault = isDefault
            self.tier = tier
        }

        /// Size formatted as string
        public var sizeString: String {
            if sizeGB < 1.0 {
                return String(format: "%.0f MB", sizeGB * 1024)
            }
            return String(format: "%.1f GB", sizeGB)
        }
    }

    // MARK: - Model Registry

    /// All available models
    /// Order matters - first model is shown first in UI
    public static let availableModels: [ModelInfo] = [
        // Tiny tier - for low memory systems
        ModelInfo(
            id: "mlx-community/SmolLM2-360M-Instruct-4bit",
            displayName: "SmolLM 360M",
            description: "Ultra-lightweight model. Works on any Mac.",
            sizeGB: 0.3,
            memoryGB: 0.5,
            isDefault: false,
            tier: .tiny
        ),

        // Light tier - good default
        ModelInfo(
            id: "mlx-community/gemma-2-2b-it-4bit",
            displayName: "Gemma 2 2B",
            description: "Google's efficient 2B model. Fast and capable.",
            sizeGB: 1.6,
            memoryGB: 2.0,
            isDefault: true,  // DEFAULT MODEL
            tier: .light
        ),

        // Standard tier
        ModelInfo(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B",
            description: "Meta's latest small model. Good quality.",
            sizeGB: 2.0,
            memoryGB: 2.5,
            isDefault: false,
            tier: .standard
        ),

        // Pro tier
        ModelInfo(
            id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            displayName: "Mistral 7B",
            description: "Powerful 7B model. Best quality, needs more RAM.",
            sizeGB: 4.0,
            memoryGB: 5.0,
            isDefault: false,
            tier: .pro
        ),
    ]

    /// Default model
    public static var defaultModel: ModelInfo {
        availableModels.first { $0.isDefault } ?? availableModels[0]
    }

    /// Get model info by ID
    public static func model(for id: String) -> ModelInfo? {
        availableModels.first { $0.id == id }
    }

    /// Estimate memory requirement for a model ID
    /// Uses pattern matching on the model name
    public static func estimatedMemoryGB(for modelId: String) -> Double {
        // First check registry
        if let model = model(for: modelId) {
            return model.memoryGB
        }

        // Fall back to pattern matching
        let lower = modelId.lowercased()

        if lower.contains("360m") || lower.contains("500m") {
            return 0.5
        } else if lower.contains("1b") || lower.contains("1.7b") {
            return 1.0
        } else if lower.contains("2b") {
            return 2.0
        } else if lower.contains("3b") {
            return 2.5
        } else if lower.contains("4b") {
            return 3.0
        } else if lower.contains("7b") || lower.contains("8b") {
            return 5.0
        } else if lower.contains("13b") || lower.contains("14b") {
            return 10.0
        }

        return 2.0 // Default assumption
    }

    /// Suggest a smaller model that fits in available memory
    public static func suggestSmallerModel(availableGB: Double) -> ModelInfo? {
        // Find largest model that fits
        return availableModels
            .filter { $0.memoryGB <= availableGB }
            .sorted { $0.memoryGB > $1.memoryGB }
            .first
    }

    /// Models grouped by tier
    public static var modelsByTier: [Tier: [ModelInfo]] {
        Dictionary(grouping: availableModels, by: { $0.tier })
    }
}
