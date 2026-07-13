@testable import CloudVision
import Foundation
import Testing

@Suite(.serialized)
struct TOSMediaStagingTests {
    @Test func multipartStageUsesTemporarySTSFileRangesVerifyAndProviderReadability() async throws {
        let fixture = try temporaryMediaFixture(byteCount: 13)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let requests = RequestLedger()
        let session = makeTOSSession { request in
            requests.append(request)
            #expect(request.url?.host == "fixture-bucket.tos-cn-beijing.volces.com")
            #expect(request.value(forHTTPHeaderField: "x-tos-security-token") == "temporary-token")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("TOS4-HMAC-SHA256 ") == true)
            return try tosResponse(for: request)
        }
        let checkpoints = TOSCheckpointLedger()
        let stager = URLSessionTOSMediaStager(
            configuration: TOSMediaStagingConfiguration(
                region: .cnBeijing,
                bucket: "fixture-bucket",
                objectPrefix: "engram/runs/",
                partSizeBytes: 5
            ),
            session: session,
            now: { Date(timeIntervalSince1970: 10_000) }
        )

        let result = try await stager.stage(
            fileURL: fixture,
            sourceFingerprint: "sha256-fixture",
            byteCount: 13,
            consent: consent(maximumBytes: 13),
            credentials: temporaryCredentials(),
            checkpoint: nil,
            persistCheckpoint: { await checkpoints.append($0) }
        )

        #expect(result.object.tosURL == "tos://fixture-bucket/engram/runs/sha256-fixture.mov")
        #expect(result.checkpoint.parts.map(\.number) == [1, 2, 3])
        #expect(result.checkpoint.isVerified)
        #expect(result.checkpoint.isProviderReadable)
        #expect(requests.methods == ["POST", "PUT", "PUT", "PUT", "POST", "HEAD", "GET"])
        #expect(requests.partStreamFlags == [true, true, true])

        let encoded = String(decoding: try JSONEncoder().encode(result.checkpoint), as: UTF8.self)
        #expect(!encoded.contains("temporary-secret"))
        #expect(!encoded.contains("temporary-token"))
        #expect(!encoded.contains("https://"))
        #expect(!encoded.contains(fixture.path))
    }

    @Test func resumeSkipsUploadedPartsAndCompletedCheckpointPreventsDuplicateUpload() async throws {
        let fixture = try temporaryMediaFixture(byteCount: 13)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let requests = RequestLedger()
        let session = makeTOSSession { request in
            requests.append(request)
            return try tosResponse(for: request)
        }
        let stager = URLSessionTOSMediaStager(
            configuration: TOSMediaStagingConfiguration(
                region: .cnBeijing,
                bucket: "fixture-bucket",
                objectPrefix: "engram/runs/",
                partSizeBytes: 5
            ),
            session: session,
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        let partial = TOSUploadCheckpoint(
            sourceFingerprint: "sha256-fixture",
            objectKey: "engram/runs/sha256-fixture.mov",
            uploadID: "upload-1",
            byteCount: 13,
            parts: [TOSUploadedPart(number: 1, eTag: "etag-1")],
            isCompleted: false,
            isVerified: false,
            isProviderReadable: false,
            cleanupState: .pending,
            expiresAt: Date(timeIntervalSince1970: 10_000 + 86_400)
        )

        let resumed = try await stager.stage(
            fileURL: fixture,
            sourceFingerprint: "sha256-fixture",
            byteCount: 13,
            consent: consent(maximumBytes: 13),
            credentials: temporaryCredentials(),
            checkpoint: partial,
            persistCheckpoint: { _ in }
        )
        #expect(resumed.checkpoint.parts.count == 3)
        #expect(requests.methods == ["PUT", "PUT", "POST", "HEAD", "GET"])

        requests.reset()
        _ = try await stager.stage(
            fileURL: fixture,
            sourceFingerprint: "sha256-fixture",
            byteCount: 13,
            consent: consent(maximumBytes: 13),
            credentials: temporaryCredentials(),
            checkpoint: resumed.checkpoint,
            persistCheckpoint: { _ in }
        )
        #expect(requests.methods.isEmpty)
    }

    @Test func cleanupUsesDeleteAndRetainsRetryStateOnFailure() async throws {
        let calls = RequestLedger()
        let session = makeTOSSession { request in
            calls.append(request)
            let status = request.httpMethod == "DELETE" ? 503 : 200
            return try tosResponse(for: request, status: status)
        }
        let stager = URLSessionTOSMediaStager(
            configuration: TOSMediaStagingConfiguration(
                region: .cnBeijing,
                bucket: "fixture-bucket",
                objectPrefix: "engram/runs/",
                partSizeBytes: 5
            ),
            session: session,
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        let checkpoint = TOSUploadCheckpoint(
            sourceFingerprint: "sha256-fixture",
            objectKey: "engram/runs/sha256-fixture.mov",
            uploadID: "upload-1",
            byteCount: 13,
            parts: [],
            isCompleted: true,
            isVerified: true,
            isProviderReadable: true,
            cleanupState: .pending,
            expiresAt: Date(timeIntervalSince1970: 10_000 + 86_400)
        )

        let cleaned = await stager.cleanup(checkpoint, credentials: temporaryCredentials())

        #expect(calls.methods == ["DELETE"])
        #expect(cleaned.cleanupState == .retryRequired)
    }
}

private func consent(maximumBytes: Int64) -> CloudRunConsentReceipt {
    CloudRunConsentReceipt(
        runID: "run-1",
        sourceFingerprint: "sha256-fixture",
        planHash: "plan-1",
        acceptedAt: Date(timeIntervalSince1970: 10_000),
        maximumBytes: maximumBytes,
        maximumDurationSeconds: 100,
        costAcceptance: .unknownMayCharge
    )
}

private func temporaryCredentials() -> TOSTemporaryCredentials {
    TOSTemporaryCredentials(
        accessKeyID: "temporary-access",
        secretAccessKey: "temporary-secret",
        securityToken: "temporary-token",
        expiresAt: Date(timeIntervalSince1970: 20_000)
    )
}

private func temporaryMediaFixture(byteCount: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-tos-\(UUID().uuidString).mov")
    try Data((0..<byteCount).map(UInt8.init)).write(to: url)
    return url
}

private func makeTOSSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    TOSContractURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TOSContractURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func tosResponse(
    for request: URLRequest,
    status: Int = 200
) throws -> (HTTPURLResponse, Data) {
    let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    let headers: [String: String]
    let body: Data
    if request.httpMethod == "POST", query.contains(where: { $0.name == "uploads" }) {
        headers = [:]
        body = Data("<InitiateMultipartUploadResult><UploadId>upload-1</UploadId></InitiateMultipartUploadResult>".utf8)
    } else if request.httpMethod == "PUT" {
        let number = query.first(where: { $0.name == "partNumber" })?.value ?? "0"
        headers = ["ETag": "etag-\(number)"]
        body = Data()
    } else if request.httpMethod == "HEAD" {
        headers = ["Content-Length": "13"]
        body = Data()
    } else {
        headers = [:]
        body = Data()
    }
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: nil,
        headerFields: headers
    ))
    return (response, body)
}

private final class RequestLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap(\.httpMethod)
    }

    var partStreamFlags: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.httpMethod == "PUT" }.map { $0.httpBodyStream != nil }
    }

    func reset() {
        lock.lock()
        requests.removeAll()
        lock.unlock()
    }
}

private actor TOSCheckpointLedger {
    private(set) var values: [TOSUploadCheckpoint] = []
    func append(_ checkpoint: TOSUploadCheckpoint) { values.append(checkpoint) }
}

private final class TOSContractURLProtocol: URLProtocol, @unchecked Sendable {
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
