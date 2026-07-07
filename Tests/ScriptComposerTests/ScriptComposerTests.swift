import EngineKit
import Foundation
import QwenVLRuntime
import ScriptCore
import Testing
import VideoUnderstanding
@testable import ScriptComposer

@Test func qwenComposerMapsStrictJSONToScriptAndPromptShape() async throws {
    let generator = RecordingVLMGenerator(responses: [
        """
        {
          "title": "厨房开场",
          "summary": "主角在厨房介绍一道菜。",
          "shots": [
            {
              "start": 0.0,
              "end": 2.4,
              "narration": "今天我们做一道快手菜。",
              "visualDescription": "主角站在厨房台面前，手边放着食材。",
              "pacingNote": "温和开场"
            },
            {
              "startSeconds": 2.4,
              "endSeconds": 5.0,
              "narration": "先把蔬菜切好。",
              "visualDescription": "近景展示刀切蔬菜的动作。",
              "pacingNote": "切到手部特写"
            }
          ]
        }
        """
    ])
    let composer = Qwen3VLScriptComposer(
        generator: generator,
        configuration: .init(maxKeyframeCount: 4),
        dateProvider: { Date(timeIntervalSince1970: 10) },
        idProvider: { "script-fixed" }
    )

    let script = try await composer.compose(
        sourceID: "video-1",
        transcript: fixtureTranscript,
        keyframes: [
            jpegFrame(timestamp: 4),
            jpegFrame(timestamp: 1),
            jpegFrame(timestamp: 2),
        ]
    )

    #expect(script.id == "script-fixed")
    #expect(script.videoSourceID == "video-1")
    #expect(script.title == "厨房开场")
    #expect(script.summary == "主角在厨房介绍一道菜。")
    #expect(script.createdAt == Date(timeIntervalSince1970: 10))
    #expect(script.shots == [
        StoryboardShot(
            index: 0,
            startSeconds: 0,
            endSeconds: 2.4,
            narration: "今天我们做一道快手菜。",
            visualDescription: "主角站在厨房台面前，手边放着食材。",
            pacingNote: "温和开场"
        ),
        StoryboardShot(
            index: 1,
            startSeconds: 2.4,
            endSeconds: 5,
            narration: "先把蔬菜切好。",
            visualDescription: "近景展示刀切蔬菜的动作。",
            pacingNote: "切到手部特写"
        ),
    ])

    let requests = await generator.requests
    #expect(requests.count == 1)
    #expect(requests[0].frames.map(\.timestampSeconds) == [1, 2, 4])
    #expect(requests[0].prompt.contains("\"visualDescription\""))
    #expect(requests[0].prompt.contains("[0.0s-2.4s] 今天我们做一道快手菜。"))
    #expect(requests[0].prompt.contains("frame_1: timestamp=1.0s"))
    #expect(ScriptRendering.indexableText(script).contains("画面: 近景展示刀切蔬菜的动作。"))
}

@Test func qwenComposerRetriesMalformedJSONThenUsesSecondOutput() async throws {
    let generator = RecordingVLMGenerator(responses: [
        "不是 JSON",
        """
        {
          "title": "重试成功",
          "summary": "第二次输出合法。",
          "shots": [
            {
              "start": 0,
              "end": 3,
              "narration": "重试台词",
              "visualDescription": "重试后描述画面。",
              "pacingNote": "重试节奏"
            }
          ]
        }
        """,
    ])
    let composer = Qwen3VLScriptComposer(
        generator: generator,
        configuration: .init(maxKeyframeCount: 4),
        dateProvider: { Date(timeIntervalSince1970: 20) },
        idProvider: { "script-retry" }
    )

    let script = try await composer.compose(
        sourceID: "video-retry",
        transcript: fixtureTranscript,
        keyframes: [jpegFrame(timestamp: 1)]
    )

    #expect(script.title == "重试成功")
    #expect(script.shots.count == 1)
    #expect(script.shots[0].visualDescription == "重试后描述画面。")

    let requests = await generator.requests
    #expect(requests.count == 2)
    #expect(requests[1].prompt.contains("上一次输出不是合法 JSON"))
}

@Test func qwenComposerFallsBackDeterministicallyAfterMalformedJSONRetryFails() async throws {
    let generator = RecordingVLMGenerator(responses: ["bad", "still bad"])
    let composer = Qwen3VLScriptComposer(
        generator: generator,
        configuration: .init(maxKeyframeCount: 4),
        dateProvider: { Date(timeIntervalSince1970: 30) },
        idProvider: { "script-fallback" }
    )

    let script = try await composer.compose(
        sourceID: "video-bad-json",
        transcript: fixtureTranscript,
        keyframes: [jpegFrame(timestamp: 1)]
    )

    #expect(script.id == "script-fallback")
    #expect(script.title == "转写兜底剧本")
    #expect(script.shots.count == 1)
    #expect(script.shots[0].startSeconds == 0)
    #expect(script.shots[0].endSeconds == 5)
    #expect(script.shots[0].narration?.contains("今天我们做一道快手菜。") == true)
    #expect(script.shots[0].visualDescription.contains("兜底分镜"))
    #expect(await generator.requests.count == 2)
}

@Test func qwenComposerUsesTextFallbackWhenVisionRuntimeFails() async throws {
    let visionGenerator = RecordingVLMGenerator(error: VideoUnderstandingError.visionUnavailable("device memory"))
    let textGenerator = RecordingTextGenerator(responses: [
        """
        {
          "title": "转写版脚本",
          "summary": "只根据转写生成。",
          "shots": [
            {
              "start": 0,
              "end": 5,
              "narration": "今天我们做一道快手菜。先把蔬菜切好。",
              "visualDescription": "",
              "pacingNote": "转写-only"
            }
          ]
        }
        """
    ])
    let textFallback = TextScriptComposer(
        generator: textGenerator,
        dateProvider: { Date(timeIntervalSince1970: 40) },
        idProvider: { "script-text" }
    )
    let composer = Qwen3VLScriptComposer(
        generator: visionGenerator,
        configuration: .init(maxKeyframeCount: 4),
        textFallback: textFallback
    )

    let script = try await composer.compose(
        sourceID: "video-vlm-failed",
        transcript: fixtureTranscript,
        keyframes: [jpegFrame(timestamp: 1)]
    )

    #expect(script.id == "script-text")
    #expect(script.title == "转写版脚本")
    #expect(script.shots[0].visualDescription == "")
    #expect(await visionGenerator.requests.count == 1)
    #expect(await textGenerator.requests.count == 1)
    #expect((await textGenerator.requests[0]).prompt.contains("visualDescription 留空"))
}

@Test func composerLimitsFramesAndHandlesEmptyInputsWithoutThrowing() async throws {
    let generator = RecordingVLMGenerator(responses: [
        """
        {
          "title": "四帧脚本",
          "summary": "只接收四帧。",
          "shots": [
            {
              "start": 0,
              "end": 1,
              "narration": "",
              "visualDescription": "根据前四帧生成。",
              "pacingNote": ""
            }
          ]
        }
        """
    ])
    let composer = Qwen3VLScriptComposer(generator: generator, configuration: .init(maxKeyframeCount: 4))

    _ = try await composer.compose(
        sourceID: "video-limit",
        transcript: [],
        keyframes: (0 ..< 7).map { jpegFrame(timestamp: Double($0)) }
    )

    #expect((await generator.requests[0]).frames.count == 4)

    let emptyGenerator = RecordingVLMGenerator(responses: [])
    let emptyComposer = Qwen3VLScriptComposer(
        generator: emptyGenerator,
        configuration: .init(maxKeyframeCount: 4),
        dateProvider: { Date(timeIntervalSince1970: 50) },
        idProvider: { "script-empty" }
    )

    let emptyScript = try await emptyComposer.compose(sourceID: "video-empty", transcript: [], keyframes: [])

    #expect(emptyScript.id == "script-empty")
    #expect(emptyScript.title == "转写-only 剧本")
    #expect(emptyScript.shots.count == 1)
    #expect(emptyScript.shots[0].startSeconds == 0)
    #expect(emptyScript.shots[0].endSeconds == 1)
    #expect(await emptyGenerator.requests.isEmpty)
}

@Test func textScriptComposerLoadsConfiguredModelBeforeGeneration() async throws {
    let engine = LoadingScriptEngine(response: """
    {
      "title": "模型润色脚本",
      "summary": "文本模型根据转写生成结构化脚本。",
      "shots": [
        {
          "start": 0,
          "end": 5,
          "narration": "今天我们做一道快手菜。",
          "visualDescription": "",
          "pacingNote": "自然剪辑"
        }
      ]
    }
    """)
    let model = ModelIdentity(
        id: "test/qwen3-text",
        family: "qwen3",
        quantization: "4bit",
        contextLength: 32_768,
        estimatedMemoryBytes: 1_000
    )
    let composer = TextScriptComposer(
        engine: engine,
        model: model,
        dateProvider: { Date(timeIntervalSince1970: 60) },
        idProvider: { "script-loaded-text" }
    )

    let script = try await composer.compose(sourceID: "video-text", transcript: fixtureTranscript)

    #expect(script.id == "script-loaded-text")
    #expect(script.title == "模型润色脚本")
    #expect(await engine.loadedModelIDs() == [model.id])
    #expect(await engine.generateCallCount() == 1)
}

private actor RecordingVLMGenerator: QwenVLGenerating {
    struct Request: Sendable {
        let prompt: String
        let frames: [SampledFrame]
        let config: GenerationConfig
    }

    private var responses: [String]
    private let error: Error?
    private(set) var requests: [Request] = []

    init(responses: [String] = [], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    func generate(
        prompt: String,
        frames: [SampledFrame],
        config: GenerationConfig
    ) async throws -> String {
        requests.append(Request(prompt: prompt, frames: frames, config: config))
        if let error {
            throw error
        }
        return responses.isEmpty ? "{}" : responses.removeFirst()
    }
}

private actor RecordingTextGenerator: ScriptTextGenerating {
    struct Request: Sendable {
        let prompt: String
        let config: GenerationConfig
    }

    private var responses: [String]
    private let error: Error?
    private(set) var requests: [Request] = []

    init(responses: [String] = [], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    func generateScriptText(prompt: String, config: GenerationConfig) async throws -> String {
        requests.append(Request(prompt: prompt, config: config))
        if let error {
            throw error
        }
        return responses.isEmpty ? "{}" : responses.removeFirst()
    }
}

private actor LoadingScriptEngine: LLMEngine {
    nonisolated let descriptor = EngineDescriptor(id: "loading-script-engine", displayName: "Loading Script Engine", kind: .mlx)

    private let response: String
    private var loadedIDs: [String] = []
    private var generationCount = 0

    init(response: String) {
        self.response = response
    }

    func load(_ model: ModelIdentity) async throws {
        loadedIDs.append(model.id)
    }

    func unload() async {}

    func generate(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        generationCount += 1
        let loaded = !loadedIDs.isEmpty
        let response = self.response

        return AsyncThrowingStream { continuation in
            guard loaded else {
                continuation.finish(throwing: EngineError.modelNotLoaded)
                return
            }

            continuation.yield(.token(response))
            continuation.yield(.finished(.stop, GenerationMetrics(
                firstTokenLatencyMillis: nil,
                tokensPerSecond: nil,
                outputTokenCount: 1
            )))
            continuation.finish()
        }
    }

    func countTokens(in text: String) async throws -> Int {
        text.count
    }

    func loadedModelIDs() -> [String] {
        loadedIDs
    }

    func generateCallCount() -> Int {
        generationCount
    }
}

private let fixtureTranscript = [
    TranscriptSegment(startSeconds: 0, endSeconds: 2.4, text: "今天我们做一道快手菜。"),
    TranscriptSegment(startSeconds: 2.4, endSeconds: 5, text: "先把蔬菜切好。"),
]

private func jpegFrame(timestamp: Double) -> SampledFrame {
    SampledFrame(timestampSeconds: timestamp, jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]))
}
