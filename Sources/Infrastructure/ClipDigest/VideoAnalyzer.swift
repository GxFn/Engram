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
        // OCR runs FIRST: the burned-in 字幕 are the creator's own captions, and they feed the ASR
        // correction below — domain terms the ASR mishears (电竞战队/选手/黑话, e.g. 陪玩→掮客) are
        // recovered from what's written on screen. Also captured for shot attachment either way.
        let onScreenText = await recognizeOnScreenText(source)

        // Transcription is NOT a hard gate: a silent/music video with burned-in 字幕 can still yield
        // a good vision-only breakdown from frames + OCR. Only cancellation propagates.
        let transcript = try await resilientTranscript(source, onScreenText: onScreenText)

        await onStage(.scripting)

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
        } catch let error as VideoUnderstandingError {
            if case .visionConfigurationInvalid = error {
                // Don't swallow a hard config error into a transcript fallback here either — this
                // second swallow is what used to turn a 401 into a green "Indexed" transcript dump.
                throw error
            }
            return try await degradedTextFallback(source: source, transcript: transcript, error: error)
        } catch {
            return try await degradedTextFallback(source: source, transcript: transcript, error: error)
        }
    }

    /// Transcript-only fallback for a failed vision pass, explicitly marked degraded so the result
    /// can't masquerade as a full 拆解.
    private func degradedTextFallback(
        source: VideoSource,
        transcript: [TranscriptSegment],
        error: Error
    ) async throws -> Script {
        Log.clip.warning(
            "Vision script composition failed for \(source.id, privacy: .public); falling back to transcript-only: \(String(describing: error), privacy: .public)"
        )
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let script = try await textComposer.compose(sourceID: source.id, transcript: transcript)
        return script.withDegradationNote(script.degradationNote ?? "画面理解失败，已转写-only：\(detail)")
    }

    /// Transcribes + corrects, degrading to an empty transcript on any non-cancellation failure
    /// (no audio track, unsupported locale, speech assets still downloading, pre-iOS26 runtime):
    /// the breakdown then proceeds vision-only from frames + OCR instead of hard-failing a whole
    /// class of 爆款 (music/no-speech videos with burned-in 字幕).
    private func resilientTranscript(
        _ source: VideoSource,
        onScreenText: [FrameText]
    ) async throws -> [TranscriptSegment] {
        do {
            let raw = try await transcriber.transcribe(source)
            // Clean the raw ASR (typos/punctuation/run-ons) before scripting, using the burned-in
            // 字幕 as the reference for mis-heard domain terms — so 台词 is accurate and the 爆点/剧本
            // analysis reasons over real words; falls back to raw on any failure.
            return try await correctedTranscript(raw, onScreenText: onScreenText)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.clip.warning(
                "Transcription failed for \(source.id, privacy: .public); continuing vision-only: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private func correctedTranscript(
        _ raw: [TranscriptSegment],
        onScreenText: [FrameText]
    ) async throws -> [TranscriptSegment] {
        guard let corrector else {
            return raw
        }
        return try await corrector.correct(raw, onScreenText: onScreenText)
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
        var failedSegments = 0
        for index in 0..<segmentCount {
            let start = duration * Double(index) / Double(segmentCount)
            let end = duration * Double(index + 1) / Double(segmentCount)
            // The last window is unbounded above: the duration proxy can undershoot the real asset
            // length, and a half-open `< end` there dropped trailing frames/字幕 (end-cards, CTAs).
            let isLast = index == segmentCount - 1
            let inWindow: (Double) -> Bool = { time in time >= start && (isLast || time < end) }
            let segmentFrames = allFrames.filter { inWindow($0.timestampSeconds) }
            let segmentTranscript = transcript.filter { inWindow($0.startSeconds) }
            let segmentText = onScreenText.filter { inWindow($0.timestampSeconds) }
            // A silent window with only burned-in 字幕 still deserves a pass (OCR counts as content).
            guard !segmentFrames.isEmpty || !segmentTranscript.isEmpty || !segmentText.isEmpty else { continue }

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
            } catch let error as VideoUnderstandingError where isConfigurationFailure(error) {
                // A hard config error fails every segment identically — abort the whole deep pass
                // so the digest records one retryable failure instead of N placeholder segments.
                throw error
            } catch {
                failedSegments += 1
                Log.clip.warning(
                    "Deep segment \(index) composition failed for \(source.id, privacy: .public); keeping transcript/字幕 placeholder: \(String(describing: error), privacy: .public)"
                )
                // Never silently drop 1/N of the video: keep the window's 台词+字幕 as a placeholder
                // shot with REAL window timestamps (so merge ordering and the title anchor hold).
                partials.append(Self.segmentPlaceholder(
                    sourceID: source.id,
                    start: start,
                    end: end,
                    transcript: segmentTranscript,
                    onScreenText: segmentText
                ))
            }
        }

        guard var merged = DeepScriptMerge.merge(partials, sourceID: source.id) else { return nil }
        if failedSegments > 0 {
            // Partial coverage must be visible, not a clean-looking success.
            let note = "部分片段画面理解失败（\(failedSegments)/\(segmentCount) 段仅保留转写与字幕）。"
            merged = Script(
                id: merged.id,
                videoSourceID: merged.videoSourceID,
                title: merged.title,
                summary: "\(note)\n\(merged.summary)",
                shots: merged.shots,
                createdAt: merged.createdAt,
                hookStructure: merged.hookStructure,
                visualElements: merged.visualElements,
                characters: merged.characters,
                degradationNote: note
            )
        }
        return merged
    }

    private func isConfigurationFailure(_ error: VideoUnderstandingError) -> Bool {
        if case .visionConfigurationInvalid = error { return true }
        return false
    }

    /// Transcript/字幕-only stand-in for a segment whose vision pass failed. Title/summary stay empty
    /// so the placeholder can't hijack the merged title, and the shot carries the real window bounds.
    private static func segmentPlaceholder(
        sourceID: String,
        start: Double,
        end: Double,
        transcript: [TranscriptSegment],
        onScreenText: [FrameText]
    ) -> Script {
        let narration = transcript
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var captions: [String] = []
        for text in onScreenText.sorted(by: { $0.timestampSeconds < $1.timestampSeconds }) {
            for line in text.lines where !captions.contains(line) {
                captions.append(line)
            }
        }
        let shot = StoryboardShot(
            index: 0,
            startSeconds: start,
            endSeconds: end,
            narration: narration.isEmpty ? nil : narration,
            visualDescription: "本段（\(Int(start))–\(Int(end))s）画面理解失败，仅保留转写与字幕。",
            pacingNote: nil,
            onScreenText: captions
        )
        return Script(
            id: "\(sourceID)#fallback-\(Int(start))",
            videoSourceID: sourceID,
            title: "",
            summary: "",
            shots: [shot],
            createdAt: Date()
        )
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
