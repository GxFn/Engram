import CloudVision
import Foundation
import StoryboardCore
import Testing
import VideoUnderstanding

@Test func unavailableDeepCapabilityDegradesHonestlyToCloudStandard() {
    let profile = CloudProviderProfile(
        id: "fixture", displayName: "Fixture Cloud",
        capabilityURL: URL(string: "https://example.invalid/capabilities")!,
        jobURL: URL(string: "https://example.invalid/jobs")!,
        declaredCapabilities: [.frameUnderstanding]
    )
    let probe = CloudCapabilityProbeResult(
        providerID: profile.id,
        available: [.frameUnderstanding],
        unavailable: [.fullVideo, .cloudASR, .asyncJobs],
        checkedAt: Date(timeIntervalSince1970: 1),
        evidence: "HTTP 404: capability endpoint unavailable"
    )

    let decision = CloudModeResolver.resolve(
        requested: .cloudDeep,
        profile: profile,
        probe: probe,
        consent: MediaUploadConsent(allowsUpload: true, maximumBytes: 10_000)
    )

    #expect(decision.effectiveMode == .cloudStandard)
    #expect(decision.mediaUploadAllowed == false)
    #expect(decision.degradationNote?.contains("fullVideo") == true)
    #expect(decision.probeEvidence == probe.evidence)
}

@Test func timelineAlignerMapsCloudEvidenceWithoutChangingShotGraph() throws {
    let graph = try cloudGraph()
    let observations = [
        CloudTimelineObservation(
            id: "cloud-1", startSeconds: 0.8, endSeconds: 1.3,
            text: "人物进入", confidence: 0.42, kind: .visual
        ),
        CloudTimelineObservation(
            id: "asr-1", startSeconds: 2.2, endSeconds: 2.8,
            text: "一句台词", confidence: 0.95, kind: .transcript
        ),
    ]

    let alignment = CloudTimelineAligner.align(observations, to: graph, reviewThreshold: 0.6)

    #expect(alignment.authoritativeGraph == graph)
    #expect(alignment.items[0].shotIDs == [ShotID(rawValue: "S001")])
    #expect(alignment.items[1].shotIDs == [ShotID(rawValue: "S002")])
    #expect(alignment.shotsNeedingReview == [ShotID(rawValue: "S001")])
    #expect(CloudRefinementPlanner.plan(alignment).shotIDs == [ShotID(rawValue: "S001")])
}

@Test func cloudErrorSanitizerRemovesCredentialsAndLocalPaths() {
    let raw = "Bearer sk-secret-123 at /Users/alice/private/video.mp4?token=abc"
    let sanitized = CloudErrorSanitizer.sanitize(raw)

    #expect(!sanitized.contains("sk-secret"))
    #expect(!sanitized.contains("/Users/alice"))
    #expect(!sanitized.contains("token=abc"))
}

private func cloudGraph() throws -> ShotGraph {
    let asset = VideoAssetDescriptor(
        sourceID: "cloud", durationSeconds: 4, nominalFrameRate: 30, frameCount: 120,
        width: 720, height: 1280, timescale: 600, codec: "h264", hasAudio: true,
        fileSizeBytes: 10, fingerprint: SourceFingerprint(value: "cloud")
    )
    return try ShotGraph(asset: asset, shots: [
        ShotSegment(
            id: ShotID(rawValue: "S001"),
            timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 2),
            frameRange: FrameRange(startFrame: 0, endFrameExclusive: 60),
            transitionIn: .start, transitionOut: .cut, boundaryConfidence: 1,
            detectorEvidenceIDs: ["detector:S001"]
        ),
        ShotSegment(
            id: ShotID(rawValue: "S002"),
            timeRange: MediaTimeRange(startSeconds: 2, endSeconds: 4),
            frameRange: FrameRange(startFrame: 60, endFrameExclusive: 120),
            transitionIn: .cut, transitionOut: .end, boundaryConfidence: 1,
            detectorEvidenceIDs: ["detector:S002"]
        ),
    ])
}
