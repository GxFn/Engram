import EngineKit
import Foundation

/// First-launch model lineup — the Qwen3 family per the 2026-07-06 requirement
/// decision. IDs follow mlx-community naming; refresh against the latest
/// quantizations when M1 implementation lands.
public enum ModelCatalog {
    public static let qwen3_4B_4bit = ModelIdentity(
        id: "mlx-community/Qwen3-4B-4bit",
        family: "qwen3",
        quantization: "4bit",
        contextLength: 32_768,
        estimatedMemoryBytes: 2_400_000_000
    )

    /// Degrade target when the 4B model cannot fit (memory pressure, older device).
    public static let qwen3_1_7B_4bit = ModelIdentity(
        id: "mlx-community/Qwen3-1.7B-4bit",
        family: "qwen3",
        quantization: "4bit",
        contextLength: 32_768,
        estimatedMemoryBytes: 1_100_000_000
    )

    public static let qwen3Embedding_0_6B = ModelIdentity(
        id: "mlx-community/Qwen3-Embedding-0.6B-4bit",
        family: "qwen3-embedding",
        quantization: "4bit",
        contextLength: 32_768,
        estimatedMemoryBytes: 650_000_000
    )

    public static let qwen3VL_4B_4bit = ModelIdentity(
        id: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
        family: "qwen3-vl",
        quantization: "4bit",
        contextLength: 32_768,
        estimatedMemoryBytes: 2_500_000_000
    )

    public static let launchLineup: [ModelIdentity] = [
        qwen3_4B_4bit,
        qwen3_1_7B_4bit,
        qwen3Embedding_0_6B,
        qwen3VL_4B_4bit,
    ]
}
