import Foundation

/// Independently probed production roles. Role composition never turns one credential or a
/// declared model name into capabilities owned by another provider product.
public enum CloudProviderRole: String, Codable, CaseIterable, Hashable, Sendable, Comparable {
    case arkText
    case arkFrame
    case lasVideoStoryboard
    case lasVideoFineUnderstanding
    case lasScriptGeneration
    case lasEnhancedASR
    case mediaStaging

    public static let arkStandardRoles: Set<Self> = [.arkText, .arkFrame]
    public static let lasDeepRoles: Set<Self> = [
        .lasVideoStoryboard,
        .lasVideoFineUnderstanding,
        .lasScriptGeneration,
        .lasEnhancedASR,
        .mediaStaging,
    ]

    public var providerKind: CloudProviderKind {
        switch self {
        case .arkText, .arkFrame: .volcengineArk
        case .lasVideoStoryboard, .lasVideoFineUnderstanding,
             .lasScriptGeneration, .lasEnhancedASR: .volcengineLAS
        case .mediaStaging: .volcengineTOS
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum CloudProviderKind: String, Codable, Hashable, Sendable {
    case volcengineArk
    case volcengineLAS
    case volcengineTOS
}

public enum CloudCredentialScheme: String, Codable, Hashable, Sendable {
    case apiKey
    case temporarySTS
}

public enum CloudProbeLevel: String, Codable, Hashable, Sendable {
    case configuration
    case authenticated
    case liveMedia
}

public enum CloudCapabilityStatus: String, Codable, Hashable, Sendable {
    case available
    case unavailable
    case authFailed
    case unreachable
    case stale
}

public enum CloudAcceptedMediaKind: String, Codable, Hashable, Sendable {
    case imageURL
    case httpsObject
    case tosObject
    case video
    case audio
}

public struct CloudObservedLimits: Codable, Hashable, Sendable {
    public let maximumBytes: Int64?
    public let maximumDurationSeconds: Double?

    public init(maximumBytes: Int64? = nil, maximumDurationSeconds: Double? = nil) {
        self.maximumBytes = maximumBytes.map { max(0, $0) }
        self.maximumDurationSeconds = maximumDurationSeconds.map { max(0, $0) }
    }
}

/// Sanitized authorization evidence for one exact role/profile/config/credential tuple.
/// Raw provider bodies, media locators and credential values are intentionally not representable.
public struct CloudRoleCapabilitySnapshot: Codable, Hashable, Sendable {
    public let role: CloudProviderRole
    public let providerKind: CloudProviderKind
    public let profileID: String
    public let configurationFingerprint: String
    public let credentialScheme: CloudCredentialScheme
    public let credentialReferenceID: String
    public let probeLevel: CloudProbeLevel
    public let status: CloudCapabilityStatus
    public let observedCapabilities: Set<String>
    public let acceptedMediaKinds: Set<CloudAcceptedMediaKind>
    public let limits: CloudObservedLimits
    public let supportsAsync: Bool?
    public let supportsIdempotency: Bool?
    public let supportsCancellation: Bool?
    public let reportsUsage: Bool?
    public let lastProbedAt: Date
    public let expiresAt: Date
    public let officialContractRevision: String
    public let sanitizedEvidenceCode: String

    public init(
        role: CloudProviderRole,
        providerKind: CloudProviderKind,
        profileID: String,
        configurationFingerprint: String,
        credentialScheme: CloudCredentialScheme,
        credentialReferenceID: String,
        probeLevel: CloudProbeLevel,
        status: CloudCapabilityStatus,
        observedCapabilities: Set<String>,
        acceptedMediaKinds: Set<CloudAcceptedMediaKind>,
        limits: CloudObservedLimits,
        supportsAsync: Bool?,
        supportsIdempotency: Bool?,
        supportsCancellation: Bool?,
        reportsUsage: Bool?,
        lastProbedAt: Date,
        expiresAt: Date,
        officialContractRevision: String,
        sanitizedEvidenceCode: String
    ) {
        self.role = role
        self.providerKind = providerKind
        self.profileID = profileID
        self.configurationFingerprint = configurationFingerprint
        self.credentialScheme = credentialScheme
        self.credentialReferenceID = credentialReferenceID
        self.probeLevel = probeLevel
        self.status = status
        self.observedCapabilities = observedCapabilities
        self.acceptedMediaKinds = acceptedMediaKinds
        self.limits = limits
        self.supportsAsync = supportsAsync
        self.supportsIdempotency = supportsIdempotency
        self.supportsCancellation = supportsCancellation
        self.reportsUsage = reportsUsage
        self.lastProbedAt = lastProbedAt
        self.expiresAt = expiresAt
        self.officialContractRevision = officialContractRevision
        self.sanitizedEvidenceCode = CloudErrorSanitizer.sanitize(sanitizedEvidenceCode)
    }

    public func authorizes(expectedFingerprint: String, now: Date) -> Bool {
        status == .available
            && probeLevel == .liveMedia
            && configurationFingerprint == expectedFingerprint
            && now < expiresAt
    }

    /// Authentication rejection invalidates only this role. Rate-limit and provider 5xx errors are
    /// transient run failures and do not rewrite previously observed capability evidence.
    public func invalidated(forHTTPStatus httpStatus: Int) -> Self {
        guard httpStatus == 401 || httpStatus == 403 else { return self }
        return Self(
            role: role,
            providerKind: providerKind,
            profileID: profileID,
            configurationFingerprint: configurationFingerprint,
            credentialScheme: credentialScheme,
            credentialReferenceID: credentialReferenceID,
            probeLevel: probeLevel,
            status: .authFailed,
            observedCapabilities: observedCapabilities,
            acceptedMediaKinds: acceptedMediaKinds,
            limits: limits,
            supportsAsync: supportsAsync,
            supportsIdempotency: supportsIdempotency,
            supportsCancellation: supportsCancellation,
            reportsUsage: reportsUsage,
            lastProbedAt: lastProbedAt,
            expiresAt: lastProbedAt,
            officialContractRevision: officialContractRevision,
            sanitizedEvidenceCode: "authentication-rejected"
        )
    }
}

public enum CloudAnalysisRequestedMode: String, Codable, CaseIterable, Hashable, Sendable {
    case local
    case arkStandard
    case lasDeep
    case hybridMaximum
}

public enum CloudAnalysisEffectiveMode: String, Codable, Hashable, Sendable {
    case local
    case arkStandard
    case lasDeep
    case lasArkRefine
    case awaitingCapabilityProbe
    case awaitingConsent
    case requiresUserChoice
    case unavailable
}

public enum CloudExecutionAlternative: String, Codable, Hashable, Sendable {
    case arkStandard
    case lasDeep
    case local
    case cancel
}

public enum CloudCostAcceptance: Codable, Hashable, Sendable {
    case unknownMayCharge
    case knownEstimate(Decimal)
}

/// One video/run/plan authorization. It is never a reusable application setting.
public struct CloudRunConsentReceipt: Codable, Hashable, Sendable {
    public let runID: String
    public let sourceFingerprint: String
    public let planHash: String
    public let acceptedAt: Date
    public let maximumBytes: Int64
    public let maximumDurationSeconds: Double
    public let costAcceptance: CloudCostAcceptance

    public init(
        runID: String,
        sourceFingerprint: String,
        planHash: String,
        acceptedAt: Date,
        maximumBytes: Int64,
        maximumDurationSeconds: Double,
        costAcceptance: CloudCostAcceptance
    ) {
        self.runID = runID
        self.sourceFingerprint = sourceFingerprint
        self.planHash = planHash
        self.acceptedAt = acceptedAt
        self.maximumBytes = max(0, maximumBytes)
        self.maximumDurationSeconds = max(0, maximumDurationSeconds)
        self.costAcceptance = costAcceptance
    }
}

public struct CloudExecutionDecision: Codable, Hashable, Sendable {
    public let requestedMode: CloudAnalysisRequestedMode
    public let effectiveMode: CloudAnalysisEffectiveMode
    public let missingRoles: [CloudProviderRole]
    public let staleRoles: [CloudProviderRole]
    public let allowedAlternatives: [CloudExecutionAlternative]
    public let mediaUploadAllowed: Bool
    public let arkRefinementAllowed: Bool
    public let planHash: String
}

public enum CloudAnalysisPlanner {
    public static func resolve(
        requested: CloudAnalysisRequestedMode,
        snapshots: [CloudRoleCapabilitySnapshot],
        expectedFingerprints: [CloudProviderRole: String],
        consent: CloudRunConsentReceipt?,
        now: Date
    ) -> CloudExecutionDecision {
        let planHash = stablePlanHash(requested: requested, fingerprints: expectedFingerprints)
        guard requested != .local else {
            return decision(requested, .local, planHash: planHash)
        }

        let required: Set<CloudProviderRole> = switch requested {
        case .local: []
        case .arkStandard: CloudProviderRole.arkStandardRoles
        case .lasDeep: CloudProviderRole.lasDeepRoles
        case .hybridMaximum:
            CloudProviderRole.lasDeepRoles.union(CloudProviderRole.arkStandardRoles)
        }
        let latest = Dictionary(grouping: snapshots, by: \ .role).compactMapValues {
            $0.max { $0.lastProbedAt < $1.lastProbedAt }
        }
        var missing: [CloudProviderRole] = []
        var stale: [CloudProviderRole] = []
        for role in required.sorted() {
            guard let fingerprint = expectedFingerprints[role], let snapshot = latest[role] else {
                missing.append(role)
                continue
            }
            if snapshot.status == .available,
               snapshot.configurationFingerprint == fingerprint,
               snapshot.probeLevel == .liveMedia,
               now >= snapshot.expiresAt {
                stale.append(role)
            } else if !snapshot.authorizes(expectedFingerprint: fingerprint, now: now) {
                missing.append(role)
            }
        }

        if !stale.isEmpty {
            return CloudExecutionDecision(
                requestedMode: requested,
                effectiveMode: .awaitingCapabilityProbe,
                missingRoles: missing,
                staleRoles: stale,
                allowedAlternatives: [],
                mediaUploadAllowed: false,
                arkRefinementAllowed: false,
                planHash: planHash
            )
        }
        if !missing.isEmpty {
            return CloudExecutionDecision(
                requestedMode: requested,
                effectiveMode: .requiresUserChoice,
                missingRoles: missing,
                staleRoles: [],
                allowedAlternatives: alternatives(
                    requested: requested,
                    snapshots: latest,
                    fingerprints: expectedFingerprints,
                    now: now
                ),
                mediaUploadAllowed: false,
                arkRefinementAllowed: false,
                planHash: planHash
            )
        }

        if requested == .arkStandard {
            return decision(requested, .arkStandard, planHash: planHash)
        }
        guard consent?.planHash == planHash else {
            return decision(requested, .awaitingConsent, planHash: planHash)
        }
        return decision(
            requested,
            requested == .hybridMaximum ? .lasArkRefine : .lasDeep,
            upload: true,
            refine: requested == .hybridMaximum,
            planHash: planHash
        )
    }

    private static func alternatives(
        requested: CloudAnalysisRequestedMode,
        snapshots: [CloudProviderRole: CloudRoleCapabilitySnapshot],
        fingerprints: [CloudProviderRole: String],
        now: Date
    ) -> [CloudExecutionAlternative] {
        func allFresh(_ roles: Set<CloudProviderRole>) -> Bool {
            roles.allSatisfy { role in
                guard let snapshot = snapshots[role], let fingerprint = fingerprints[role] else { return false }
                return snapshot.authorizes(expectedFingerprint: fingerprint, now: now)
            }
        }
        if requested == .hybridMaximum, allFresh(CloudProviderRole.lasDeepRoles) {
            return [.lasDeep, .local, .cancel]
        }
        if requested == .lasDeep, allFresh(CloudProviderRole.arkStandardRoles) {
            return [.arkStandard, .local, .cancel]
        }
        return [.local, .cancel]
    }

    private static func decision(
        _ requested: CloudAnalysisRequestedMode,
        _ effective: CloudAnalysisEffectiveMode,
        upload: Bool = false,
        refine: Bool = false,
        planHash: String
    ) -> CloudExecutionDecision {
        CloudExecutionDecision(
            requestedMode: requested,
            effectiveMode: effective,
            missingRoles: [],
            staleRoles: [],
            allowedAlternatives: [],
            mediaUploadAllowed: upload,
            arkRefinementAllowed: refine,
            planHash: planHash
        )
    }

    private static func stablePlanHash(
        requested: CloudAnalysisRequestedMode,
        fingerprints: [CloudProviderRole: String]
    ) -> String {
        let input = (["cloud-plan-v1", requested.rawValue] + fingerprints.keys.sorted().map {
            "\($0.rawValue)=\(fingerprints[$0] ?? "")"
        }).joined(separator: "|")
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return String(value, radix: 16)
    }
}
