@testable import CloudVision
import Foundation
import StoryboardCore
import Testing
import VideoUnderstanding

@Test func explicitArkFrameOnlyProfileDegradesDeepHonestly() {
    let chatURL = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!
    let profile = CloudProviderProfile(
        id: "volcengine-ark-frame",
        displayName: "Volcengine Ark frame chat",
        capabilityURL: chatURL,
        jobURL: chatURL,
        declaredCapabilities: [.frameUnderstanding]
    )
    let probe = CloudCapabilityProbeResult(
        providerID: profile.id,
        available: [.frameUnderstanding],
        unavailable: [.fullVideo, .cloudASR, .asyncJobs],
        checkedAt: Date(timeIntervalSince1970: 1),
        evidence: "official Ark frame chat succeeded; direct video not proven"
    )

    let decision = CloudModeResolver.resolve(
        requested: .cloudDeep,
        profile: profile,
        probe: probe,
        consent: MediaUploadConsent(allowsUpload: true, maximumBytes: 50_000_000)
    )

    #expect(decision.effectiveMode == .cloudStandard)
    #expect(decision.mediaUploadAllowed == false)
    #expect(decision.degradationNote?.contains("fullVideo") == true)
}

@Test func providerTransportArtifactsCarryIdempotencyUsageAndCancellationContract() throws {
    let request = CloudVideoJobRequest(
        sourceID: "clip-1",
        sourceFingerprint: "sha256-fixture",
        byteCount: 3,
        requestedCapabilities: [.fullVideo, .cloudASR]
    )
    let requestObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    )
    let receipt = CloudVideoJobReceipt(
        jobID: "job-1",
        state: .completed,
        observations: [],
        sanitizedError: nil
    )
    let receiptObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any]
    )

    #expect(requestObject["idempotencyKey"] as? String == "sha256-fixture")
    #expect(receiptObject["usage"] != nil)
    #expect(CloudCapability(rawValue: "jobCancellation") != nil)
}

@Test func asyncASRSubmitUsesOfficialHeadersAndBodyInsteadOfGenericVideoJobsSchema() async throws {
    let session = makeContractSession { request in
        let response = try #require(request.url).absoluteString
        #expect(response == "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Api-Request-Id") == "sha256-fixture")
        #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.bigasr.auc")
        let body = try requestBodyData(request)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["audio"] != nil)
        #expect(object["mediaBase64"] == nil)
        return try contractResponse(for: request, state: "queued")
    }
    let profile = providerFixture(
        jobURL: URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit")!
    )
    let client = URLSessionCloudVideoJobClient(profile: profile, session: session)

    _ = try await client.submit(
        CloudVideoJobRequest(
            sourceID: "clip-1",
            sourceFingerprint: "sha256-fixture",
            byteCount: 3,
            requestedCapabilities: [.cloudASR, .asyncJobs]
        ),
        media: Data([1, 2, 3]),
        consent: MediaUploadConsent(allowsUpload: true, maximumBytes: 3),
        bearerToken: "speech-access-key"
    )
}

@Test func asyncASRStatusUsesOfficialQueryRequestInsteadOfAppendingJobID() async throws {
    let session = makeContractSession { request in
        #expect(request.url?.absoluteString == "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Api-Request-Id") == "task-123")
        return try contractResponse(for: request, state: "completed")
    }
    let profile = providerFixture(
        jobURL: URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query")!
    )
    let client = URLSessionCloudVideoJobClient(profile: profile, session: session)

    _ = try await client.status(jobID: "task-123", bearerToken: "speech-access-key")
}

@Test func providerHTTPErrorIsSanitizedAtTheTransportBoundary() async throws {
    let session = makeContractSession { request in
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = Data(
            "Bearer sk-secret at /Users/alice/private/video.mp4?token=raw-token".utf8
        )
        return (response, body)
    }
    let client = URLSessionCloudVideoJobClient(
        profile: providerFixture(jobURL: URL(string: "https://provider.invalid/jobs")!),
        session: session
    )

    do {
        _ = try await client.status(jobID: "job-1", bearerToken: "top-secret")
        Issue.record("Expected provider transport failure")
    } catch let CloudVideoJobError.invalidResponse(message) {
        #expect(!message.contains("sk-secret"))
        #expect(!message.contains("/Users/alice"))
        #expect(!message.contains("raw-token"))
        #expect(message.contains("[REDACTED]"))
    }
}

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

private func providerFixture(jobURL: URL) -> CloudProviderProfile {
    CloudProviderProfile(
        id: "volcengine-contract-fixture",
        displayName: "Volcengine contract fixture",
        capabilityURL: URL(string: "https://provider.invalid/capabilities")!,
        jobURL: jobURL,
        declaredCapabilities: [.fullVideo, .cloudASR, .asyncJobs]
    )
}

private func makeContractSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    ContractURLProtocol.handler = handler
    configuration.protocolClasses = [ContractURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func contractResponse(
    for request: URLRequest,
    state: String
) throws -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    let data = try JSONSerialization.data(withJSONObject: [
        "jobID": "job-1",
        "state": state,
        "observations": [],
        "sanitizedError": NSNull(),
    ])
    return (response, data)
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
