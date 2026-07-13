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
                    audioTOSURL: "tos://engram-stage/source.mp4",
                    format: "mp4"
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
    }

    @Test func productionLASContractCannotRepresentCustomHostPathOrOperatorID() {
        #expect(LASOperatorContract.videoStoryboard.operatorID == "las_video_scene_seg")
        #expect(LASOperatorContract.videoFineUnderstanding.operatorID == "las_video_understanding")
        #expect(LASOperatorContract.scriptGeneration.operatorID == "las_short_drama_script_gen")
        #expect(LASOperatorContract.enhancedASR.operatorID == "las_asr_pro")
        #expect(LASServiceRegion.cnBeijing.submitURL.path == "/api/v1/submit")
        #expect(LASServiceRegion.cnBeijing.pollURL.path == "/api/v1/poll")
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
    let body = try #require(request.httpBody)
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
