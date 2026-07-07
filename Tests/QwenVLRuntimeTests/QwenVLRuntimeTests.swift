import CoreGraphics
import EngineKit
import Foundation
import ImageIO
import ModelStore
import Testing
import UniformTypeIdentifiers
import VideoUnderstanding
@testable import QwenVLRuntime

@Test func describerMapsTimestampAlignedFrameDescriptions() async throws {
    let generator = RecordingGenerator(responses: [
        "  人物在厨房里切菜。\n忽略第二行",
        "街道上车辆缓慢驶过。",
    ])
    let describer = Qwen3VLDescriber(generator: generator)

    let descriptions = try await describer.describe([
        jpegFrame(timestamp: 2),
        jpegFrame(timestamp: 1),
    ])

    #expect(descriptions.map(\.timestampSeconds) == [1, 2])
    #expect(descriptions.map(\.description) == [
        "人物在厨房里切菜。",
        "街道上车辆缓慢驶过。",
    ])

    let prompts = await generator.prompts
    #expect(prompts.count == 2)
    #expect(prompts.allSatisfy { $0.contains("一句") && $0.contains("主体") && $0.contains("场景") })
}

@Test func describerLimitsFrameCountBeforeGenerating() async throws {
    let generator = RecordingGenerator(responses: ["第一帧。", "第二帧。"])
    let describer = Qwen3VLDescriber(generator: generator, maxFrameCount: 1)

    let descriptions = try await describer.describe([
        jpegFrame(timestamp: 3),
        jpegFrame(timestamp: 1),
    ])

    #expect(descriptions.map(\.timestampSeconds) == [1])
    #expect(await generator.callCount == 1)
}

@Test func describerRejectsInvalidFramePayloads() async {
    let describer = Qwen3VLDescriber(generator: RecordingGenerator(responses: []))

    await expectVisionUnavailable(containing: "empty JPEG") {
        _ = try await describer.describe([SampledFrame(timestampSeconds: 1, jpegData: Data())])
    }

    await expectVisionUnavailable(containing: "not JPEG") {
        _ = try await describer.describe([SampledFrame(timestampSeconds: 1, jpegData: Data([0x00, 0x01]))])
    }
}

@Test func describerMapsRuntimeFailuresToVisionUnavailable() async {
    let describer = Qwen3VLDescriber(generator: RecordingGenerator(error: FixtureError.runtimeFailed))

    await expectVisionUnavailable(containing: "runtimeFailed") {
        _ = try await describer.describe([jpegFrame(timestamp: 1)])
    }
}

@Test func containerAutoLoadsConfiguredRuntimeAndGenerates() async throws {
    let runtime = FakeRuntime(session: FakeSession(response: "画面中有人在写字。"))
    let container = QwenVLContainer(model: testModel, runtime: runtime)

    let output = try await container.generateDescription(
        for: jpegFrame(timestamp: 4),
        prompt: "描述画面",
        config: .init(temperature: 0.1, topP: 0.8, maxTokens: 12)
    )

    #expect(output == "画面中有人在写字。")
    #expect(await runtime.loadedModels == [testModel])
    #expect(await runtime.session?.requests.map(\.prompt) == ["描述画面"])

    await container.unload()
    #expect(await runtime.clearCacheCount == 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ENGRAM_SMOKE"] == "1"))
func qwenVLSmokeDescribesLocalFrameWhenEnabled() async throws {
    let root = ProcessInfo.processInfo.environment["ENGRAM_SMOKE_MODELS_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    let model = ModelIdentity(
        id: ProcessInfo.processInfo.environment["ENGRAM_SMOKE_VLM_MODEL_ID"]
            ?? ModelCatalog.qwen3VL_4B_4bit.id,
        family: "qwen3-vl",
        quantization: "4bit",
        contextLength: 32_768,
        estimatedMemoryBytes: ModelCatalog.qwen3VL_4B_4bit.estimatedMemoryBytes
    )
    let container = QwenVLContainer(model: model, modelDirectoryRoot: root)
    let describer = Qwen3VLDescriber(generator: container, maxFrameCount: 1)

    let descriptions = try await describer.describe([
        SampledFrame(timestampSeconds: 0, jpegData: try makeJPEGData())
    ])

    #expect(descriptions.count == 1)
    #expect(!descriptions[0].description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    await container.unload()
}

private actor RecordingGenerator: QwenVLFrameGenerating {
    private var responses: [String]
    private let error: Error?
    private(set) var prompts: [String] = []

    init(responses: [String] = [], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    var callCount: Int {
        prompts.count
    }

    func generateDescription(
        for frame: SampledFrame,
        prompt: String,
        config: GenerationConfig
    ) async throws -> String {
        prompts.append(prompt)
        if let error {
            throw error
        }
        return responses.isEmpty ? "默认描述。" : responses.removeFirst()
    }
}

private actor FakeRuntime: QwenVLRuntimeLoading {
    private let sessionToReturn: FakeSession
    private(set) var loadedModels: [ModelIdentity] = []
    private(set) var clearCacheCount = 0

    init(session: FakeSession) {
        self.sessionToReturn = session
    }

    var session: FakeSession? {
        sessionToReturn
    }

    func load(_ model: ModelIdentity) async throws -> any QwenVLSession {
        loadedModels.append(model)
        return sessionToReturn
    }

    func clearCache() async {
        clearCacheCount += 1
    }
}

private actor FakeSession: QwenVLSession {
    struct Request: Sendable {
        let prompt: String
        let timestamps: [Double]
        let maxTokens: Int
    }

    private let response: String
    private(set) var requests: [Request] = []

    init(response: String) {
        self.response = response
    }

    func generate(
        prompt: String,
        frames: [SampledFrame],
        config: GenerationConfig
    ) async throws -> String {
        requests.append(Request(
            prompt: prompt,
            timestamps: frames.map(\.timestampSeconds),
            maxTokens: config.maxTokens
        ))
        return response
    }
}

private let testModel = ModelIdentity(
    id: "test/qwen-vl",
    family: "qwen3-vl",
    quantization: "4bit",
    contextLength: 128,
    estimatedMemoryBytes: 10
)

private enum FixtureError: Error {
    case runtimeFailed
}

private func jpegFrame(timestamp: Double) -> SampledFrame {
    SampledFrame(timestampSeconds: timestamp, jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]))
}

private func makeJPEGData() throws -> Data {
    let width = 2
    let height = 2
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    let pixels = Data(repeating: 0xCC, count: width * height * bytesPerPixel)
    let provider = CGDataProvider(data: pixels as CFData)!
    let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!

    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw FixtureError.runtimeFailed
    }

    return data as Data
}

private func expectVisionUnavailable(
    containing expectedText: String,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected VideoUnderstandingError.visionUnavailable.")
    } catch let error as VideoUnderstandingError {
        guard case let .visionUnavailable(message) = error else {
            Issue.record("Expected visionUnavailable, got \(error).")
            return
        }

        #expect(message.contains(expectedText))
    } catch {
        Issue.record("Expected VideoUnderstandingError, got \(error).")
    }
}
