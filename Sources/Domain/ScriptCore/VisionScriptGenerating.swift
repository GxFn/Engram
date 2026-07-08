import EngineKit
import Foundation
import VideoUnderstanding

/// Backend-neutral seam: turn one prompt plus keyframes into raw model text.
///
/// Both the on-device MLX Qwen3-VL runtime and cloud VLM APIs implement this, so the
/// script composer, prompt building, and JSON decoding are identical regardless of which
/// backend produced the text. This is what makes the vision backend user-selectable
/// (on-device ↔ cloud) without touching the composition pipeline.
public protocol VisionScriptGenerating: Sendable {
    func generate(
        prompt: String,
        frames: [SampledFrame],
        config: GenerationConfig
    ) async throws -> String
}
