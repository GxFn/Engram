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
          "visualElements": ["厨房", "主角", "食材", "手部特写"],
          "hookStructure": {
            "openingHook": "今天我们做一道快手菜。",
            "retentionDevices": ["先给成品期待", "用手部特写保持节奏"],
            "payoff": "把复杂菜变成快手菜",
            "callToAction": "收藏后照着做",
            "whyItWorks": "开场直接给出低门槛收益，画面和转写共同强化实用价值。"
          },
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
    #expect(script.visualElements == ["厨房", "主角", "食材", "手部特写"])
    #expect(script.hookStructure == HookAnalysis(
        openingHook: "今天我们做一道快手菜。",
        retentionDevices: ["先给成品期待", "用手部特写保持节奏"],
        payoff: "把复杂菜变成快手菜",
        callToAction: "收藏后照着做",
        whyItWorks: "开场直接给出低门槛收益，画面和转写共同强化实用价值。"
    ))
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
    let visionPrompt = requests[0].prompt
    #expect(visionPrompt.contains("\"visualDescription\""))
    #expect(visionPrompt.contains("\"visualElements\""))
    #expect(visionPrompt.contains("\"hookStructure\""))
    #expect(visionPrompt.contains("\"openingHook\""))
    #expect(visionPrompt.contains("\"retentionDevices\""))
    #expect(visionPrompt.contains("\"whyItWorks\""))
    #expect(visionPrompt.contains("3-8"))
    #expect(visionPrompt.contains("前 3 秒钩子"))
    #expect(visionPrompt.contains("为什么可能爆"))
    #expect(visionPrompt.contains("关键视觉元素"))
    #expect(visionPrompt.contains("[0.0s-2.4s] 今天我们做一道快手菜。"))
    #expect(visionPrompt.contains("frame_1: timestamp=1.0s"))
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
    #expect(script.hookStructure == nil)
    #expect(script.visualElements == [])

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
    #expect(script.hookStructure == nil)
    #expect(script.visualElements == [])
    #expect(await generator.requests.count == 2)
}

@Test func qwenComposerUsesTextFallbackWhenVisionRuntimeFails() async throws {
    let visionGenerator = RecordingVLMGenerator(error: VideoUnderstandingError.visionUnavailable("device memory"))
    let textGenerator = RecordingTextGenerator(responses: [
        """
        {
          "title": "转写版脚本",
          "summary": "只根据转写生成。",
          "visualElements": [],
          "hookStructure": {
            "openingHook": "今天我们做一道快手菜。",
            "retentionDevices": ["承诺快手结果"],
            "payoff": "节省做菜时间",
            "callToAction": null,
            "whyItWorks": "转写开场直接说明收益，即使没有画面也能判断脚本钩子。"
          },
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
    #expect(script.visualElements == [])
    #expect(script.hookStructure == HookAnalysis(
        openingHook: "今天我们做一道快手菜。",
        retentionDevices: ["承诺快手结果"],
        payoff: "节省做菜时间",
        callToAction: nil,
        whyItWorks: "转写开场直接说明收益，即使没有画面也能判断脚本钩子。"
    ))
    #expect(await visionGenerator.requests.count == 1)
    let textRequests = await textGenerator.requests
    #expect(textRequests.count == 1)
    let textPrompt = textRequests[0].prompt
    #expect(textPrompt.contains("visualDescription 留空"))
    #expect(textPrompt.contains("\"visualElements\": []"))
    #expect(textPrompt.contains("\"hookStructure\""))
    #expect(textPrompt.contains("\"openingHook\""))
    #expect(textPrompt.contains("\"retentionDevices\""))
    #expect(textPrompt.contains("\"whyItWorks\""))
    #expect(textPrompt.contains("visualElements 可以为空数组"))
    #expect(textPrompt.contains("基于转写文本谨慎生成"))
    #expect(textPrompt.contains("为什么可能爆"))
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

@Test func scriptComposerLegacyJSONWithoutHookAndVisualFieldsDefaultsToEmptyDomainFields() async throws {
    let generator = RecordingVLMGenerator(responses: [
        """
        {
          "title": "旧格式脚本",
          "summary": "旧 composer 输出没有新增字段。",
          "shots": [
            {
              "start": 0,
              "end": 2,
              "narration": "旧格式台词",
              "visualDescription": "旧格式画面",
              "pacingNote": "旧格式节奏"
            }
          ]
        }
        """
    ])
    let composer = Qwen3VLScriptComposer(
        generator: generator,
        configuration: .init(maxKeyframeCount: 4),
        dateProvider: { Date(timeIntervalSince1970: 70) },
        idProvider: { "script-legacy-json" }
    )

    let script = try await composer.compose(
        sourceID: "video-legacy-json",
        transcript: fixtureTranscript,
        keyframes: [jpegFrame(timestamp: 1)]
    )

    #expect(script.id == "script-legacy-json")
    #expect(script.title == "旧格式脚本")
    #expect(script.hookStructure == nil)
    #expect(script.visualElements == [])
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
