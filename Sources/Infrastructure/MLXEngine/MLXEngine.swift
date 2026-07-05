import EngineKit

/// MLX-backed inference engine — the M1 workhorse.
/// This target deliberately carries no mlx-swift dependency yet: the package
/// must build clean everywhere until the engine actually lands; the dependency
/// arrives in the same commit as the implementation.
public actor MLXEngine: LLMEngine {
    public nonisolated let descriptor = EngineDescriptor(
        id: "mlx",
        displayName: "MLX",
        kind: .mlx
    )

    public init() {}

    public func load(_ model: ModelIdentity) async throws {
        throw EngineError.notImplemented("M1")
    }

    public func unload() async {}

    public func generate(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: EngineError.notImplemented("M1"))
        }
    }

    public func countTokens(in text: String) async throws -> Int {
        throw EngineError.notImplemented("M1")
    }
}
