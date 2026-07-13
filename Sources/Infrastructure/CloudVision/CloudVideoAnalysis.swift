import Foundation
import StoryboardCore
import VideoUnderstanding

public enum CloudCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case frameUnderstanding
    case fullVideo
    case cloudASR
    case asyncJobs
}

public struct CloudProviderProfile: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let capabilityURL: URL
    public let jobURL: URL
    public let declaredCapabilities: Set<CloudCapability>

    public init(
        id: String,
        displayName: String,
        capabilityURL: URL,
        jobURL: URL,
        declaredCapabilities: Set<CloudCapability>
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilityURL = capabilityURL
        self.jobURL = jobURL
        self.declaredCapabilities = declaredCapabilities
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

    public init(sourceID: String, sourceFingerprint: String, byteCount: Int64, requestedCapabilities: Set<CloudCapability>) {
        self.sourceID = sourceID
        self.sourceFingerprint = sourceFingerprint
        self.byteCount = max(0, byteCount)
        self.requestedCapabilities = requestedCapabilities
    }
}

public enum CloudVideoJobState: String, Codable, Hashable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public struct CloudVideoJobReceipt: Codable, Hashable, Sendable {
    public let jobID: String
    public let state: CloudVideoJobState
    public let observations: [CloudTimelineObservation]
    public let sanitizedError: String?
}

public enum CloudVideoJobError: Error, Hashable, Sendable {
    case uploadNotConsented
    case uploadExceedsConsent
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
}

/// Async full-video/cloud-ASR job transport. Callers must probe capabilities and
/// collect explicit consent before invoking this client.
public struct URLSessionCloudVideoJobClient: CloudVideoJobClient {
    private let profile: CloudProviderProfile
    private let session: URLSession

    public init(profile: CloudProviderProfile, session: URLSession = .shared) {
        self.profile = profile
        self.session = session
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
        struct Body: Encodable { let request: CloudVideoJobRequest; let mediaBase64: String }
        var urlRequest = URLRequest(url: profile.jobURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(Body(request: request, mediaBase64: media.base64EncodedString()))
        return try await execute(urlRequest)
    }

    public func status(jobID: String, bearerToken: String) async throws -> CloudVideoJobReceipt {
        let safeID = jobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var request = URLRequest(url: profile.jobURL.appendingPathComponent(safeID))
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return try await execute(request)
    }

    private func execute(_ request: URLRequest) async throws -> CloudVideoJobReceipt {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let receipt = try? JSONDecoder().decode(CloudVideoJobReceipt.self, from: data) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudVideoJobError.invalidResponse(CloudErrorSanitizer.sanitize("HTTP \(status): \(body)"))
        }
        return receipt
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
