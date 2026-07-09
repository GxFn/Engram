import ClipCore
import EngramLogging
import Foundation
import ScriptCore
import VideoUnderstanding

public protocol VideoAnalyzing: Sendable {
    func analyze(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> Script
}

public struct VideoAnalyzer: VideoAnalyzing {
    private let transcriber: any Transcriber
    private let sampler: any FrameSampler
    private let visionComposer: any VisionScriptComposing
    private let textComposer: any TextScriptComposing
    private let corrector: (any TranscriptCorrecting)?
    private let recognizer: (any FrameTextRecognizing)?
    private let maxFrames: Int
    private let deep: DeepModeConfiguration?

    /// Segmented map-reduce ("deep") analysis config. Long videos are split into time windows,
    /// each analyzed with its own frames + transcript slice, then merged — so every part of a
    /// long video gets real visual attention instead of ~6 frames across the whole thing.
    public struct DeepModeConfiguration: Sendable {
        public var thresholdSeconds: Double     // videos longer than this use deep mode
        public var segmentWindowSeconds: Double // target seconds per segment
        public var maxSegments: Int
        public var framesPerSegment: Int

        public init(
            thresholdSeconds: Double = 150,
            segmentWindowSeconds: Double = 150,
            maxSegments: Int = 8,
            framesPerSegment: Int = 6
        ) {
            self.thresholdSeconds = max(1, thresholdSeconds)
            self.segmentWindowSeconds = max(1, segmentWindowSeconds)
            self.maxSegments = max(2, maxSegments)
            self.framesPerSegment = max(1, framesPerSegment)
        }
    }

    /// Hard ceiling for frames in one VLM call — bounds cloud token cost and on-device memory.
    static let frameBudgetCeiling = 16

    public init(
        transcriber: any Transcriber,
        sampler: any FrameSampler,
        visionComposer: any VisionScriptComposing,
        textComposer: any TextScriptComposing,
        corrector: (any TranscriptCorrecting)? = nil,
        recognizer: (any FrameTextRecognizing)? = nil,
        maxFrames: Int = 6,
        deep: DeepModeConfiguration? = DeepModeConfiguration()
    ) {
        self.transcriber = transcriber
        self.sampler = sampler
        self.visionComposer = visionComposer
        self.textComposer = textComposer
        self.corrector = corrector
        self.recognizer = recognizer
        self.maxFrames = max(0, min(maxFrames, Self.frameBudgetCeiling))
        self.deep = deep
    }

    /// Frames scale with duration (~1 per 10s) so a fast-cut 2-minute video isn't summarized from a
    /// fixed 6 snapshots — most 分镜 would have no frame in their window, forcing the VLM to fabricate
    /// 画面. `base` (the configured maxFrames) is the floor; the ceiling bounds cost. Deep mode covers
    /// anything longer than its threshold with per-segment budgets instead.
    static func frameBudget(base: Int, durationSeconds: Double) -> Int {
        guard base > 0 else { return 0 }
        guard durationSeconds.isFinite, durationSeconds > 0 else { return base }
        let byDuration = Int((durationSeconds / 10).rounded(.up))
        return max(base, min(frameBudgetCeiling, byDuration))
    }

    public func analyze(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> Script {
        await onStage(.transcribing)
        // Transcription is NOT a hard gate: a silent/music video with burned-in 字幕 can still yield
        // a good vision-only breakdown from frames + OCR. Only cancellation propagates.
        let transcript = try await resilientTranscript(source)

        await onStage(.scripting)

        // Deterministic OCR of burned-in 字幕/on-screen text (independent of the VLM) so captions are
        // captured in both 云端 and 本地 modes; empty when no recognizer or nothing detected.
        let onScreenText = await recognizeOnScreenText(source)

        let duration = videoDuration(source: source, transcript: transcript, onScreenText: onScreenText)
        if let deep, duration > deep.thresholdSeconds,
           let merged = try await analyzeDeep(source, transcript: transcript, onScreenText: onScreenText, duration: duration, config: deep) {
            return merged
        }

        let keyframes = try await sampledFrames(
            for: source,
            maxFrames: Self.frameBudget(base: maxFrames, durationSeconds: duration)
        )

        // Nothing extractable at all (no speech, no frames, no on-screen text): fail cleanly rather
        // than compose an empty-input script that would masquerade as a breakdown.
        if transcript.isEmpty, keyframes.isEmpty, onScreenText.isEmpty {
            throw VideoUnderstandingError.unreadableAsset(
                "无法转写、无可用关键帧、也未识别到画面文字——没有可拆解的内容。"
            )
        }

        do {
            return try await visionComposer.compose(
                sourceID: source.id,
                transcript: transcript,
                keyframes: keyframes,
                onScreenText: onScreenText
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.clip.warning(
                "Vision script composition failed for \(source.id, privacy: .public); falling back to transcript-only: \(String(describing: error), privacy: .public)"
            )
            return try await textComposer.compose(sourceID: source.id, transcript: transcript)
        }
    }

    /// Transcribes + corrects, degrading to an empty transcript on any non-cancellation failure
    /// (no audio track, unsupported locale, speech assets still downloading, pre-iOS26 runtime):
    /// the breakdown then proceeds vision-only from frames + OCR instead of hard-failing a whole
    /// class of 爆款 (music/no-speech videos with burned-in 字幕).
    private func resilientTranscript(_ source: VideoSource) async throws -> [TranscriptSegment] {
        do {
            let raw = try await transcriber.transcribe(source)
            // Clean the raw ASR (typos/punctuation/run-ons) before scripting so 台词 is readable and
            // the 爆点/剧本 analysis reasons over accurate text; falls back to raw on any failure.
            return try await correctedTranscript(raw)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.clip.warning(
                "Transcription failed for \(source.id, privacy: .public); continuing vision-only: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private func correctedTranscript(_ raw: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        guard let corrector else {
            return raw
        }
        return try await corrector.correct(raw)
    }

    private func recognizeOnScreenText(_ source: VideoSource) async -> [FrameText] {
        guard let recognizer else { return [] }
        return await recognizer.recognizeText(in: source)
    }

    // MARK: - Deep (segmented map-reduce) path

    private func analyzeDeep(
        _ source: VideoSource,
        transcript: [TranscriptSegment],
        onScreenText: [FrameText],
        duration: Double,
        config: DeepModeConfiguration
    ) async throws -> Script? {
        let segmentCount = min(
            config.maxSegments,
            max(2, Int((duration / config.segmentWindowSeconds).rounded(.up)))
        )
        let totalFrames = segmentCount * config.framesPerSegment
        let allFrames = try await sampledFrames(for: source, maxFrames: totalFrames)

        var partials: [Script] = []
        for index in 0..<segmentCount {
            let start = duration * Double(index) / Double(segmentCount)
            let end = duration * Double(index + 1) / Double(segmentCount)
            let segmentFrames = allFrames.filter { $0.timestampSeconds >= start && $0.timestampSeconds < end }
            let segmentTranscript = transcript.filter { $0.startSeconds >= start && $0.startSeconds < end }
            let segmentText = onScreenText.filter { $0.timestampSeconds >= start && $0.timestampSeconds < end }
            guard !segmentFrames.isEmpty || !segmentTranscript.isEmpty else { continue }

            do {
                let partial = try await visionComposer.compose(
                    sourceID: "\(source.id)#seg\(index)",
                    transcript: segmentTranscript,
                    keyframes: segmentFrames,
                    onScreenText: segmentText
                )
                partials.append(partial)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.clip.warning(
                    "Deep segment \(index) composition failed for \(source.id, privacy: .public); skipping segment: \(String(describing: error), privacy: .public)"
                )
            }
        }

        return DeepScriptMerge.merge(partials, sourceID: source.id)
    }

    private func videoDuration(
        source: VideoSource,
        transcript: [TranscriptSegment],
        onScreenText: [FrameText] = []
    ) -> Double {
        if let duration = source.durationSeconds, duration.isFinite, duration > 0 {
            return duration
        }
        // OCR timestamps extend the proxy for silent videos (no transcript to infer duration from),
        // so deep mode and the frame budget still scale for a music video with burned-in 字幕.
        return max(
            transcript.map(\.endSeconds).filter(\.isFinite).max() ?? 0,
            onScreenText.map(\.timestampSeconds).filter(\.isFinite).max() ?? 0
        )
    }

    private func sampledFrames(for source: VideoSource, maxFrames: Int) async throws -> [SampledFrame] {
        guard maxFrames > 0 else { return [] }
        do {
            return try await sampler.sampleKeyFrames(source, maxFrames: maxFrames)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.clip.warning(
                "Video frame sampling failed for \(source.id, privacy: .public); continuing with transcript-only frame set: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }
}
