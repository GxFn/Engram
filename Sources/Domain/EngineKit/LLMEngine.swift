/// The single seam every inference backend implements. Features and AppShell
/// program against this protocol only; adding a new backend (M3 FMEngine)
/// must require zero feature-layer changes.
public protocol LLMEngine: Actor {
    nonisolated var descriptor: EngineDescriptor { get }

    /// Loads model weights into memory. Engines own their memory-pressure
    /// response: on system pressure they unload or refuse with `.outOfMemory`.
    func load(_ model: ModelIdentity) async throws

    func unload() async

    /// Streams tokens as they are produced; the stream must end with a
    /// `.finished` event carrying the generation metrics.
    func generate(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error>

    /// Token count under this engine's tokenizer — context-budget arithmetic
    /// must use the engine's own tokenizer, never a generic approximation.
    func countTokens(in text: String) async throws -> Int
}
