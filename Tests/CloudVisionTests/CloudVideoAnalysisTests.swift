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
    #expect(profile.transport == .frameChat)
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

@Test func providerArtifactsDecodeLegacyCheckpointsWithoutNewContractFields() throws {
    let request = try JSONDecoder().decode(
        CloudVideoJobRequest.self,
        from: Data(#"{"sourceID":"clip-1","sourceFingerprint":"legacy-fingerprint","byteCount":3,"requestedCapabilities":["cloudASR"]}"#.utf8)
    )
    let receipt = try JSONDecoder().decode(
        CloudVideoJobReceipt.self,
        from: Data(#"{"jobID":"legacy-job","state":"queued","observations":[],"sanitizedError":null}"#.utf8)
    )

    #expect(request.idempotencyKey == "legacy-fingerprint")
    #expect(receipt.usage == .zero)
    #expect(receipt.cancellationSupported == false)
}

@Suite(.serialized)
struct ProviderHTTPContractTests {
@Test func asyncASRSubmitUsesOfficialHeadersAndBodyInsteadOfGenericVideoJobsSchema() async throws {
    let session = makeContractSession { request in
        let response = try #require(request.url).absoluteString
        #expect(response == "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Api-App-Key") == "speech-app-id")
        #expect(request.value(forHTTPHeaderField: "X-Api-Request-Id") == "sha256-fixture")
        #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.bigasr.auc")
        let body = try requestBodyData(request)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let audio = try #require(object["audio"] as? [String: Any])
        #expect(audio["url"] as? String == "https://fixture.tos-cn-beijing.volces.com/tiny.mp4")
        #expect(audio["data"] == nil)
        #expect(object["mediaBase64"] == nil)
        return try contractResponse(for: request, state: "queued")
    }
    let profile = providerFixture(
        jobURL: URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit")!
    )
    let client = URLSessionCloudVideoJobClient(
        profile: profile,
        session: session,
        doubaoAppKey: "speech-app-id"
    )

    _ = try await client.submitRemoteMedia(
        CloudVideoJobRequest(
            sourceID: "clip-1",
            sourceFingerprint: "sha256-fixture",
            byteCount: 3,
            requestedCapabilities: [.cloudASR, .asyncJobs]
        ),
        mediaURL: URL(string: "https://fixture.tos-cn-beijing.volces.com/tiny.mp4")!,
        consent: MediaUploadConsent(allowsUpload: true, maximumBytes: 3),
        bearerToken: "speech-access-key"
    )
}

@Test func asyncASRRejectsInlineMediaInsteadOfInventingAnUnsupportedUploadContract() async {
    let client = URLSessionCloudVideoJobClient(
        profile: .doubaoAsyncASR(),
        doubaoAppKey: "speech-app-id"
    )

    await #expect(throws: CloudVideoJobError.remoteMediaRequired) {
        try await client.submit(
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
}

@Test func frameChatProfileCannotBeUsedAsAnAsyncVideoJobTransport() async {
    let profile = CloudProviderProfile.frameChat(
        id: "frame-only",
        displayName: "Frame only",
        baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
    )
    let client = URLSessionCloudVideoJobClient(profile: profile)

    await #expect(throws: CloudVideoJobError.jobTransportUnsupported) {
        try await client.submit(
            CloudVideoJobRequest(
                sourceID: "clip-1",
                sourceFingerprint: "sha256-fixture",
                byteCount: 3,
                requestedCapabilities: [.fullVideo]
            ),
            media: Data([1, 2, 3]),
            consent: MediaUploadConsent(allowsUpload: true, maximumBytes: 3),
            bearerToken: "speech-access-key"
        )
    }
}

@Test func asyncASRStatusUsesOfficialQueryRequestInsteadOfAppendingJobID() async throws {
    let session = makeContractSession { request in
        #expect(request.url?.absoluteString == "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Api-App-Key") == "speech-app-id")
        #expect(request.value(forHTTPHeaderField: "X-Api-Request-Id") == "task-123")
        return try contractResponse(for: request, state: "completed")
    }
    let profile = providerFixture(
        jobURL: URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query")!
    )
    let client = URLSessionCloudVideoJobClient(
        profile: profile,
        session: session,
        doubaoAppKey: "speech-app-id"
    )

    _ = try await client.status(jobID: "task-123", bearerToken: "speech-access-key")
}

@Test func asyncASRMapsOfficialQueueAndProcessingStatusCodes() async throws {
    let responses = ContractResponseQueue(["20000002", "20000001"])
    let session = makeContractSession { request in
        let code = responses.removeFirst()
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Api-Status-Code": code]
        )!
        return (response, Data(#"{"audio_info":{"duration":0}}"#.utf8))
    }
    let client = URLSessionCloudVideoJobClient(
        profile: .doubaoAsyncASR(),
        session: session,
        doubaoAppKey: "speech-app-id"
    )

    let queued = try await client.status(jobID: "task-123", bearerToken: "speech-access-key")
    let running = try await client.status(jobID: "task-123", bearerToken: "speech-access-key")

    #expect(queued.state == .queued)
    #expect(running.state == .running)
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
        #expect(message == "HTTP 403: provider request failed")
    }
}

@Test func customJobCancellationUsesOnlyAnExplicitCancellationCapability() async throws {
    let session = makeContractSession { request in
        #expect(request.url?.absoluteString == "https://provider.invalid/jobs/job-1")
        #expect(request.httpMethod == "DELETE")
        return try contractResponse(for: request, state: "cancelled")
    }
    let profile = CloudProviderProfile(
        id: "custom-cancellable",
        displayName: "Custom cancellable gateway",
        capabilityURL: URL(string: "https://provider.invalid/capabilities")!,
        jobURL: URL(string: "https://provider.invalid/jobs")!,
        declaredCapabilities: [.fullVideo, .asyncJobs, .jobCancellation],
        transport: .customJSONJob
    )
    let client = URLSessionCloudVideoJobClient(profile: profile, session: session)

    let receipt = try await client.cancel(jobID: "job-1", bearerToken: "secret")

    #expect(receipt.state == .cancelled)
}

@Test func customJobTransportClassifies429And5xxWithoutPersistingRawBodies() async throws {
    let statuses = ContractResponseQueue(["429", "503"])
    let session = makeContractSession { request in
        let status = Int(statuses.removeFirst())!
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data("private transcript and Bearer sk-secret".utf8))
    }
    let client = URLSessionCloudVideoJobClient(
        profile: providerFixture(jobURL: URL(string: "https://provider.invalid/jobs")!),
        session: session
    )

    await #expect(throws: CloudVideoJobError.rateLimited) {
        try await client.status(jobID: "job-1", bearerToken: "secret")
    }
    await #expect(throws: CloudVideoJobError.providerUnavailable(503)) {
        try await client.status(jobID: "job-1", bearerToken: "secret")
    }
}

@Test func customJobTransportRejectsTruncatedSuccessWithoutEchoingTheResponse() async throws {
    let session = makeContractSession { request in
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data(#"{"jobID":"job-1""#.utf8))
    }
    let client = URLSessionCloudVideoJobClient(
        profile: providerFixture(jobURL: URL(string: "https://provider.invalid/jobs")!),
        session: session
    )

    do {
        _ = try await client.status(jobID: "job-1", bearerToken: "secret")
        Issue.record("Expected truncated response failure")
    } catch let CloudVideoJobError.invalidResponse(message) {
        #expect(message == "HTTP 200: undecodable provider response")
        #expect(!message.contains("jobID"))
    }
}

@Test func doubaoASRDeclaresProviderCancellationUnsupported() async {
    let client = URLSessionCloudVideoJobClient(profile: .doubaoAsyncASR())

    await #expect(throws: CloudVideoJobError.cancellationUnsupported) {
        try await client.cancel(jobID: "job-1", bearerToken: "speech-access-key")
    }
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

@Test func timelineAlignerTreatsMissingProviderConfidenceAsUnknownAndNeedsReview() throws {
    let graph = try cloudGraph()
    let observation = CloudTimelineObservation(
        id: "asr-unknown",
        startSeconds: 0.2,
        endSeconds: 0.8,
        text: "Provider omitted confidence.",
        confidence: nil,
        kind: .transcript
    )

    let alignment = CloudTimelineAligner.align([observation], to: graph)

    #expect(alignment.items.first?.observation.confidence == nil)
    #expect(alignment.items.first?.evidence.confidence == 0)
    #expect(alignment.shotsNeedingReview == [ShotID(rawValue: "S001")])
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

private final class ContractResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func removeFirst() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}
