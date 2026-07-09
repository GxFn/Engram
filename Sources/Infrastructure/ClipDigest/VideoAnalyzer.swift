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
            thresholdSeconds: Double = 300,
            segmentWindowSeconds: Double = 150,
            maxSegments: Int = 8,
            framesPerSegment: Int = 4
        ) {
            self.thresholdSeconds = max(1, thresholdSeconds)
            self.segmentWindowSeconds = max(1, segmentWindowSeconds)
            self.maxSegments = max(2, maxSegments)
            self.framesPerSegment = max(1, framesPerSegment)
        }
    }

    public init(
        transcriber: any Transcriber,
        sampler: any FrameSampler,
        visionComposer: any VisionScriptComposing,
        textComposer: any TextScriptComposing,
        corrector: (any TranscriptCorrecting)? = nil,
        maxFrames: Int = 6,
        deep: DeepModeConfiguration? = DeepModeConfiguration()
    ) {
        self.transcriber = transcriber
        self.sampler = sampler
        self.visionComposer = visionComposer
        self.textComposer = textComposer
        self.corrector = corrector
        self.maxFrames = max(0, min(maxFrames, 8))
        self.deep = deep
    }

    public func analyze(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> Script {
        await onStage(.transcribing)
        let rawTranscript = try await transcriber.transcribe(source)
        // Clean the raw ASR (typos/punctuation/run-ons) before scripting so 台词 is readable and the
        // 爆点/剧本 analysis reasons over accurate text; falls back to raw on any failure.
        let transcript = try await correctedTranscript(rawTranscript)

        await onStage(.scripting)

        let duration = videoDuration(source: source, transcript: transcript)
        if let deep, duration > deep.thresholdSeconds,
           let merged = try await analyzeDeep(source, transcript: transcript, duration: duration, config: deep) {
            return merged
        }

        let keyframes = try await sampledFrames(for: source, maxFrames: maxFrames)

        do {
            return try await visionComposer.compose(
                sourceID: source.id,
                transcript: transcript,
                keyframes: keyframes
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

    private func correctedTranscript(_ raw: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        guard let corrector else {
            return raw
        }
        return try await corrector.correct(raw)
    }

    // MARK: - Deep (segmented map-reduce) path

    private func analyzeDeep(
        _ source: VideoSource,
        transcript: [TranscriptSegment],
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
            guard !segmentFrames.isEmpty || !segmentTranscript.isEmpty else { continue }

            do {
                let partial = try await visionComposer.compose(
                    sourceID: "\(source.id)#seg\(index)",
                    transcript: segmentTranscript,
                    keyframes: segmentFrames
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

    private func videoDuration(source: VideoSource, transcript: [TranscriptSegment]) -> Double {
        if let duration = source.durationSeconds, duration.isFinite, duration > 0 {
            return duration
        }
        return transcript.map(\.endSeconds).filter(\.isFinite).max() ?? 0
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
