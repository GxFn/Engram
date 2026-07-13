@testable import CloudVision
import Foundation
import Testing

@Suite(.serialized)
struct LASOperatorTransportTests {
    @Test func officialOperatorContractsUseFixedRegionPathsAndRoleSpecificBodies() async throws {
        let expected: [(LASOperatorInvocation, String, String)] = [
            (
                .videoStoryboard(
                    videoTOSURL: "tos://engram-stage/source.mp4",
                    outputTOSPath: "tos://engram-stage/output/run-1/"
                ),
                "las_video_scene_seg",
                "video_url"
            ),
            (
                .fineUnderstanding(
                    videoTOSURL: "tos://engram-stage/source.mp4",
                    query: "Return evidence-grounded events with timestamps."
                ),
                "las_video_understanding",
                "query"
            ),
            (
                .scriptGeneration(
                    videoTOSURLs: ["tos://engram-stage/source.mp4"],
                    outputTOSPath: "tos://engram-stage/output/run-1/"
                ),
                "las_short_drama_script_gen",
                "video_urls"
            ),
            (
                .enhancedASR(
                    audioTOSURL: "tos://engram-stage/source.wav",
                    format: "wav"
                ),
                "las_asr_pro",
                "audio"
            ),
        ]

        for (invocation, operatorID, roleField) in expected {
            let session = makeLASSession { request in
                #expect(request.url?.absoluteString == "https://operator.las.cn-beijing.volces.com/api/v1/submit")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer las-secret")
                #expect(request.value(forHTTPHeaderField: "X-Api-App-Key") == nil)
                let body = try requestBodyObject(request)
                #expect(body["operator_id"] as? String == operatorID)
                #expect(body["operator_version"] as? String == "v1")
                let data = try #require(body["data"] as? [String: Any])
                #expect(data[roleField] != nil)
                #expect(body["mediaBase64"] == nil)
                return try lasResponse(
                    for: request,
                    body: #"{"metadata":{"task_id":"task-1","task_status":"PENDING","business_code":"0","error_msg":""}}"#
                )
            }
            let client = URLSessionLASOperatorClient(region: .cnBeijing, session: session)

            let receipt = try await client.submit(invocation, apiKey: "las-secret")

            #expect(receipt.taskID == "task-1")
            #expect(receipt.state == .pending)
            #expect(receipt.operatorID == operatorID)
        }
    }

    @Test func pollUsesOfficialEndpointAndMapsTypedUsageWithoutKeepingRawResponse() async throws {
        let session = makeLASSession { request in
            #expect(request.url?.absoluteString == "https://operator.las.cn-beijing.volces.com/api/v1/poll")
            let body = try requestBodyObject(request)
            #expect(body["operator_id"] as? String == "las_video_understanding")
            #expect(body["task_id"] as? String == "task-fine-1")
            return try lasResponse(
                for: request,
                body: #"{"metadata":{"task_id":"task-fine-1","task_status":"COMPLETED","business_code":"0","error_msg":""},"data":{"video_duration":12.5,"final_summary":"A person enters.","token_usages":[{"model_name":"fixture","token_usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120}}]}}"#
            )
        }
        let client = URLSessionLASOperatorClient(region: .cnBeijing, session: session)

        let receipt = try await client.poll(
            contract: .videoFineUnderstanding,
            taskID: "task-fine-1",
            apiKey: "las-secret"
        )

        #expect(receipt.state == .completed)
        #expect(receipt.usage.requestCount == 1)
        #expect(receipt.usage.inputTokens == 100)
        #expect(receipt.usage.outputTokens == 20)
        #expect(receipt.usage.mediaMilliseconds == 12_500)
        #expect(receipt.observations.map(\.text) == ["A person enters."])
        let encoded = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        #expect(!encoded.contains("token_usages"))
        #expect(!encoded.contains("tos://"))
        #expect(try JSONDecoder().decode(LASOperatorTaskReceipt.self, from: Data(encoded.utf8)).artifacts.isEmpty)
    }

    @Test func productionLASContractCannotRepresentCustomHostPathOrOperatorID() {
        #expect(LASOperatorContract.videoStoryboard.operatorID == "las_video_scene_seg")
        #expect(LASOperatorContract.videoFineUnderstanding.operatorID == "las_video_understanding")
        #expect(LASOperatorContract.scriptGeneration.operatorID == "las_short_drama_script_gen")
        #expect(LASOperatorContract.enhancedASR.operatorID == "las_asr_pro")
        #expect(LASServiceRegion.cnBeijing.submitURL.path == "/api/v1/submit")
        #expect(LASServiceRegion.cnBeijing.pollURL.path == "/api/v1/poll")
    }

    @Test func productionContractsCarryTraceableOfficialOperatorSources() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Infrastructure/CloudVision/LASOperatorTransport.swift"),
            encoding: .utf8
        )
        for documentID in ["2299022", "2275546", "2371959", "2275584"] {
            #expect(source.contains(documentID), "Missing official LAS operator document \(documentID)")
        }
        #expect(source.contains("documentedASRFormats"))
        #expect(source.contains("explicitLiveDiagnostic"))
        #expect(source.contains("liveProbeValidated"))
    }

    @Test func acceptedScriptJobMapsToPendingAndCompletedBusinessFailureFailsClosed() async throws {
        let responses = [
            #"{"metadata":{"task_id":"script-accepted","task_status":"ACCEPTED","business_code":"0","error_msg":""}}"#,
            #"{"metadata":{"task_id":"fine-failed","task_status":"COMPLETED","business_code":"500","error_msg":"provider business failure"}}"#,
        ]
        let index = ResponseIndex()
        let session = makeLASSession { request in
            try lasResponse(for: request, body: responses[index.take()])
        }
        let client = URLSessionLASOperatorClient(region: .cnBeijing, session: session)

        let accepted = try await client.poll(
            contract: .scriptGeneration,
            taskID: "script-accepted",
            apiKey: "las-secret"
        )
        #expect(accepted.state == .pending)
        await #expect(throws: LASOperatorTransportError.self) {
            try await client.poll(
                contract: .videoFineUnderstanding,
                taskID: "fine-failed",
                apiKey: "las-secret"
            )
        }
    }

    @Test func fineGlobalSummaryDoesNotFabricatePerShotTimelineEvidence() async throws {
        let session = makeLASSession { request in
            try lasResponse(
                for: request,
                body: #"{"metadata":{"task_id":"fine-1","task_status":"COMPLETED","business_code":"0","error_msg":""},"data":{"video_duration":12.5,"final_summary":"Whole-video summary only."}}"#
            )
        }
        let client = URLSessionLASOperatorClient(region: .cnBeijing, session: session)

        let receipt = try await client.poll(
            contract: .videoFineUnderstanding,
            taskID: "fine-1",
            apiKey: "las-secret"
        )

        #expect(receipt.observations.isEmpty)
    }

    @Test func pollKeepsOnlyNonSignedTOSArtifactReferencesForStoryboardAndScripts() async throws {
        let responses = [
            #"{"metadata":{"task_id":"story-1","task_status":"COMPLETED","business_code":"0","error_msg":""},"data":{"segments_url":"tos://fixture-bucket/engram/runs/output/segments.json","characters_registry_url":"tos://fixture-bucket/engram/runs/output/characters.json"}}"#,
            #"{"metadata":{"task_id":"script-1","task_status":"COMPLETED","business_code":"0","error_msg":""},"data":{"final_table_path":"tos://fixture-bucket/engram/runs/output/characters.json","scripts_path":"tos://fixture-bucket/engram/runs/output/scripts","package_url":"https://signed.example.invalid/archive.zip?token=secret"}}"#,
        ]
        let index = ResponseIndex()
        let session = makeLASSession { request in
            try lasResponse(for: request, body: responses[index.take()])
        }
        let client = URLSessionLASOperatorClient(region: .cnBeijing, session: session)

        let storyboard = try await client.poll(
            contract: .videoStoryboard,
            taskID: "story-1",
            apiKey: "las-secret"
        )
        let script = try await client.poll(
            contract: .scriptGeneration,
            taskID: "script-1",
            apiKey: "las-secret"
        )

        #expect(storyboard.artifacts.map(\.kind) == [.storyboardSegments, .storyboardCharacters])
        #expect(script.artifacts.map(\.kind) == [.generatedCharacters, .generatedScripts])
        let encoded = String(decoding: try JSONEncoder().encode(script), as: UTF8.self)
        #expect(!encoded.contains("signed.example.invalid"))
        #expect(!encoded.contains("token=secret"))
    }

    @Test func successfulSubmitWithoutATaskReceiptBecomesUnknownAcknowledgement() async throws {
        let session = makeLASSession { request in
            try lasResponse(for: request, body: #"{"metadata":{"business_code":"0"}}"#)
        }
        let client = URLSessionLASOperatorClient(region: .cnBeijing, session: session)

        await #expect(throws: LASOperatorTransportError.submissionAcknowledgementUnknown) {
            try await client.submit(
                .videoStoryboard(
                    videoTOSURL: "tos://engram-stage/source.mp4",
                    outputTOSPath: "tos://engram-stage/output/run-1/"
                ),
                apiKey: "las-secret"
            )
        }
    }
}

private final class ResponseIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func take() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

private func makeLASSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    LASContractURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LASContractURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func requestBodyObject(_ request: URLRequest) throws -> [String: Any] {
    let body: Data
    if let value = request.httpBody {
        body = value
    } else {
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var value = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            value.append(buffer, count: count)
        }
        body = value
    }
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private func lasResponse(
    for request: URLRequest,
    body: String,
    status: Int = 200
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: nil,
        headerFields: nil
    ))
    return (response, Data(body.utf8))
}

private final class LASContractURLProtocol: URLProtocol, @unchecked Sendable {
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
