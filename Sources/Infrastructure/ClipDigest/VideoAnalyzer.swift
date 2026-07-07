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
    private let maxFrames: Int

    public init(
        transcriber: any Transcriber,
        sampler: any FrameSampler,
        visionComposer: any VisionScriptComposing,
        textComposer: any TextScriptComposing,
        maxFrames: Int = 6
    ) {
        self.transcriber = transcriber
        self.sampler = sampler
        self.visionComposer = visionComposer
        self.textComposer = textComposer
        self.maxFrames = max(0, min(maxFrames, 8))
    }

    public func analyze(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> Script {
        await onStage(.transcribing)
        let transcript = try await transcriber.transcribe(source)

        await onStage(.scripting)
        let keyframes = try await sampledFrames(for: source)

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

    private func sampledFrames(for source: VideoSource) async throws -> [SampledFrame] {
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
