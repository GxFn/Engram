@testable import AppShell
import CloudVision
import ClipDigest
import Foundation
import StoryboardCore
import Testing
import VideoUnderstanding

@Suite(.serialized)
struct CloudStoryboardEnricherContractTests {
@Test func productionCloudEnricherSubmitsPollsPersistsUsageAndRoutesRefinementOverMockHTTP() async throws {
    let fixture = try CloudEnricherFixture()
    defer { fixture.cleanup() }
    let recorder = CloudEnricherHTTPRecorder()
    let session = makeCloudEnricherHTTPSession { request in
        recorder.record(request)
        return try cloudEnricherResponse(
            for: request,
            state: request.httpMethod == "POST" ? .queued : .completed
        )
    }
    let consent = CloudConsentLedger()
    let checkpoints = CloudCheckpointLedger()
    let enricher = ConfiguredCloudStoryboardEnricher(
        configuration: fixture.configuration(consent: consent),
        capabilityProbe: CloudEnricherProbe(),
        clientFactory: { URLSessionCloudVideoJobClient(profile: $0, session: session) },
        sleep: { _ in }
    )

    let result = try await enricher.enrich(
        source: fixture.source,
        asset: fixture.asset,
        graph: fixture.graph,
        resume: nil,
        checkpoint: { await checkpoints.append($0) }
    )

    #expect(result.context.requestedCloudMode == .cloudDeep)
    #expect(result.context.cloudMode == .cloudDeep)
    #expect(result.context.mediaUploaded)
    #expect(result.context.mediaBytesUploaded == 3)
    #expect((result.context.requestBytes ?? 0) > 3)
    #expect(result.context.requestCount == 2)
    #expect(result.context.inputTokens == 11)
    #expect(result.context.outputTokens == 7)
    #expect(result.context.mediaMilliseconds == 2_000)
    #expect(result.context.estimatedUSD == Decimal(string: "0.012"))
    #expect(result.context.refinementShotIDs == [fixture.graph.shots[0].id])
    #expect(result.shotsNeedingReview == [fixture.graph.shots[0].id])
    #expect(recorder.methodCount("POST") == 1)
    #expect(recorder.methodCount("GET") == 1)
    #expect(recorder.submittedIdempotencyKey() == fixture.asset.fingerprint.value)
    #expect(await consent.count == 1)
    #expect(await checkpoints.states == ["queued", "completed"])
}

@Test func productionCloudEnricherCheckpoints429AndResumesWithoutDuplicateHTTPSubmit() async throws {
    let fixture = try CloudEnricherFixture()
    defer { fixture.cleanup() }
    let failingRecorder = CloudEnricherHTTPRecorder()
    let failingSession = makeCloudEnricherHTTPSession { request in
        failingRecorder.record(request)
        if request.httpMethod == "GET" {
            return try cloudEnricherErrorResponse(for: request, status: 429)
        }
        return try cloudEnricherResponse(for: request, state: .queued)
    }
    let consent = CloudConsentLedger()
    let checkpoints = CloudCheckpointLedger()
    let first = ConfiguredCloudStoryboardEnricher(
        configuration: fixture.configuration(consent: consent),
        capabilityProbe: CloudEnricherProbe(),
        clientFactory: { URLSessionCloudVideoJobClient(profile: $0, session: failingSession) },
        sleep: { _ in }
    )

    await #expect(throws: VideoUnderstandingError.self) {
        try await first.enrich(
            source: fixture.source,
            asset: fixture.asset,
            graph: fixture.graph,
            resume: nil,
            checkpoint: { await checkpoints.append($0) }
        )
    }
    let resume = try #require(await checkpoints.values.last)
    #expect(resume.state == "transport-error")

    let resumedRecorder = CloudEnricherHTTPRecorder()
    let resumedSession = makeCloudEnricherHTTPSession { request in
        resumedRecorder.record(request)
        return try cloudEnricherResponse(for: request, state: .completed)
    }
    let resumed = ConfiguredCloudStoryboardEnricher(
        configuration: fixture.configuration(consent: consent),
        capabilityProbe: CloudEnricherProbe(),
        clientFactory: { URLSessionCloudVideoJobClient(profile: $0, session: resumedSession) },
        sleep: { _ in }
    )
    let result = try await resumed.enrich(
        source: fixture.source,
        asset: fixture.asset,
        graph: fixture.graph,
        resume: resume,
        checkpoint: { await checkpoints.append($0) }
    )

    #expect(result.context.cloudMode == .cloudDeep)
    #expect(failingRecorder.methodCount("POST") == 1)
    #expect(failingRecorder.methodCount("GET") == 1)
    #expect(resumedRecorder.methodCount("POST") == 0)
    #expect(resumedRecorder.methodCount("GET") == 1)
    #expect(await consent.count == 1)
}

@Test func productionCloudEnricherCancelsSubmittedHTTPJobAndPersistsReceipt() async throws {
    let fixture = try CloudEnricherFixture()
    defer { fixture.cleanup() }
    let recorder = CloudEnricherHTTPRecorder()
    let session = makeCloudEnricherHTTPSession { request in
        recorder.record(request)
        return try cloudEnricherResponse(
            for: request,
            state: request.httpMethod == "DELETE" ? .cancelled : .queued
        )
    }
    let checkpoints = CloudCheckpointLedger()
    let enricher = ConfiguredCloudStoryboardEnricher(
        configuration: fixture.configuration(consent: CloudConsentLedger()),
        capabilityProbe: CloudEnricherProbe(),
        clientFactory: { URLSessionCloudVideoJobClient(profile: $0, session: session) },
        sleep: { _ in throw CancellationError() }
    )

    await #expect(throws: CancellationError.self) {
        try await enricher.enrich(
            source: fixture.source,
            asset: fixture.asset,
            graph: fixture.graph,
            resume: nil,
            checkpoint: { await checkpoints.append($0) }
        )
    }

    #expect(recorder.methods() == ["POST", "DELETE"])
    #expect(await checkpoints.states == ["queued", "cancelled"])
}

@Test func productionCloudEnricherTimesOutAfterBoundedHTTPPollingAndKeepsResumeCheckpoint() async throws {
    let fixture = try CloudEnricherFixture()
    defer { fixture.cleanup() }
    let recorder = CloudEnricherHTTPRecorder()
    let session = makeCloudEnricherHTTPSession { request in
        recorder.record(request)
        return try cloudEnricherResponse(for: request, state: .queued)
    }
    let checkpoints = CloudCheckpointLedger()
    let enricher = ConfiguredCloudStoryboardEnricher(
        configuration: fixture.configuration(consent: CloudConsentLedger()),
        capabilityProbe: CloudEnricherProbe(),
        clientFactory: { URLSessionCloudVideoJobClient(profile: $0, session: session) },
        sleep: { _ in }
    )

    await #expect(throws: VideoUnderstandingError.self) {
        try await enricher.enrich(
            source: fixture.source,
            asset: fixture.asset,
            graph: fixture.graph,
            resume: nil,
            checkpoint: { await checkpoints.append($0) }
        )
    }

    #expect(recorder.methodCount("POST") == 1)
    #expect(recorder.methodCount("GET") == 60)
    #expect(await checkpoints.states.last == "transport-error")
}
}

private struct CloudEnricherFixture {
    let root: URL
    let source: VideoSource
    let asset: VideoAssetDescriptor
    let graph: ShotGraph
    let profile: CloudProviderProfile

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EngramCloudEnricherContract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mediaURL = root.appendingPathComponent("tiny.mp4")
        try Data([1, 2, 3]).write(to: mediaURL)
        source = VideoSource(
            id: "cloud-contract",
            localFileURL: mediaURL,
            importedAt: Date(timeIntervalSince1970: 1)
        )
        asset = VideoAssetDescriptor(
            sourceID: source.id,
            durationSeconds: 2,
            nominalFrameRate: 30,
            frameCount: 60,
            width: 720,
            height: 1280,
            timescale: 600,
            codec: "fixture",
            hasAudio: true,
            fileSizeBytes: 3,
            fingerprint: SourceFingerprint(value: "cloud-contract-fingerprint")
        )
        graph = try ShotGraph(asset: asset, shots: [
            ShotSegment(
                id: ShotID(rawValue: "S001"),
                timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 2),
                frameRange: FrameRange(startFrame: 0, endFrameExclusive: 60),
                transitionIn: .start,
                transitionOut: .end,
                boundaryConfidence: 1,
                detectorEvidenceIDs: ["detector:S001"]
            ),
        ])
        profile = CloudProviderProfile(
            id: "explicit-custom-video-gateway",
            displayName: "Explicit custom video gateway",
            capabilityURL: URL(string: "https://provider.invalid/capabilities")!,
            jobURL: URL(string: "https://provider.invalid/jobs")!,
            declaredCapabilities: [
                .frameUnderstanding, .fullVideo, .cloudASR, .asyncJobs,
                .idempotentSubmit, .usageReporting, .jobCancellation,
            ],
            transport: .customJSONJob
        )
    }

    func configuration(consent: CloudConsentLedger) -> CloudAIResolver.VideoConfiguration {
        CloudAIResolver.VideoConfiguration(
            profile: profile,
            requestedMode: .cloudDeep,
            consent: MediaUploadConsent(allowsUpload: true, maximumBytes: 10),
            bearerToken: "runtime-only-token",
            consumeUploadConsent: { await consent.consume() }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct CloudEnricherProbe: CloudCapabilityProbing {
    func probe(_ profile: CloudProviderProfile) async -> CloudCapabilityProbeResult {
        CloudCapabilityProbeResult(
            providerID: profile.id,
            available: profile.declaredCapabilities,
            unavailable: [],
            checkedAt: Date(timeIntervalSince1970: 2),
            evidence: "mock HTTP capability contract"
        )
    }
}

private actor CloudConsentLedger {
    private(set) var count = 0
    func consume() -> Bool {
        count += 1
        return count == 1
    }
}

private actor CloudCheckpointLedger {
    private(set) var values: [CloudVideoJobCheckpoint] = []
    var states: [String] { values.map(\.state) }
    func append(_ checkpoint: CloudVideoJobCheckpoint) {
        values.append(checkpoint)
    }
}

private func makeCloudEnricherHTTPSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    CloudEnricherURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudEnricherURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func cloudEnricherResponse(
    for request: URLRequest,
    state: CloudVideoJobState
) throws -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    let receipt = CloudVideoJobReceipt(
        jobID: "job-contract",
        state: state,
        observations: state == .completed ? [
            CloudTimelineObservation(
                id: "visual-low-confidence",
                startSeconds: 0.2,
                endSeconds: 1.8,
                text: "person crosses the frame",
                confidence: 0.4,
                kind: .visual
            ),
        ] : [],
        sanitizedError: nil,
        idempotencyKey: "cloud-contract-fingerprint",
        usage: CloudProviderUsage(
            requestCount: state == .completed ? 2 : 1,
            inputTokens: state == .completed ? 11 : 0,
            outputTokens: state == .completed ? 7 : 0,
            mediaMilliseconds: state == .completed ? 2_000 : 0,
            estimatedUSD: state == .completed ? Decimal(string: "0.012") : nil
        ),
        cancellationSupported: true
    )
    return (response, try JSONEncoder().encode(receipt))
}

private func cloudEnricherErrorResponse(
    for request: URLRequest,
    status: Int
) throws -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: status,
        httpVersion: nil,
        headerFields: nil
    )!
    return (response, Data("provider-private-body".utf8))
}

private final class CloudEnricherHTTPRecorder: @unchecked Sendable {
    private struct RecordedRequest {
        let method: String
        let body: Data?
    }

    private let lock = NSLock()
    private var requests: [RecordedRequest] = []

    func record(_ request: URLRequest) {
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "",
            body: request.httpBody ?? request.httpBodyStream.flatMap(Self.readAll)
        )
        lock.lock()
        requests.append(recorded)
        lock.unlock()
    }

    func methods() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map(\.method)
    }

    func methodCount(_ method: String) -> Int {
        methods().filter { $0 == method }.count
    }

    func submittedIdempotencyKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let body = requests.first(where: { $0.method == "POST" })?.body,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let request = root["request"] as? [String: Any]
        else { return nil }
        return request["idempotencyKey"] as? String
    }

    private static func readAll(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class CloudEnricherURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
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
