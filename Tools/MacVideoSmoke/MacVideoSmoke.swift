import EngineKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import FrameVision
import MLXEngine
import ModelStore
import QwenVLRuntime
import ScriptComposer
import ScriptCore
import SpeechTranscription
import VideoUnderstanding

@main
struct MacVideoSmoke {
    static func main() async {
#if canImport(Darwin)
        setbuf(stdout, nil)
#endif
        do {
            let options = try SmokeOptions.parse(CommandLine.arguments)
            let report = try await MacVideoSmokeRunner(options: options).run()
            print(report.markdown)
            if let outputURL = options.outputURL {
                try report.writeJSON(to: outputURL)
                print("\nWrote JSON report: \(outputURL.path)")
            }
        } catch let error as SmokeUsageError {
            fputs("\(error.message)\n\n\(SmokeOptions.usage)\n", stderr)
            Foundation.exit(2)
        } catch {
            fputs("MacVideoSmoke failed: \(String(describing: error))\n", stderr)
            Foundation.exit(1)
        }
    }
}

private struct MacVideoSmokeRunner {
    let options: SmokeOptions

    func run() async throws -> SmokeReport {
        let videoURL = options.videoURL
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw SmokeUsageError("Video file does not exist: \(videoURL.path)")
        }

        let source = VideoSource(
            id: videoURL.deletingPathExtension().lastPathComponent,
            localFileURL: videoURL,
            importedAt: Date()
        )
        let modelStore = ModelStore(modelsDirectory: options.modelRootURL)

        print("Video: \(videoURL.path)")
        print("Locale: \(options.locale.identifier)")
        print("Model root: \(modelStore.modelDirectoryRoot.path)")

        let transcript = try await transcribe(source)
        let frames = try await sampleFrames(source)
        let composition = try await composeScript(
            source: source,
            transcript: transcript,
            frames: frames,
            modelStore: modelStore
        )

        return SmokeReport(
            videoPath: videoURL.path,
            localeIdentifier: options.locale.identifier,
            modelRootPath: modelStore.modelDirectoryRoot.path,
            mode: options.modeName,
            transcript: transcript,
            frameSummaries: frames.map {
                SmokeFrame(timestampSeconds: $0.timestampSeconds, jpegBytes: $0.jpegData.count)
            },
            script: composition.script,
            indexableText: ScriptRendering.indexableText(composition.script),
            rawVLMOutputs: composition.rawVLMOutputs
        )
    }

    private func transcribe(_ source: VideoSource) async throws -> [TranscriptSegment] {
        print("Transcribing...")
        let transcriber = SpeechAnalyzerTranscriber(locale: options.locale)
        let transcript = try await transcriber.transcribe(source)
        print("Transcript segments: \(transcript.count)")
        return transcript
    }

    private func sampleFrames(_ source: VideoSource) async throws -> [SampledFrame] {
        guard options.maxFrames > 0 else {
            return []
        }

        print("Sampling \(options.maxFrames) frame(s)...")
        let sampler = AVFoundationFrameSampler()
        let frames = try await sampler.sampleKeyFrames(source, maxFrames: options.maxFrames)
        print("Frames: \(frames.count)")
        return frames
    }

    private func composeScript(
        source: VideoSource,
        transcript: [TranscriptSegment],
        frames: [SampledFrame],
        modelStore: ModelStore
    ) async throws -> SmokeComposition {
        if options.useVLM {
            let vlmModel = ModelCatalog.qwen3VL_4B_4bit
            if options.downloadVLMModel {
                try await ensureDownloaded(vlmModel, in: modelStore)
            }

            let generator = RecordingQwenVLGenerator(
                base: QwenVLContainer(modelDirectoryRoot: modelStore.modelDirectoryRoot)
            )
            if let directVLMPrompt = options.directVLMPrompt {
                print("Generating direct Qwen3-VL probe...")
                let output = try await generator.generate(
                    prompt: directVLMPrompt,
                    frames: frames,
                    config: options.generationConfig
                )
                return SmokeComposition(
                    script: diagnosticScript(sourceID: source.id, frames: frames, output: output),
                    rawVLMOutputs: await generator.outputs()
                )
            }

            print("Composing script with Qwen3-VL...")
            let composer = Qwen3VLScriptComposer(
                generator: generator,
                configuration: ScriptComposerConfiguration(
                    maxKeyframeCount: options.maxFrames,
                    generationConfig: options.generationConfig
                )
            )
            let script = try await composer.compose(
                sourceID: source.id,
                transcript: transcript,
                keyframes: frames,
                onScreenText: []
            )
            return SmokeComposition(script: script, rawVLMOutputs: await generator.outputs())
        }

        let textModel = ModelCatalog.qwen3_1_7B_4bit
        if options.downloadTextModel {
            try await ensureDownloaded(textModel, in: modelStore)
        }

        let engine = MLXEngine(modelDirectoryRoot: modelStore.modelDirectoryRoot)
        let textComposer = TextScriptComposer(
            engine: engine,
            model: textModel,
            configuration: ScriptComposerConfiguration(
                maxKeyframeCount: 0,
                generationConfig: options.generationConfig
            )
        )

        print("Composing script with Qwen3 text model...")
        let script = try await textComposer.compose(sourceID: source.id, transcript: transcript)
        return SmokeComposition(script: script, rawVLMOutputs: nil)
    }

    private func diagnosticScript(sourceID: String, frames: [SampledFrame], output: String) -> Script {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = trimmed.isEmpty ? "Qwen3-VL returned an empty response." : trimmed
        let frameStart = frames.first?.timestampSeconds ?? 0
        return Script(
            id: UUID().uuidString,
            videoSourceID: sourceID,
            title: "Qwen3-VL 直接探针",
            summary: String(description.prefix(240)),
            shots: [
                StoryboardShot(
                    index: 0,
                    startSeconds: max(0, frameStart),
                    endSeconds: max(1, frameStart + 1),
                    narration: nil,
                    visualDescription: description,
                    pacingNote: "直接 VLM 输出探针，不作为最终剧本。"
                )
            ],
            createdAt: Date()
        )
    }

    private func ensureDownloaded(_ model: ModelIdentity, in modelStore: ModelStore) async throws {
        if try await modelStore.isDownloaded(model) {
            print("Model already downloaded: \(model.id)")
            return
        }

        print("Downloading model: \(model.id)")
        _ = try await modelStore.download(model) { state in
            if let fraction = state.fractionCompleted {
                let percent = Int((fraction * 100).rounded())
                print("Download \(model.id): \(percent)%")
            } else {
                print("Download \(model.id): \(state.completedBytes) bytes")
            }
        }
    }
}

private struct SmokeComposition {
    let script: Script
    let rawVLMOutputs: [String]?
}

private actor RecordingQwenVLGenerator: QwenVLGenerating {
    private let base: any QwenVLGenerating
    private var recordedOutputs: [String] = []

    init(base: any QwenVLGenerating) {
        self.base = base
    }

    func generate(
        prompt: String,
        frames: [SampledFrame],
        config: GenerationConfig
    ) async throws -> String {
        let output = try await base.generate(prompt: prompt, frames: frames, config: config)
        recordedOutputs.append(output)
        return output
    }

    func outputs() -> [String] {
        recordedOutputs
    }
}

private struct SmokeOptions {
    var videoURL: URL
    var locale: Locale = Locale(identifier: "zh_CN")
    var modelRootURL: URL?
    var outputURL: URL?
    var downloadTextModel = false
    var useVLM = false
    var downloadVLMModel = false
    var directVLMPrompt: String?
    var maxFrames = 4
    var generationConfig = GenerationConfig(temperature: 0.2, topP: 0.9, maxTokens: 1_500)

    var modeName: String {
        if directVLMPrompt != nil {
            return "qwen3-vl-direct"
        }
        return useVLM ? "qwen3-vl" : "text"
    }

    static let usage = """
    Usage:
      swift run MacVideoSmoke <video-path> [options]

    Options:
      --locale <id>             Speech locale, default zh_CN.
      --model-root <path>       ModelStore root, default Application Support/Models.
      --output <path>           Write JSON report.
      --download-text-model     Download Qwen3-1.7B-4bit if missing.
      --vlm                     Try Qwen3-VL script composition.
      --download-vlm-model      Download Qwen3-VL-4B-4bit if missing.
      --direct-vlm-prompt <text> Run one direct Qwen3-VL prompt against sampled frames.
      --max-frames <n>          Frames for sampling/VLM, default 4.
      --max-tokens <n>          Generation max tokens, default 1500.
    """

    static func parse(_ arguments: [String]) throws -> SmokeOptions {
        var args = Array(arguments.dropFirst())
        guard !args.isEmpty else {
            throw SmokeUsageError("Missing <video-path>.")
        }

        let videoPath = args.removeFirst()
        var options = SmokeOptions(videoURL: URL(fileURLWithPath: videoPath).standardizedFileURL)

        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--locale":
                options.locale = Locale(identifier: try nextValue(after: arg, from: &args))
            case "--model-root":
                options.modelRootURL = URL(fileURLWithPath: try nextValue(after: arg, from: &args)).standardizedFileURL
            case "--output":
                options.outputURL = URL(fileURLWithPath: try nextValue(after: arg, from: &args)).standardizedFileURL
            case "--download-text-model":
                options.downloadTextModel = true
            case "--vlm":
                options.useVLM = true
            case "--download-vlm-model":
                options.useVLM = true
                options.downloadVLMModel = true
            case "--direct-vlm-prompt":
                options.useVLM = true
                options.directVLMPrompt = try nextValue(after: arg, from: &args)
            case "--max-frames":
                options.maxFrames = try positiveInt(nextValue(after: arg, from: &args), name: arg)
            case "--max-tokens":
                let maxTokens = try positiveInt(nextValue(after: arg, from: &args), name: arg)
                options.generationConfig.maxTokens = maxTokens
            default:
                throw SmokeUsageError("Unknown argument: \(arg)")
            }
        }

        return options
    }

    private static func nextValue(after option: String, from args: inout [String]) throws -> String {
        guard !args.isEmpty else {
            throw SmokeUsageError("Missing value after \(option).")
        }

        return args.removeFirst()
    }

    private static func positiveInt(_ value: String, name: String) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else {
            throw SmokeUsageError("\(name) must be a positive integer.")
        }

        return parsed
    }
}

private struct SmokeReport: Encodable {
    let videoPath: String
    let localeIdentifier: String
    let modelRootPath: String
    let mode: String
    let transcript: [TranscriptSegment]
    let frameSummaries: [SmokeFrame]
    let script: Script
    let indexableText: String
    let rawVLMOutputs: [String]?

    var markdown: String {
        """
        # Mac Video Smoke

        - video: \(videoPath)
        - locale: \(localeIdentifier)
        - mode: \(mode)
        - transcript segments: \(transcript.count)
        - sampled frames: \(frameSummaries.count)

        ## Transcript
        \(transcriptPreview)

        ## Script
        title: \(script.title)
        summary: \(script.summary)

        \(indexableText)
        \(rawVLMPreview)
        """
    }

    private var transcriptPreview: String {
        let lines = transcript.prefix(12).map { segment in
            "[\(format(segment.startSeconds))s-\(format(segment.endSeconds))s] \(segment.text)"
        }
        return lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
    }

    private var rawVLMPreview: String {
        guard let firstOutput = rawVLMOutputs?.first else {
            return ""
        }

        return """

        ## Raw VLM Output Preview
        \(String(firstOutput.prefix(4_000)))
        """
    }

    func writeJSON(to outputURL: URL) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: outputURL, options: .atomic)
    }
}

private struct SmokeFrame: Encodable {
    let timestampSeconds: Double
    let jpegBytes: Int
}

private struct SmokeUsageError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private func format(_ seconds: Double) -> String {
    String(format: "%.1f", seconds.isFinite ? seconds : 0)
}
