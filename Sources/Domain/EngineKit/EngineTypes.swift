import Foundation

/// Identifies one inference backend (MLX, Foundation Models, …).
public struct EngineDescriptor: Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let kind: EngineKind

    public init(id: String, displayName: String, kind: EngineKind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

public enum EngineKind: String, Sendable, Codable, CaseIterable {
    case mlx
    case foundationModels
}

/// Identity + resource envelope of one downloadable model artifact.
/// `estimatedMemoryBytes` drives the device-capability check before download.
public struct ModelIdentity: Sendable, Hashable, Codable {
    public let id: String
    public let family: String
    public let quantization: String
    public let contextLength: Int
    public let estimatedMemoryBytes: Int64

    public init(
        id: String,
        family: String,
        quantization: String,
        contextLength: Int,
        estimatedMemoryBytes: Int64
    ) {
        self.id = id
        self.family = family
        self.quantization = quantization
        self.contextLength = contextLength
        self.estimatedMemoryBytes = estimatedMemoryBytes
    }
}

public struct ChatMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Codable, CaseIterable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct GenerationConfig: Sendable, Hashable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int

    public init(temperature: Double, topP: Double, maxTokens: Int) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    public static let `default` = GenerationConfig(temperature: 0.7, topP: 0.9, maxTokens: 1024)
}

public struct GenerationRequest: Sendable {
    public let messages: [ChatMessage]
    public let config: GenerationConfig

    public init(messages: [ChatMessage], config: GenerationConfig = .default) {
        self.messages = messages
        self.config = config
    }
}

public enum FinishReason: String, Sendable {
    case stop
    case length
    case cancelled
    case error
}

/// Per-generation measurements; the Bench feature aggregates these into runs.
public struct GenerationMetrics: Sendable {
    public let firstTokenLatencyMillis: Double?
    public let tokensPerSecond: Double?
    public let outputTokenCount: Int

    public init(firstTokenLatencyMillis: Double?, tokensPerSecond: Double?, outputTokenCount: Int) {
        self.firstTokenLatencyMillis = firstTokenLatencyMillis
        self.tokensPerSecond = tokensPerSecond
        self.outputTokenCount = outputTokenCount
    }
}

public enum GenerationEvent: Sendable {
    case token(String)
    case finished(FinishReason, GenerationMetrics)
}

public enum EngineError: Error, Sendable {
    /// Placeholder used by infrastructure stubs; the payload names the roadmap milestone.
    case notImplemented(String)
    case modelNotLoaded
    case outOfMemory
    case cancelled
}
