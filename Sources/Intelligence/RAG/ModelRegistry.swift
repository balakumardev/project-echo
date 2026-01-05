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

    /// All available models (Updated January 2025)
    /// Focused on small, efficient models suitable for background apps
    /// Order matters - first model is shown first in UI
    public static let availableModels: [ModelInfo] = [
        // Tiny tier - ultra-lightweight for any Mac
        ModelInfo(
            id: "mlx-community/Qwen3-0.6B-8bit",
            displayName: "Qwen3 0.6B",
            description: "Ultra-light. Works on any Mac, very fast.",
            sizeGB: 0.6,
            memoryGB: 1.0,
            isDefault: false,
            tier: .tiny
        ),

        // Light tier - good balance of quality and speed
        ModelInfo(
            id: "mlx-community/Qwen3-1.7B-4bit",
            displayName: "Qwen3 1.7B",
            description: "Excellent quality for size. Great for most Macs.",
            sizeGB: 1.0,
            memoryGB: 1.5,
            isDefault: false,
            tier: .light
        ),
        // NOTE: Gemma 3 models removed - MLX has vocabulary size mismatch bug (262208 vs 262144)
        // See: https://github.com/huggingface/swift-transformers/issues/180
        // Re-add when MLX fixes Gemma 3 support

        ModelInfo(
            id: "mlx-community/gemma-2-2b-it-4bit",
            displayName: "Gemma 2 2B",
            description: "Google's efficient model. Good quality, fast inference.",
            sizeGB: 1.5,
            memoryGB: 2.0,
            isDefault: false,
            tier: .light
        ),

        // Standard tier - best balance for 8GB+ Macs
        ModelInfo(
            id: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen3 4B",
            description: "Best quality-to-size ratio. Recommended for most users.",
            sizeGB: 2.5,
            memoryGB: 3.0,
            isDefault: true,  // DEFAULT MODEL
            tier: .standard
        ),

        // Pro tier - for 16GB+ Macs
        ModelInfo(
            id: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen3 8B",
            description: "High quality. Best for 16GB+ Macs.",
            sizeGB: 4.5,
            memoryGB: 5.5,
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

        if lower.contains("0.6b") || lower.contains("270m") || lower.contains("360m") || lower.contains("500m") {
            return 1.0
        } else if lower.contains("1b") || lower.contains("1.7b") {
            return 1.5
        } else if lower.contains("2b") {
            return 2.0
        } else if lower.contains("3b") {
            return 2.5
        } else if lower.contains("4b") {
            return 3.5
        } else if lower.contains("7b") || lower.contains("8b") {
            return 5.5
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

    /// Recommend the best model for the user's system RAM
    /// Uses conservative memory limits since this app runs in the background
    /// - Parameter systemRAMGB: Total system RAM in GB
    /// - Returns: Recommended model, or default if RAM unknown
    public static func recommendedModel(forSystemRAMGB systemRAMGB: Double) -> ModelInfo {
        // Reserve memory for OS and other apps (this app runs in background)
        // Be conservative: use at most 30% of RAM for the model
        let availableForModel = systemRAMGB * 0.3

        // Find the best model that fits
        if let recommended = availableModels
            .filter({ $0.memoryGB <= availableForModel })
            .sorted(by: { $0.memoryGB > $1.memoryGB })  // Prefer larger (better quality)
            .first {
            return recommended
        }

        // Fallback to smallest model if nothing fits
        return availableModels.min(by: { $0.memoryGB < $1.memoryGB }) ?? defaultModel
    }

    /// Get total system RAM in GB
    public static var systemRAMGB: Double {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        return Double(physicalMemory) / 1_073_741_824  // Convert bytes to GB
    }

    /// Models grouped by tier
    public static var modelsByTier: [Tier: [ModelInfo]] {
        Dictionary(grouping: availableModels, by: { $0.tier })
    }
}
