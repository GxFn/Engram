import Foundation

/// LAS production regions are a closed provider contract. Production callers cannot inject a
/// host or route through Settings.
public enum LASServiceRegion: String, Codable, CaseIterable, Hashable, Sendable {
    case cnBeijing = "cn-beijing"

    public var operatorBaseURL: URL {
        switch self {
        case .cnBeijing: URL(string: "https://operator.las.cn-beijing.volces.com")!
        }
    }

    public var submitURL: URL { operatorBaseURL.appendingPathComponent("api/v1/submit") }
    public var pollURL: URL { operatorBaseURL.appendingPathComponent("api/v1/poll") }

    public var TOSEndpointHost: String {
        switch self {
        case .cnBeijing: "tos-cn-beijing.volces.com"
        }
    }
}

public struct LASOperatorContractSource: Codable, Hashable, Sendable {
    public let documentID: String
    public let officialURL: URL
    public let submitPath: String
    public let pollPath: String
    public let reviewedAt: String

    public init(documentID: String, reviewedAt: String = "2026-07-13") {
        self.documentID = documentID
        self.officialURL = URL(string: "https://www.volcengine.com/docs/6492/\(documentID)")!
        self.submitPath = "/api/v1/submit"
        self.pollPath = "/api/v1/poll"
        self.reviewedAt = reviewedAt
    }
}

public enum LASOperatorResultSchemaEvidence: String, Codable, Hashable, Sendable {
    /// The operator page publishes a field-level response and executable response example.
    case officialResponseExample
    /// The page publishes only an artifact prefix, not the schema of files below that prefix.
    case artifactPrefixOnlyUnverified
}

/// Provider IDs and versions copied from the corresponding official operator pages. The ASR
/// page currently shows `v2` in one parameter table but uses `v1` in both submit and poll curl
/// examples; this contract follows the executable examples and keeps the revision explicit.
public enum LASOperatorContract: String, Codable, CaseIterable, Hashable, Sendable {
    case videoStoryboard
    case videoFineUnderstanding
    case scriptGeneration
    case enhancedASR

    public var operatorID: String {
        switch self {
        case .videoStoryboard: "las_video_scene_seg"
        case .videoFineUnderstanding: "las_video_understanding"
        case .scriptGeneration: "las_short_drama_script_gen"
        case .enhancedASR: "las_asr_pro"
        }
    }

    public var operatorVersion: String { "v1" }

    public var source: LASOperatorContractSource {
        switch self {
        case .videoStoryboard: LASOperatorContractSource(documentID: "2299022")
        case .videoFineUnderstanding: LASOperatorContractSource(documentID: "2275546")
        case .scriptGeneration: LASOperatorContractSource(documentID: "2371959")
        case .enhancedASR: LASOperatorContractSource(documentID: "2275584")
        }
    }

    public static let documentedASRFormats: Set<String> = ["raw", "wav", "mp3", "ogg"]

    public var resultSchemaEvidence: LASOperatorResultSchemaEvidence {
        switch self {
        case .scriptGeneration: .artifactPrefixOnlyUnverified
        case .videoStoryboard, .videoFineUnderstanding, .enhancedASR: .officialResponseExample
        }
    }

    public var role: CloudProviderRole {
        switch self {
        case .videoStoryboard: .lasVideoStoryboard
        case .videoFineUnderstanding: .lasVideoFineUnderstanding
        case .scriptGeneration: .lasScriptGeneration
        case .enhancedASR: .lasEnhancedASR
        }
    }
}

/// The enhanced-ASR page advertises video containers as a capability, but its required
/// `audio.format` table documents only raw/wav/mp3/ogg. A video container is therefore sent only
/// by the explicit paid diagnostic or after that exact LAS role has live-media evidence.
public enum LASASRFormatAuthorization: String, Codable, Hashable, Sendable {
    case officialDocumented
    case explicitLiveDiagnostic
    case liveProbeValidated
}

public enum LASOperatorInvocation: Hashable, Sendable {
    case videoStoryboard(videoTOSURL: String, outputTOSPath: String)
    case fineUnderstanding(videoTOSURL: String, query: String)
    case scriptGeneration(videoTOSURLs: [String], outputTOSPath: String)
    case enhancedASR(
        audioTOSURL: String,
        format: String,
        authorization: LASASRFormatAuthorization = .officialDocumented
    )

    public var contract: LASOperatorContract {
        switch self {
        case .videoStoryboard: .videoStoryboard
        case .fineUnderstanding: .videoFineUnderstanding
        case .scriptGeneration: .scriptGeneration
        case .enhancedASR: .enhancedASR
        }
    }

    fileprivate func requestBody() throws -> Data {
        let data: [String: Any]
        switch self {
        case let .videoStoryboard(videoTOSURL, outputTOSPath):
            try Self.validateProviderMediaURL(videoTOSURL)
            try Self.validateTOSOutputPath(outputTOSPath)
            data = [
                "video_url": videoTOSURL,
                "output_tos_path": outputTOSPath,
                "min_segment_duration": 4.0,
                "max_segment_duration": 10.0,
                "seg_mode": "precise",
            ]
        case let .fineUnderstanding(videoTOSURL, query):
            try Self.validateProviderMediaURL(videoTOSURL)
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LASOperatorTransportError.invalidInvocation("fine-understanding-query-missing")
            }
            data = [
                "video_url": videoTOSURL,
                "query": query,
                "media_resolution": "high",
                "clip_context": "long",
            ]
        case let .scriptGeneration(videoTOSURLs, outputTOSPath):
            guard !videoTOSURLs.isEmpty else {
                throw LASOperatorTransportError.invalidInvocation("script-video-list-missing")
            }
            try videoTOSURLs.forEach(Self.validateProviderMediaURL)
            try Self.validateTOSOutputPath(outputTOSPath)
            data = [
                "video_urls": videoTOSURLs,
                "output_tos_path": outputTOSPath,
            ]
        case let .enhancedASR(audioTOSURL, format, authorization):
            try Self.validateProviderMediaURL(audioTOSURL)
            let normalizedFormat = format.lowercased()
            guard !normalizedFormat.isEmpty else {
                throw LASOperatorTransportError.invalidInvocation("asr-format-missing")
            }
            guard LASOperatorContract.documentedASRFormats.contains(normalizedFormat)
                    || authorization != .officialDocumented
            else {
                throw LASOperatorTransportError.invalidInvocation(
                    "lasEnhancedASR-format-unverified:\(normalizedFormat)"
                )
            }
            data = [
                "resource": "bigasr",
                "audio": ["url": audioTOSURL, "format": normalizedFormat],
                "request": [
                    "model_name": "bigmodel",
                    "enable_itn": true,
                    "enable_punc": true,
                    "show_utterances": true,
                ],
            ]
        }
        return try JSONSerialization.data(withJSONObject: [
            "operator_id": contract.operatorID,
            "operator_version": contract.operatorVersion,
            "data": data,
        ], options: [.sortedKeys])
    }

    private static func validateProviderMediaURL(_ value: String) throws {
        guard let components = URLComponents(string: value),
              components.scheme == "tos" || components.scheme == "https",
              components.host?.isEmpty == false
        else { throw LASOperatorTransportError.invalidInvocation("provider-media-url-invalid") }
    }

    private static func validateTOSOutputPath(_ value: String) throws {
        guard let components = URLComponents(string: value),
              components.scheme == "tos", components.host?.isEmpty == false
        else { throw LASOperatorTransportError.invalidInvocation("output-tos-path-invalid") }
    }
}

public enum LASTaskState: String, Codable, Hashable, Sendable {
    case pending
    case running
    case completed
    case failed
    case timeout
}

public enum LASOperatorArtifactKind: String, Codable, Hashable, Sendable {
    case storyboardSegments
    case storyboardCharacters
    case generatedScripts
    case generatedCharacters
}

/// A non-secret TOS object or prefix written into the user's configured output directory.
/// Presigned HTTPS download links are deliberately excluded from this persisted representation.
public struct LASOperatorArtifact: Codable, Hashable, Sendable {
    public let kind: LASOperatorArtifactKind
    public let tosURL: String
    public let isPrefix: Bool

    public init?(kind: LASOperatorArtifactKind, tosURL: String, isPrefix: Bool = false) {
        guard let components = URLComponents(string: tosURL),
              components.scheme == "tos", components.host?.isEmpty == false,
              components.query == nil
        else { return nil }
        self.kind = kind
        self.tosURL = tosURL
        self.isPrefix = isPrefix
    }
}

/// Sanitized typed provider result. Raw response bodies, input object URLs and output signed URLs
/// are intentionally not representable in this persisted envelope.
public struct LASOperatorTaskReceipt: Codable, Hashable, Sendable {
    public let operatorID: String
    public let taskID: String
    public let state: LASTaskState
    public let businessCode: String
    public let requestID: String?
    public let globalSummary: String?
    public let observations: [CloudTimelineObservation]
    public let artifacts: [LASOperatorArtifact]
    public let usage: CloudProviderUsage
    public let sanitizedError: String?

    public init(
        operatorID: String,
        taskID: String,
        state: LASTaskState,
        businessCode: String,
        requestID: String?,
        globalSummary: String? = nil,
        observations: [CloudTimelineObservation],
        artifacts: [LASOperatorArtifact] = [],
        usage: CloudProviderUsage,
        sanitizedError: String?
    ) {
        self.operatorID = operatorID
        self.taskID = taskID
        self.state = state
        self.businessCode = businessCode
        self.requestID = requestID
        self.globalSummary = globalSummary
        self.observations = observations
        self.artifacts = artifacts
        self.usage = usage
        self.sanitizedError = sanitizedError.map(CloudErrorSanitizer.sanitize)
    }

    private enum CodingKeys: String, CodingKey {
        case operatorID, taskID, state, businessCode, requestID, globalSummary, observations, artifacts, usage, sanitizedError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            operatorID: try container.decode(String.self, forKey: .operatorID),
            taskID: try container.decode(String.self, forKey: .taskID),
            state: try container.decode(LASTaskState.self, forKey: .state),
            businessCode: try container.decode(String.self, forKey: .businessCode),
            requestID: try container.decodeIfPresent(String.self, forKey: .requestID),
            globalSummary: try container.decodeIfPresent(String.self, forKey: .globalSummary),
            observations: try container.decode([CloudTimelineObservation].self, forKey: .observations),
            artifacts: try container.decodeIfPresent([LASOperatorArtifact].self, forKey: .artifacts) ?? [],
            usage: try container.decode(CloudProviderUsage.self, forKey: .usage),
            sanitizedError: try container.decodeIfPresent(String.self, forKey: .sanitizedError)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operatorID, forKey: .operatorID)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(state, forKey: .state)
        try container.encode(businessCode, forKey: .businessCode)
        try container.encodeIfPresent(requestID, forKey: .requestID)
        try container.encodeIfPresent(globalSummary, forKey: .globalSummary)
        try container.encode(observations, forKey: .observations)
        if !artifacts.isEmpty { try container.encode(artifacts, forKey: .artifacts) }
        try container.encode(usage, forKey: .usage)
        try container.encodeIfPresent(sanitizedError, forKey: .sanitizedError)
    }
}

public enum LASOperatorTransportError: Error, Hashable, Sendable {
    case invalidInvocation(String)
    case missingAPIKey
    case authenticationRejected
    case rateLimited
    case providerUnavailable(Int)
    /// Submit may have reached the provider. Automatic resubmission could create a duplicate bill.
    case submissionAcknowledgementUnknown
    case invalidResponse(String)
}

public protocol LASOperatorClient: Sendable {
    func submit(_ invocation: LASOperatorInvocation, apiKey: String) async throws -> LASOperatorTaskReceipt
    func poll(
        contract: LASOperatorContract,
        taskID: String,
        apiKey: String
    ) async throws -> LASOperatorTaskReceipt
}

public struct URLSessionLASOperatorClient: LASOperatorClient {
    private let region: LASServiceRegion
    private let session: URLSession

    public init(region: LASServiceRegion, session: URLSession = .shared) {
        self.region = region
        self.session = session
    }

    public func submit(
        _ invocation: LASOperatorInvocation,
        apiKey: String
    ) async throws -> LASOperatorTaskReceipt {
        let request = try makeRequest(
            url: region.submitURL,
            apiKey: apiKey,
            body: invocation.requestBody()
        )
        do {
            return try await execute(
                request,
                contract: invocation.contract,
                requiresSubmissionAcknowledgement: true
            )
        } catch let error as LASOperatorTransportError {
            throw error
        } catch {
            // The request may have been accepted before the connection failed. A paid submit is
            // not safe to replay without a provider acknowledgement or controller/user review.
            throw LASOperatorTransportError.submissionAcknowledgementUnknown
        }
    }

    public func poll(
        contract: LASOperatorContract,
        taskID: String,
        apiKey: String
    ) async throws -> LASOperatorTaskReceipt {
        guard !taskID.isEmpty else {
            throw LASOperatorTransportError.invalidInvocation("task-id-missing")
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "operator_id": contract.operatorID,
            "operator_version": contract.operatorVersion,
            "task_id": taskID,
        ], options: [.sortedKeys])
        let request = try makeRequest(url: region.pollURL, apiKey: apiKey, body: body)
        return try await execute(request, contract: contract)
    }

    private func makeRequest(url: URL, apiKey: String, body: Data) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw LASOperatorTransportError.missingAPIKey }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    private func execute(
        _ request: URLRequest,
        contract: LASOperatorContract,
        requiresSubmissionAcknowledgement: Bool = false
    ) async throws -> LASOperatorTaskReceipt {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 401, 403: throw LASOperatorTransportError.authenticationRejected
        case 429: throw LASOperatorTransportError.rateLimited
        case 500..<600: throw LASOperatorTransportError.providerUnavailable(status)
        case 200..<300: break
        default: throw LASOperatorTransportError.invalidResponse("HTTP \(status): provider-request-failed")
        }
        do {
            let payload = try JSONDecoder().decode(LASEnvelope.self, from: data)
            return try payload.receipt(contract: contract)
        } catch let error as LASOperatorTransportError {
            if requiresSubmissionAcknowledgement {
                throw LASOperatorTransportError.submissionAcknowledgementUnknown
            }
            throw error
        } catch {
            if requiresSubmissionAcknowledgement {
                throw LASOperatorTransportError.submissionAcknowledgementUnknown
            }
            throw LASOperatorTransportError.invalidResponse("HTTP \(status): undecodable-provider-response")
        }
    }
}

private struct LASEnvelope: Decodable {
    struct Metadata: Decodable {
        let taskID: String
        let taskStatus: String
        let businessCode: String
        let errorMessage: String?
        let requestID: String?

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case taskStatus = "task_status"
            case businessCode = "business_code"
            case errorMessage = "error_msg"
            case requestID = "request_id"
        }
    }

    struct TokenUsage: Decodable {
        struct Counts: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
        let tokenUsage: Counts?
        enum CodingKeys: String, CodingKey { case tokenUsage = "token_usage" }
    }

    struct Utterance: Decodable {
        struct Word: Decodable { let confidence: Double? }
        let startTime: Int64
        let endTime: Int64
        let text: String
        let confidence: Double?
        let words: [Word]?
        enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case text
            case confidence
            case words
        }
    }

    struct ASRResult: Decodable {
        let text: String?
        let utterances: [Utterance]?
    }

    struct AudioInfo: Decodable { let duration: Int64? }

    struct ResultData: Decodable {
        let videoDuration: Double?
        let finalSummary: String?
        let tokenUsages: [TokenUsage]?
        let audioInfo: AudioInfo?
        let result: ASRResult?
        let segmentsURL: String?
        let charactersRegistryURL: String?
        let finalTablePath: String?
        let scriptsPath: String?
        let status: String?
        let failedVideoURLs: [String]?

        enum CodingKeys: String, CodingKey {
            case videoDuration = "video_duration"
            case finalSummary = "final_summary"
            case tokenUsages = "token_usages"
            case audioInfo = "audio_info"
            case result
            case segmentsURL = "segments_url"
            case charactersRegistryURL = "characters_registry_url"
            case finalTablePath = "final_table_path"
            case scriptsPath = "scripts_path"
            case status
            case failedVideoURLs = "failed_video_urls"
        }
    }

    let metadata: Metadata
    let data: ResultData?

    func receipt(contract: LASOperatorContract) throws -> LASOperatorTaskReceipt {
        let state: LASTaskState = switch metadata.taskStatus.uppercased() {
        case "PENDING", "ACCEPTED": .pending
        case "RUNNING": .running
        case "COMPLETED": .completed
        case "FAILED": .failed
        case "TIMEOUT": .timeout
        default: throw LASOperatorTransportError.invalidResponse("unknown-task-status")
        }
        if state == .completed, metadata.businessCode != "0" {
            throw LASOperatorTransportError.invalidResponse("provider-business-code-nonzero")
        }
        if contract == .scriptGeneration,
           state == .completed,
           data?.status?.lowercased() == "failed" {
            throw LASOperatorTransportError.invalidResponse("script-result-failed")
        }
        let tokens = data?.tokenUsages ?? []
        let inputTokens = tokens.reduce(0) { $0 + ($1.tokenUsage?.promptTokens ?? 0) }
        let outputTokens = tokens.reduce(0) { $0 + ($1.tokenUsage?.completionTokens ?? 0) }
        let durationMilliseconds: Int64 = if let milliseconds = data?.audioInfo?.duration {
            milliseconds
        } else if let seconds = data?.videoDuration {
            Int64((seconds * 1_000).rounded())
        } else {
            0
        }
        let observations = (data?.result?.utterances ?? []).enumerated().map { index, item in
            // The official las_asr_pro example exposes confidence on words nested in an
            // utterance. Prefer an explicit utterance value when present; otherwise use the
            // minimum valid word score so the aggregate cannot overstate its weakest token.
            let wordConfidences = (item.words ?? []).compactMap(\.confidence)
                .filter { $0.isFinite && (0...1).contains($0) }
            let confidence = item.confidence.flatMap {
                $0.isFinite && (0...1).contains($0) ? $0 : nil
            } ?? wordConfidences.min()
            return CloudTimelineObservation(
                id: "las-asr-\(index)",
                startSeconds: Double(item.startTime) / 1_000,
                endSeconds: Double(item.endTime) / 1_000,
                text: item.text,
                confidence: confidence,
                kind: .transcript
            )
        }
        var artifacts: [LASOperatorArtifact] = []
        if let value = data?.segmentsURL,
           let artifact = LASOperatorArtifact(kind: .storyboardSegments, tosURL: value) {
            artifacts.append(artifact)
        }
        if let value = data?.charactersRegistryURL,
           let artifact = LASOperatorArtifact(kind: .storyboardCharacters, tosURL: value) {
            artifacts.append(artifact)
        }
        if let value = data?.finalTablePath,
           let artifact = LASOperatorArtifact(kind: .generatedCharacters, tosURL: value) {
            artifacts.append(artifact)
        }
        if let value = data?.scriptsPath,
           let artifact = LASOperatorArtifact(kind: .generatedScripts, tosURL: value, isPrefix: true) {
            artifacts.append(artifact)
        }
        let sanitizedError: String? = if data?.status?.lowercased() == "partial_success" {
            "script-partial-success:\(data?.failedVideoURLs?.count ?? 0)"
        } else {
            metadata.errorMessage?.isEmpty == false ? metadata.errorMessage : nil
        }
        return LASOperatorTaskReceipt(
            operatorID: contract.operatorID,
            taskID: metadata.taskID,
            state: state,
            businessCode: metadata.businessCode,
            requestID: metadata.requestID,
            globalSummary: data?.finalSummary,
            observations: observations,
            artifacts: artifacts,
            usage: CloudProviderUsage(
                requestCount: 1,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                mediaMilliseconds: durationMilliseconds,
                estimatedUSD: nil
            ),
            sanitizedError: sanitizedError
        )
    }
}
