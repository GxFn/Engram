import EngineKit

/// Apple Foundation Models engine — lands in M3 as the second LLMEngine
/// implementation. The milestone's architecture claim is that adding this
/// backend touches zero feature-layer code; keeping the stub compiling against
/// the protocol from day one makes that claim checkable in CI.
public actor FMEngine: LLMEngine {
    public nonisolated let descriptor = EngineDescriptor(
        id: "foundation-models",
        displayName: "Apple Foundation Models",
        kind: .foundationModels
    )

    public init() {}

    public func load(_ model: ModelIdentity) async throws {
        throw EngineError.notImplemented("M3")
    }

    public func unload() async {}

    public func generate(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: EngineError.notImplemented("M3"))
        }
    }

    public func countTokens(in text: String) async throws -> Int {
        throw EngineError.notImplemented("M3")
    }
}
