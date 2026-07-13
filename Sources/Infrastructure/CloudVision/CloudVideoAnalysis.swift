import Foundation
import StoryboardCore
import VideoUnderstanding

public enum CloudCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case frameUnderstanding
    case fullVideo
    case cloudASR
    case asyncJobs
    case idempotentSubmit
    case usageReporting
    case jobCancellation
}

public enum CloudProviderTransport: String, Codable, Hashable, Sendable {
    /// A configured OpenAI-compatible chat endpoint. It proves frame/image chat only.
    case frameChat
    /// Doubao recording-file ASR submit/query protocol under openspeech.bytedance.com.
    case doubaoAsyncASR
    /// Backward-compatible custom gateway. It must never be inferred from an arbitrary chat URL.
    case customJSONJob
}

public struct CloudProviderProfile: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let capabilityURL: URL
    public let jobURL: URL
    public let declaredCapabilities: Set<CloudCapability>
    public let transport: CloudProviderTransport

    public init(
        id: String,
        displayName: String,
        capabilityURL: URL,
        jobURL: URL,
        declaredCapabilities: Set<CloudCapability>,
        transport: CloudProviderTransport? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilityURL = capabilityURL
        self.jobURL = jobURL
        self.declaredCapabilities = declaredCapabilities
        self.transport = transport ?? Self.inferTransport(
            jobURL: jobURL,
            declaredCapabilities: declaredCapabilities
        )
    }

    public static func frameChat(
        id: String,
        displayName: String,
        baseURL: URL
    ) -> CloudProviderProfile {
        let endpoint = baseURL.path.hasSuffix("/chat/completions")
            ? baseURL
            : baseURL.appendingPathComponent("chat/completions")
        return CloudProviderProfile(
            id: id,
            displayName: displayName,
            capabilityURL: endpoint,
            jobURL: endpoint,
            declaredCapabilities: [.frameUnderstanding],
            transport: .frameChat
        )
    }

    public static func doubaoAsyncASR(
        id: String = "volcengine-doubao-asr",
        displayName: String = "Volcengine Doubao asynchronous ASR",
        submitURL: URL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit")!
    ) -> CloudProviderProfile {
        CloudProviderProfile(
            id: id,
            displayName: displayName,
            capabilityURL: submitURL,
            jobURL: submitURL,
            declaredCapabilities: [.cloudASR, .asyncJobs, .idempotentSubmit, .usageReporting],
            transport: .doubaoAsyncASR
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, capabilityURL, jobURL, declaredCapabilities, transport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        capabilityURL = try container.decode(URL.self, forKey: .capabilityURL)
        jobURL = try container.decode(URL.self, forKey: .jobURL)
        declaredCapabilities = try container.decode(Set<CloudCapability>.self, forKey: .declaredCapabilities)
        transport = try container.decodeIfPresent(CloudProviderTransport.self, forKey: .transport)
            ?? Self.inferTransport(jobURL: jobURL, declaredCapabilities: declaredCapabilities)
    }

    private static func inferTransport(
        jobURL: URL,
        declaredCapabilities: Set<CloudCapability>
    ) -> CloudProviderTransport {
        if jobURL.host == "openspeech.bytedance.com",
           jobURL.path.contains("/auc/bigmodel/") {
            return .doubaoAsyncASR
        }
        if declaredCapabilities == [.frameUnderstanding] {
            return .frameChat
        }
        return .customJSONJob
    }
}

public struct CloudCapabilityProbeResult: Codable, Hashable, Sendable {
    public let providerID: String
    public let available: Set<CloudCapability>
    public let unavailable: Set<CloudCapability>
    public let checkedAt: Date
    /// Sanitized, non-secret response or transport evidence suitable for diagnostics.
    public let evidence: String

    public init(
        providerID: String,
        available: Set<CloudCapability>,
        unavailable: Set<CloudCapability>,
        checkedAt: Date,
        evidence: String
    ) {
        self.providerID = providerID
        self.available = available
        self.unavailable = unavailable
        self.checkedAt = checkedAt
        self.evidence = CloudErrorSanitizer.sanitize(evidence)
    }
}

public protocol CloudCapabilityProbing: Sendable {
    func probe(_ profile: CloudProviderProfile) async -> CloudCapabilityProbeResult
}

/// Probes a public capability endpoint without sending credentials or media.
public struct HTTPCloudCapabilityProbe: CloudCapabilityProbing {
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    public func probe(_ profile: CloudProviderProfile) async -> CloudCapabilityProbeResult {
        if profile.transport == .frameChat {
            return CloudCapabilityProbeResult(
                providerID: profile.id,
                available: [.frameUnderstanding],
                unavailable: profile.declaredCapabilities.subtracting([.frameUnderstanding]),
                checkedAt: now(),
                evidence: "explicit frame-chat profile; deep-video capability not declared"
            )
        }
        var request = URLRequest(url: profile.capabilityURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            struct Payload: Decodable { let capabilities: [String] }
            guard (200..<300).contains(status),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data)
            else {
                return unavailable(profile, evidence: "HTTP \(status): capability endpoint unavailable")
            }
            let available = Set(payload.capabilities.compactMap(CloudCapability.init(rawValue:)))
                .intersection(profile.declaredCapabilities)
            return CloudCapabilityProbeResult(
                providerID: profile.id,
                available: available,
                unavailable: profile.declaredCapabilities.subtracting(available),
                checkedAt: now(),
                evidence: "HTTP \(status): \(available.map(\.rawValue).sorted().joined(separator: ","))"
            )
        } catch {
            return unavailable(profile, evidence: String(describing: error))
        }
    }

    private func unavailable(_ profile: CloudProviderProfile, evidence: String) -> CloudCapabilityProbeResult {
        CloudCapabilityProbeResult(
            providerID: profile.id,
            available: [],
            unavailable: profile.declaredCapabilities,
            checkedAt: now(),
            evidence: evidence
        )
    }
}

public struct MediaUploadConsent: Codable, Hashable, Sendable {
    public let allowsUpload: Bool
    public let maximumBytes: Int64

    public init(allowsUpload: Bool, maximumBytes: Int64) {
        self.allowsUpload = allowsUpload
        self.maximumBytes = max(0, maximumBytes)
    }
}

public struct CloudModeDecision: Codable, Hashable, Sendable {
    public let requestedMode: EffectiveCloudMode
    public let effectiveMode: EffectiveCloudMode
    public let mediaUploadAllowed: Bool
    public let degradationNote: String?
    public let probeEvidence: String
}

public enum CloudModeResolver {
    public static func resolve(
        requested: EffectiveCloudMode,
        profile: CloudProviderProfile,
        probe: CloudCapabilityProbeResult,
        consent: MediaUploadConsent
    ) -> CloudModeDecision {
        switch requested {
        case .local:
            return CloudModeDecision(
                requestedMode: requested, effectiveMode: .local,
                mediaUploadAllowed: false, degradationNote: nil,
                probeEvidence: probe.evidence
            )
        case .cloudStandard:
            let available = probe.available.contains(.frameUnderstanding)
            return CloudModeDecision(
                requestedMode: requested,
                effectiveMode: available ? .cloudStandard : .local,
                mediaUploadAllowed: false,
                degradationNote: available ? nil : "frameUnderstanding unavailable; degraded to local",
                probeEvidence: probe.evidence
            )
        case .cloudDeep:
            let deep: Set<CloudCapability> = [.fullVideo, .cloudASR, .asyncJobs]
            let missing = deep.subtracting(probe.available)
            let canUpload = missing.isEmpty && consent.allowsUpload && consent.maximumBytes > 0
            if canUpload {
                return CloudModeDecision(
                    requestedMode: requested, effectiveMode: .cloudDeep,
                    mediaUploadAllowed: true, degradationNote: nil,
                    probeEvidence: probe.evidence
                )
            }
            let standard = probe.available.contains(.frameUnderstanding)
            let reasons = missing.map(\.rawValue).sorted().joined(separator: ",")
            let consentReason = consent.allowsUpload ? "" : "; upload consent missing"
            return CloudModeDecision(
                requestedMode: requested,
                effectiveMode: standard ? .cloudStandard : .local,
                mediaUploadAllowed: false,
                degradationNote: "\(reasons.isEmpty ? "cloudDeep" : reasons) unavailable\(consentReason); degraded to \(standard ? "cloudStandard" : "local")",
                probeEvidence: probe.evidence
            )
        }
    }
}

public struct CloudCostEstimate: Codable, Hashable, Sendable {
    public let uploadBytes: Int64
    public let estimatedUSD: Decimal

    public init(uploadBytes: Int64, estimatedUSD: Decimal) {
        self.uploadBytes = max(0, uploadBytes)
        self.estimatedUSD = max(0, estimatedUSD)
    }
}

public struct CloudVideoJobRequest: Codable, Hashable, Sendable {
    public let sourceID: String
    public let sourceFingerprint: String
    public let byteCount: Int64
    public let requestedCapabilities: Set<CloudCapability>
    public let idempotencyKey: String

    public init(
        sourceID: String,
        sourceFingerprint: String,
        byteCount: Int64,
        requestedCapabilities: Set<CloudCapability>,
        idempotencyKey: String? = nil
    ) {
        self.sourceID = sourceID
        self.sourceFingerprint = sourceFingerprint
        self.byteCount = max(0, byteCount)
        self.requestedCapabilities = requestedCapabilities
        self.idempotencyKey = if let idempotencyKey, !idempotencyKey.isEmpty {
            idempotencyKey
        } else {
            sourceFingerprint
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, sourceFingerprint, byteCount, requestedCapabilities, idempotencyKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        sourceFingerprint = try container.decode(String.self, forKey: .sourceFingerprint)
        byteCount = max(0, try container.decode(Int64.self, forKey: .byteCount))
        requestedCapabilities = try container.decode(Set<CloudCapability>.self, forKey: .requestedCapabilities)
        let decodedKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey)
        idempotencyKey = if let decodedKey, !decodedKey.isEmpty {
            decodedKey
        } else {
            sourceFingerprint
        }
    }
}

public enum CloudVideoJobState: String, Codable, Hashable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public struct CloudProviderUsage: Codable, Hashable, Sendable {
    public let requestCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let mediaMilliseconds: Int64
    public let estimatedUSD: Decimal?

    public init(
        requestCount: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        mediaMilliseconds: Int64 = 0,
        estimatedUSD: Decimal? = nil
    ) {
        self.requestCount = max(0, requestCount)
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.mediaMilliseconds = max(0, mediaMilliseconds)
        self.estimatedUSD = estimatedUSD.map { max(0, $0) }
    }

    public static let zero = CloudProviderUsage()
}

public struct CloudVideoJobReceipt: Codable, Hashable, Sendable {
    public let jobID: String
    public let state: CloudVideoJobState
    public let observations: [CloudTimelineObservation]
    public let sanitizedError: String?
    public let idempotencyKey: String?
    public let usage: CloudProviderUsage
    public let cancellationSupported: Bool

    public init(
        jobID: String,
        state: CloudVideoJobState,
        observations: [CloudTimelineObservation],
        sanitizedError: String?,
        idempotencyKey: String? = nil,
        usage: CloudProviderUsage = .zero,
        cancellationSupported: Bool = false
    ) {
        self.jobID = jobID
        self.state = state
        self.observations = observations
        self.sanitizedError = sanitizedError.map(CloudErrorSanitizer.sanitize)
        self.idempotencyKey = idempotencyKey
        self.usage = usage
        self.cancellationSupported = cancellationSupported
    }

    private enum CodingKeys: String, CodingKey {
        case jobID, state, observations, sanitizedError, idempotencyKey, usage, cancellationSupported
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(String.self, forKey: .jobID)
        state = try container.decode(CloudVideoJobState.self, forKey: .state)
        observations = try container.decodeIfPresent([CloudTimelineObservation].self, forKey: .observations) ?? []
        sanitizedError = try container.decodeIfPresent(String.self, forKey: .sanitizedError)
            .map(CloudErrorSanitizer.sanitize)
        idempotencyKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey)
        usage = try container.decodeIfPresent(CloudProviderUsage.self, forKey: .usage) ?? .zero
        cancellationSupported = try container.decodeIfPresent(Bool.self, forKey: .cancellationSupported) ?? false
    }
}

public enum CloudVideoJobError: Error, Hashable, Sendable {
    case uploadNotConsented
    case uploadExceedsConsent
    case remoteMediaRequired
    case invalidRemoteMediaURL
    case missingProviderAppKey
    case jobTransportUnsupported
    case rateLimited
    case providerUnavailable(Int)
    case cancellationUnsupported
    case invalidResponse(String)
}

public protocol CloudVideoJobClient: Sendable {
    func submit(
        _ request: CloudVideoJobRequest,
        media: Data,
        consent: MediaUploadConsent,
        bearerToken: String
    ) async throws -> CloudVideoJobReceipt
    func status(jobID: String, bearerToken: String) async throws -> CloudVideoJobReceipt
    func cancel(jobID: String, bearerToken: String) async throws -> CloudVideoJobReceipt
    func inlineRequestByteCount(_ request: CloudVideoJobRequest, media: Data) throws -> Int64
}

public extension CloudVideoJobClient {
    func cancel(jobID: String, bearerToken: String) async throws -> CloudVideoJobReceipt {
        throw CloudVideoJobError.cancellationUnsupported
    }

    func inlineRequestByteCount(_ request: CloudVideoJobRequest, media: Data) throws -> Int64 {
        Int64(try JSONEncoder().encode(CustomJSONJobBody(
            request: request,
            mediaBase64: media.base64EncodedString()
        )).count)
    }
}

private struct CustomJSONJobBody: Encodable {
    let request: CloudVideoJobRequest
    let mediaBase64: String
}

/// Async full-video/cloud-ASR job transport. Callers must probe capabilities and
/// collect explicit consent before invoking this client.
public struct URLSessionCloudVideoJobClient: CloudVideoJobClient {
    private let profile: CloudProviderProfile
    private let session: URLSession
    /// Provider credential supplied at runtime only. It is intentionally absent from the Codable
    /// profile, checkpoints and diagnostics so an App ID is never persisted as analysis evidence.
    private let doubaoAppKey: String?

    public init(
        profile: CloudProviderProfile,
        session: URLSession = .shared,
        doubaoAppKey: String? = nil
    ) {
        self.profile = profile
        self.session = session
        self.doubaoAppKey = doubaoAppKey
    }

    public func submit(
        _ request: CloudVideoJobRequest,
        media: Data,
        consent: MediaUploadConsent,
        bearerToken: String
    ) async throws -> CloudVideoJobReceipt {
        guard consent.allowsUpload else { throw CloudVideoJobError.uploadNotConsented }
        guard media.count <= consent.maximumBytes, Int64(media.count) == request.byteCount else {
            throw CloudVideoJobError.uploadExceedsConsent
        }
        if profile.transport == .doubaoAsyncASR {
            // The standard asynchronous AUC contract accepts an online HTTPS/TOS object URL,
            // not inline Base64. The flash endpoint has a different synchronous contract and
            // must not be silently substituted here.
            throw CloudVideoJobError.remoteMediaRequired
        }
        guard profile.transport == .customJSONJob else {
            throw CloudVideoJobError.jobTransportUnsupported
        }
        var urlRequest = URLRequest(url: profile.jobURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try customJobBody(request, media: media)
        return try await execute(urlRequest)
    }

    /// Exact byte count of the custom gateway's JSON payload, including inline Base64 media.
    public func inlineRequestByteCount(
        _ request: CloudVideoJobRequest,
        media: Data
    ) throws -> Int64 {
        guard profile.transport == .customJSONJob else {
            throw CloudVideoJobError.jobTransportUnsupported
        }
        return Int64(try customJobBody(request, media: media).count)
    }

    /// Submit media already staged at an HTTPS URL to the provider's documented async endpoint.
    /// The URL remains request-local and is never copied into receipts, checkpoints or errors.
    public func submitRemoteMedia(
        _ request: CloudVideoJobRequest,
        mediaURL: URL,
        consent: MediaUploadConsent,
        bearerToken: String
    ) async throws -> CloudVideoJobReceipt {
        guard consent.allowsUpload else { throw CloudVideoJobError.uploadNotConsented }
        guard request.byteCount <= consent.maximumBytes else {
            throw CloudVideoJobError.uploadExceedsConsent
        }
        guard mediaURL.scheme?.lowercased() == "https", mediaURL.host != nil else {
            throw CloudVideoJobError.invalidRemoteMediaURL
        }
        guard profile.transport == .doubaoAsyncASR else {
            throw CloudVideoJobError.invalidResponse("remote-media submit is unsupported for this provider transport")
        }
        return try await submitDoubaoASR(request, mediaURL: mediaURL, accessKey: bearerToken)
    }

    public func status(jobID: String, bearerToken: String) async throws -> CloudVideoJobReceipt {
        if profile.transport == .doubaoAsyncASR {
            return try await queryDoubaoASR(jobID: jobID, accessKey: bearerToken)
        }
        guard profile.transport == .customJSONJob else {
            throw CloudVideoJobError.jobTransportUnsupported
        }
        let safeID = jobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var request = URLRequest(url: profile.jobURL.appendingPathComponent(safeID))
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return try await execute(request)
    }

    public func cancel(jobID: String, bearerToken: String) async throws -> CloudVideoJobReceipt {
        // Doubao recording-file ASR documents submit/query but no provider-side cancellation API.
        // Do not synthesize DELETE /jobs/{id}; local callers can stop polling and retain the job ID.
        guard profile.transport == .customJSONJob,
              profile.declaredCapabilities.contains(.jobCancellation)
        else { throw CloudVideoJobError.cancellationUnsupported }
        let safeID = jobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var request = URLRequest(url: profile.jobURL.appendingPathComponent(safeID))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return try await execute(request)
    }

    private func submitDoubaoASR(
        _ request: CloudVideoJobRequest,
        mediaURL: URL,
        accessKey: String
    ) async throws -> CloudVideoJobReceipt {
        guard let doubaoAppKey, !doubaoAppKey.isEmpty else {
            throw CloudVideoJobError.missingProviderAppKey
        }
        struct User: Encodable { let uid: String }
        struct Audio: Encodable { let url: URL }
        struct RecognitionRequest: Encodable { let modelName = "bigmodel" }
        struct Body: Encodable {
            let user: User
            let audio: Audio
            let request: RecognitionRequest
        }
        var urlRequest = URLRequest(url: doubaoASREndpoint(action: "submit"))
        urlRequest.httpMethod = "POST"
        applyDoubaoASRHeaders(
            to: &urlRequest,
            appKey: doubaoAppKey,
            accessKey: accessKey,
            requestID: request.idempotencyKey,
            isSubmission: true
        )
        urlRequest.httpBody = try JSONEncoder().encode(Body(
            user: User(uid: doubaoAppKey),
            audio: Audio(url: mediaURL),
            request: RecognitionRequest()
        ))
        return try await executeDoubaoASR(
            urlRequest,
            fallbackJobID: request.idempotencyKey,
            idempotencyKey: request.idempotencyKey,
            isSubmission: true
        )
    }

    private func customJobBody(_ request: CloudVideoJobRequest, media: Data) throws -> Data {
        try JSONEncoder().encode(CustomJSONJobBody(
            request: request,
            mediaBase64: media.base64EncodedString()
        ))
    }

    private func queryDoubaoASR(jobID: String, accessKey: String) async throws -> CloudVideoJobReceipt {
        guard let doubaoAppKey, !doubaoAppKey.isEmpty else {
            throw CloudVideoJobError.missingProviderAppKey
        }
        var request = URLRequest(url: doubaoASREndpoint(action: "query"))
        request.httpMethod = "POST"
        applyDoubaoASRHeaders(
            to: &request,
            appKey: doubaoAppKey,
            accessKey: accessKey,
            requestID: jobID,
            isSubmission: false
        )
        request.httpBody = Data("{}".utf8)
        return try await executeDoubaoASR(
            request,
            fallbackJobID: jobID,
            idempotencyKey: jobID,
            isSubmission: false
        )
    }

    private func applyDoubaoASRHeaders(
        to request: inout URLRequest,
        appKey: String,
        accessKey: String,
        requestID: String,
        isSubmission: Bool
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appKey, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue("volc.bigasr.auc", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        if isSubmission { request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence") }
    }

    private func doubaoASREndpoint(action: String) -> URL {
        let absolute = profile.jobURL.absoluteString
        for existingAction in ["submit", "query"] where absolute.hasSuffix("/\(existingAction)") {
            return URL(string: String(absolute.dropLast(existingAction.count)) + action) ?? profile.jobURL
        }
        return profile.jobURL.appendingPathComponent(action)
    }

    private func executeDoubaoASR(
        _ request: URLRequest,
        fallbackJobID: String,
        idempotencyKey: String,
        isSubmission: Bool
    ) async throws -> CloudVideoJobReceipt {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        try validateHTTPStatus(status)
        if let receipt = try? JSONDecoder().decode(CloudVideoJobReceipt.self, from: data) {
            return receipt
        }

        struct AudioInfo: Decodable { let duration: Int64? }
        struct Utterance: Decodable {
            let startTime: Int64
            let endTime: Int64
            let text: String

            enum CodingKeys: String, CodingKey {
                case startTime = "start_time"
                case endTime = "end_time"
                case text
            }
        }
        struct Result: Decodable { let utterances: [Utterance]? }
        struct Payload: Decodable {
            let audioInfo: AudioInfo?
            let result: Result?

            enum CodingKeys: String, CodingKey {
                case audioInfo = "audio_info"
                case result
            }
        }
        let payload = try? JSONDecoder().decode(Payload.self, from: data)
        let providerCode = http?.value(forHTTPHeaderField: "X-Api-Status-Code")
        let state: CloudVideoJobState = switch providerCode {
        case "20000000": isSubmission ? .queued : .completed
        case "20000001": .running
        case "20000002": .queued
        case .none where isSubmission: .queued
        default: .failed
        }
        let observations = (payload?.result?.utterances ?? []).enumerated().map { index, utterance in
            CloudTimelineObservation(
                id: "asr-\(index)",
                startSeconds: Double(utterance.startTime) / 1_000,
                endSeconds: Double(utterance.endTime) / 1_000,
                text: utterance.text,
                confidence: 1,
                kind: .transcript
            )
        }
        let providerMessage = http?.value(forHTTPHeaderField: "X-Api-Message")
        return CloudVideoJobReceipt(
            jobID: fallbackJobID,
            state: state,
            observations: observations,
            sanitizedError: state == .failed ? providerMessage : nil,
            idempotencyKey: idempotencyKey,
            usage: CloudProviderUsage(
                requestCount: 1,
                mediaMilliseconds: payload?.audioInfo?.duration ?? 0
            ),
            cancellationSupported: false
        )
    }

    private func execute(_ request: URLRequest) async throws -> CloudVideoJobReceipt {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try validateHTTPStatus(status)
        guard let receipt = try? JSONDecoder().decode(CloudVideoJobReceipt.self, from: data) else {
            throw CloudVideoJobError.invalidResponse("HTTP \(status): undecodable provider response")
        }
        return receipt
    }

    private func validateHTTPStatus(_ status: Int) throws {
        if status == 429 { throw CloudVideoJobError.rateLimited }
        if (500..<600).contains(status) {
            throw CloudVideoJobError.providerUnavailable(status)
        }
        guard (200..<300).contains(status) else {
            // Provider bodies can contain transcripts, object URLs or vendor request details.
            // Preserve only the status classification at the transport boundary.
            throw CloudVideoJobError.invalidResponse("HTTP \(status): provider request failed")
        }
    }
}

public enum CloudTimelineObservationKind: String, Codable, Hashable, Sendable {
    case visual
    case transcript
    case audio
}

public struct CloudTimelineObservation: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let confidence: Double
    public let kind: CloudTimelineObservationKind

    public init(id: String, startSeconds: Double, endSeconds: Double, text: String, confidence: Double, kind: CloudTimelineObservationKind) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.confidence = confidence
        self.kind = kind
    }
}

public struct AlignedCloudTimelineItem: Codable, Hashable, Sendable {
    public let observation: CloudTimelineObservation
    public let shotIDs: [ShotID]
    public let evidence: EvidenceRef
}

public struct CloudTimelineAlignment: Codable, Hashable, Sendable {
    public let authoritativeGraph: ShotGraph
    public let items: [AlignedCloudTimelineItem]
    public let shotsNeedingReview: [ShotID]
}

public enum CloudTimelineAligner {
    public static func align(
        _ observations: [CloudTimelineObservation],
        to graph: ShotGraph,
        reviewThreshold: Double = 0.6
    ) -> CloudTimelineAlignment {
        var review = Set<ShotID>()
        let items = observations.map { observation in
            let range = MediaTimeRange(startSeconds: observation.startSeconds, endSeconds: observation.endSeconds)
            let shotIDs = graph.shots.filter {
                min($0.timeRange.endSeconds, range.endSeconds) > max($0.timeRange.startSeconds, range.startSeconds)
            }.map(\.id)
            if observation.confidence < reviewThreshold { review.formUnion(shotIDs) }
            let kind: EvidenceKind = observation.kind == .transcript ? .transcript : (observation.kind == .audio ? .audio : .cloudTimeline)
            let evidence = EvidenceRef(
                id: EvidenceID(rawValue: "cloud:\(observation.id)"),
                kind: kind, timeRange: range, frameRange: nil,
                payloadRef: "cloud/timeline/\(observation.id).json",
                source: .cloudModel, confidence: observation.confidence,
                rawText: observation.text
            )
            return AlignedCloudTimelineItem(observation: observation, shotIDs: shotIDs, evidence: evidence)
        }
        return CloudTimelineAlignment(
            authoritativeGraph: graph,
            items: items,
            shotsNeedingReview: review.sorted()
        )
    }
}

public struct CloudRefinementPlan: Codable, Hashable, Sendable {
    public let shotIDs: [ShotID]
    public let reason: String
}

public enum CloudRefinementPlanner {
    public static func plan(_ alignment: CloudTimelineAlignment) -> CloudRefinementPlan {
        CloudRefinementPlan(
            shotIDs: alignment.shotsNeedingReview,
            reason: "Only low-confidence aligned shots are eligible for focused refinement."
        )
    }
}

public enum CloudErrorSanitizer {
    public static func sanitize(_ raw: String) -> String {
        var value = raw
        let replacements = [
            (#"(?i)Bearer\s+[^\s]+"#, "Bearer [REDACTED]"),
            (#"(?i)sk-[A-Za-z0-9_-]+"#, "[REDACTED_KEY]"),
            (#"/Users/[^\s?]+"#, "[LOCAL_PATH]"),
            (#"(?i)(token|api_key|apikey|key)=[^&\s]+"#, "$1=[REDACTED]"),
        ]
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            value = regex.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value),
                withTemplate: replacement
            )
        }
        return value
    }
}
