import EngineKit
import MLXEngine
import Testing

@Test func mlxLoadFailsExplicitlyOnIOSSimulator() async throws {
    #if os(iOS) && targetEnvironment(simulator)
    let engine = MLXEngine()
    let model = ModelIdentity(
        id: "mlx-community/Qwen3-4B-4bit",
        family: "Qwen3",
        quantization: "4bit",
        contextLength: 32768,
        estimatedMemoryBytes: 2_300_000_000
    )

    do {
        try await engine.load(model)
        Issue.record("Expected iOS simulator MLX load to throw")
    } catch EngineError.notImplemented(let message) {
        #expect(message == "simulator unsupported - use a device or macOS")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #endif
}
