import EngineKit
import MLXLLM
import MLXLMCommon

/// MLX-backed inference engine — the M1 workhorse.
/// The full loading/generation path lands in W1.3; W1.1 wires the package and
/// keeps unsupported simulator behavior explicit.
public actor MLXEngine: LLMEngine {
    public nonisolated let descriptor = EngineDescriptor(
        id: "mlx",
        displayName: "MLX",
        kind: .mlx
    )

    public init() {}

    public func load(_ model: ModelIdentity) async throws {
        #if os(iOS) && targetEnvironment(simulator)
        throw EngineError.notImplemented("simulator unsupported - use a device or macOS")
        #else
        _ = model
        throw EngineError.notImplemented("M1 W1.3")
        #endif
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
