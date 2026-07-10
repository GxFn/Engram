import EngineKit
import EngramLogging
import Foundation
import VideoUnderstanding

/// Cleans raw ASR transcripts with the text LLM before scripting/analysis: fixes obvious
/// homophones/typos, adds punctuation, and smooths run-ons — so 台词 is readable and the
/// downstream 爆点/剧本 analysis reasons over accurate text. Never invents content, preserves each
/// segment's timing, and falls back to the raw transcript on any failure (kept cheap: one short
/// text call per video). Character/celebrity names come from the vision path (on-screen captions),
/// not audio, so correction deliberately does not guess names.
public actor LLMTranscriptCorrector: TranscriptCorrecting {
    private let generator: any ScriptTextGenerating
    private let configuration: GenerationConfig

    public init(
        generator: any ScriptTextGenerating,
        configuration: GenerationConfig = GenerationConfig(temperature: 0.2, topP: 0.9, maxTokens: 1_200)
    ) {
        self.generator = generator
        self.configuration = configuration
    }

    public init(
        engine: any LLMEngine,
        model: ModelIdentity? = nil,
        configuration: GenerationConfig = GenerationConfig(temperature: 0.2, topP: 0.9, maxTokens: 1_200)
    ) {
        self.init(
            generator: LLMTextScriptGenerator(
                engine: engine,
                model: model,
                systemPrompt: "你是严谨的中文校对助手，只做转写纠错，只输出要求的 JSON。"
            ),
            configuration: configuration
        )
    }

    public func correct(_ segments: [TranscriptSegment], onScreenText: [FrameText]) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else {
            return segments
        }

        do {
            let output = try await generator.generateScriptText(
                prompt: Self.prompt(for: segments, onScreenText: onScreenText),
                config: configuration
            )
            return Self.apply(output, to: segments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.scriptComposer.warning(
                "Transcript correction failed; keeping raw transcript: \(String(describing: error), privacy: .public)"
            )
            return segments
        }
    }

    static func prompt(for segments: [TranscriptSegment], onScreenText: [FrameText] = []) -> String {
        let lines = segments.enumerated()
            .map { index, segment in "[\(index)] [\(format(segment.startSeconds))s] \(segment.text)" }
            .joined(separator: "\n")

        // The burned-in 字幕 are the creator's own captions — the authoritative wording for domain
        // terms the ASR mishears (电竞战队/选手/黑话). Fed as a reference so 掮客→陪玩-class errors and
        // garbled fragments can be recovered instead of poisoning every downstream analysis.
        let captionBlock: String
        if onScreenText.isEmpty {
            captionBlock = ""
        } else {
            let captions = onScreenText
                .sorted { $0.timestampSeconds < $1.timestampSeconds }
                .map { text in "[\(format(text.timestampSeconds))s] \(text.lines.joined(separator: " / "))" }
                .joined(separator: "\n")
            captionBlock = """


            画面字幕（OCR 识别的烧录字幕，按时间。这是作者自己压的字幕，用词比语音识别可靠，但可能夹带昵称/水印）：
            \(captions)
            """
        }

        return """
        以下是语音识别的原始转写，可能有错别字、同音字、缺标点、断句混乱，专有名词（电竞战队、选手、行业黑话等）常被听成同音错词。请在【不改变原意、不翻译】的前提下：
        - 修正明显错别字与同音字，补合适标点，把断句顺成通顺中文；
        - 对照相近时间的画面字幕纠正被听错的词，以字幕用词为准；
        - 某段语音明显破碎或缺字、而对应时间的字幕里有完整句子时，按字幕恢复该段原文；
        - 不得添加语音和字幕里都不存在的内容，不要把字幕里的昵称/水印当台词。
        保持段的数量与编号完全不变。只输出一个 JSON 数组，元素为 {"i": 段编号, "text": "修正后的该段文本"}，不要 Markdown，不要解释。

        转写：
        \(lines)
        \(captionBlock)
        """
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.1f", seconds.isFinite ? seconds : 0)
    }

    static func apply(_ output: String, to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard let data = extractJSONArray(from: output),
              let items = try? JSONDecoder().decode([CorrectedSegment].self, from: data)
        else {
            return segments
        }

        var correctedByIndex: [Int: String] = [:]
        for item in items {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.index >= 0, !text.isEmpty {
                correctedByIndex[item.index] = text
            }
        }
        guard !correctedByIndex.isEmpty else {
            return segments
        }

        return segments.enumerated().map { index, segment in
            guard let corrected = correctedByIndex[index] else {
                return segment
            }
            return TranscriptSegment(
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                text: corrected
            )
        }
    }

    private static func extractJSONArray(from output: String) -> Data? {
        JSONEnvelope.slice(output, open: "[", close: "]")
    }
}

private struct CorrectedSegment: Decodable {
    let index: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case index = "i"
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int.self, forKey: .index) {
            index = value
        } else if let string = try? container.decode(String.self, forKey: .index), let value = Int(string) {
            index = value
        } else {
            index = -1
        }
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}
