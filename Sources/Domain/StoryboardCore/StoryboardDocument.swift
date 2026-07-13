import Foundation
import VideoUnderstanding

public enum StoryboardMode: String, Codable, Hashable, Sendable {
    case faithful
    case adapted
    case analysisOnly
}

public enum EffectiveCloudMode: String, Codable, Hashable, Sendable {
    case local
    case cloudStandard
    case cloudDeep
}

public struct StoryboardSource: Codable, Hashable, Sendable {
    public let sourceID: String
    public let runID: String
    public let schemaVersion: Int
    public let pipelineVersion: String
    public let mode: StoryboardMode
    public let actualCloudMode: EffectiveCloudMode
    public let mediaUploaded: Bool
    public let cloudTelemetry: AnalysisCloudTelemetry?
    public let degradationNote: String?

    public init(
        sourceID: String,
        runID: String,
        schemaVersion: Int,
        pipelineVersion: String,
        mode: StoryboardMode,
        actualCloudMode: EffectiveCloudMode,
        mediaUploaded: Bool,
        cloudTelemetry: AnalysisCloudTelemetry? = nil,
        degradationNote: String? = nil
    ) {
        self.sourceID = sourceID
        self.runID = runID
        self.schemaVersion = schemaVersion
        self.pipelineVersion = pipelineVersion
        self.mode = mode
        self.actualCloudMode = actualCloudMode
        self.mediaUploaded = mediaUploaded
        self.cloudTelemetry = cloudTelemetry
        self.degradationNote = degradationNote
    }
}

public enum FactField: String, Codable, CaseIterable, Hashable, Sendable {
    case subject
    case character
    case action
    case interaction
    case location
    case environment
    case timeOfDay
    case prop
    case product
    case shotSize
    case cameraAngle
    case cameraMovement
    case composition
    case focalAttention
    case lighting
    case colorPalette
    case visualStyle
    case visibleText
    case audioSummary
    case musicCue
    case soundEffect
    case continuity
}

public struct GroundedFact: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let field: FactField
    public let value: String
    public let evidenceIDs: [EvidenceID]
    public let source: EvidenceSource
    public let confidence: Double
    public let reviewFlags: [String]

    public init(
        id: String? = nil,
        field: FactField,
        value: String,
        evidenceIDs: [EvidenceID],
        source: EvidenceSource,
        confidence: Double,
        reviewFlags: [String] = []
    ) {
        self.id = id ?? "\(field.rawValue):\(value)"
        self.field = field
        self.value = value
        self.evidenceIDs = evidenceIDs
        self.source = source
        self.confidence = confidence
        self.reviewFlags = reviewFlags
    }
}

public struct ObservedShotFacts: Codable, Hashable, Sendable {
    public let facts: [GroundedFact]
    public let unknownFields: [FactField]
    public let modelConfidence: Double?
    public let reviewFlags: [String]

    public init(
        facts: [GroundedFact],
        unknownFields: [FactField] = [],
        modelConfidence: Double? = nil,
        reviewFlags: [String] = []
    ) {
        self.facts = facts
        self.unknownFields = unknownFields
        self.modelConfidence = modelConfidence
        self.reviewFlags = reviewFlags
    }
}

public struct ShotProductionPlan: Codable, Hashable, Sendable {
    public let shotID: ShotID
    public let sequenceID: String?
    public let displayNumber: Int
    public let purpose: String?
    public let narrativeBeat: String?
    public let hookRole: String?
    public let targetDuration: Double?
    public let shotSize: String?
    public let angle: String?
    public let movement: String?
    public let lensIntent: String?
    public let subjectAction: String?
    public let composition: String?
    public let background: String?
    public let lightingColor: String?
    public let propsWardrobe: String?
    public let dialogueOrVO: String?
    public let onScreenCopy: String?
    public let musicSFX: String?
    public let transition: String?
    public let continuity: String?
    public let generationPrompt: String?
    public let productionNotes: String?
    public let sourceShotRefs: [ShotID]
    public let confidence: Double?
    public let userLockedFields: Set<String>
    public let isDerivedCreativePlan: Bool

    public init(
        shotID: ShotID,
        sequenceID: String? = nil,
        displayNumber: Int,
        purpose: String? = nil,
        narrativeBeat: String? = nil,
        hookRole: String? = nil,
        targetDuration: Double? = nil,
        shotSize: String? = nil,
        angle: String? = nil,
        movement: String? = nil,
        lensIntent: String? = nil,
        subjectAction: String? = nil,
        composition: String? = nil,
        background: String? = nil,
        lightingColor: String? = nil,
        propsWardrobe: String? = nil,
        dialogueOrVO: String? = nil,
        onScreenCopy: String? = nil,
        musicSFX: String? = nil,
        transition: String? = nil,
        continuity: String? = nil,
        generationPrompt: String? = nil,
        productionNotes: String? = nil,
        sourceShotRefs: [ShotID],
        confidence: Double? = nil,
        userLockedFields: Set<String> = [],
        isDerivedCreativePlan: Bool
    ) {
        self.shotID = shotID
        self.sequenceID = sequenceID
        self.displayNumber = displayNumber
        self.purpose = purpose
        self.narrativeBeat = narrativeBeat
        self.hookRole = hookRole
        self.targetDuration = targetDuration
        self.shotSize = shotSize
        self.angle = angle
        self.movement = movement
        self.lensIntent = lensIntent
        self.subjectAction = subjectAction
        self.composition = composition
        self.background = background
        self.lightingColor = lightingColor
        self.propsWardrobe = propsWardrobe
        self.dialogueOrVO = dialogueOrVO
        self.onScreenCopy = onScreenCopy
        self.musicSFX = musicSFX
        self.transition = transition
        self.continuity = continuity
        self.generationPrompt = generationPrompt
        self.productionNotes = productionNotes
        self.sourceShotRefs = sourceShotRefs
        self.confidence = confidence
        self.userLockedFields = userLockedFields
        self.isDerivedCreativePlan = isDerivedCreativePlan
    }
}

public struct StoryboardShotV2: Codable, Hashable, Sendable, Identifiable {
    public let id: ShotID
    public let observedFacts: ObservedShotFacts
    public let productionPlan: ShotProductionPlan?
    public let userLockedFields: Set<String>

    public init(
        id: ShotID,
        observedFacts: ObservedShotFacts,
        productionPlan: ShotProductionPlan? = nil,
        userLockedFields: Set<String> = []
    ) {
        self.id = id
        self.observedFacts = observedFacts
        self.productionPlan = productionPlan
        self.userLockedFields = userLockedFields
    }
}

public struct ContentAnalysis: Codable, Hashable, Sendable {
    public let title: String?
    public let summary: String
    public let themes: [String]
    public let hook: String?
    public let retentionDevices: [String]
    public let payoff: String?
    public let callToAction: String?
    public let referencedShotIDs: [ShotID]

    public init(
        title: String? = nil,
        summary: String,
        themes: [String] = [],
        hook: String? = nil,
        retentionDevices: [String] = [],
        payoff: String? = nil,
        callToAction: String? = nil,
        referencedShotIDs: [ShotID]
    ) {
        self.title = title
        self.summary = summary
        self.themes = themes
        self.hook = hook
        self.retentionDevices = retentionDevices
        self.payoff = payoff
        self.callToAction = callToAction
        self.referencedShotIDs = referencedShotIDs
    }
}

public struct StoryboardDocumentV2: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let source: StoryboardSource
    public let shotGraph: ShotGraph
    public let shots: [StoryboardShotV2]
    public let contentAnalysis: ContentAnalysis

    public init(
        id: String,
        source: StoryboardSource,
        shotGraph: ShotGraph,
        shots: [StoryboardShotV2],
        contentAnalysis: ContentAnalysis
    ) {
        self.id = id
        self.source = source
        self.shotGraph = shotGraph
        self.shots = shots
        self.contentAnalysis = contentAnalysis
    }
}

public enum QualityStatus: String, Codable, Hashable, Sendable {
    case clean
    case partial
    case degraded
    case needsReview
    case failed
}

public enum QualitySeverity: String, Codable, Hashable, Sendable {
    case info
    case warning
    case error
}

public struct QualityIssue: Codable, Hashable, Sendable {
    public let code: String
    public let severity: QualitySeverity
    public let shotID: ShotID?
    public let detail: String

    public init(code: String, severity: QualitySeverity, shotID: ShotID?, detail: String) {
        self.code = code
        self.severity = severity
        self.shotID = shotID
        self.detail = detail
    }
}

public struct QualityReport: Codable, Hashable, Sendable {
    public let status: QualityStatus
    public let issues: [QualityIssue]
    public let machineFactCount: Int
    public let groundedMachineFactCount: Int

    public init(
        status: QualityStatus,
        issues: [QualityIssue],
        machineFactCount: Int,
        groundedMachineFactCount: Int
    ) {
        self.status = status
        self.issues = issues
        self.machineFactCount = machineFactCount
        self.groundedMachineFactCount = groundedMachineFactCount
    }

    public var evidenceLinkCoverage: Double {
        machineFactCount == 0 ? 1 : Double(groundedMachineFactCount) / Double(machineFactCount)
    }
}

public enum StoryboardValidator {
    public static func validate(document: StoryboardDocumentV2, evidence: [EvidenceRef]) -> QualityReport {
        let graphIDs = Set(document.shotGraph.shots.map(\.id))
        let documentIDs = Set(document.shots.map(\.id))
        let evidenceByID = Dictionary(grouping: evidence, by: \.id)
        var issues: [QualityIssue] = []
        var machineFactCount = 0
        var groundedMachineFactCount = 0

        if graphIDs != documentIDs {
            issues.append(QualityIssue(
                code: "shot-document-mismatch",
                severity: .error,
                shotID: nil,
                detail: "Document shots must match the authoritative ShotGraph."
            ))
        }
        if document.source.actualCloudMode == .local, document.source.mediaUploaded {
            issues.append(QualityIssue(
                code: "local-mode-uploaded-media",
                severity: .error,
                shotID: nil,
                detail: "Local mode cannot upload media."
            ))
        }
        for shot in document.shots {
            let segment = document.shotGraph.shots.first { $0.id == shot.id }
            if shot.observedFacts.facts.isEmpty,
               shot.observedFacts.reviewFlags.contains(where: { $0.hasPrefix("shot-understanding-failed") }) {
                issues.append(QualityIssue(
                    code: "factless-failed-shot",
                    severity: .error,
                    shotID: shot.id,
                    detail: "A failed shot-understanding result cannot pass as a clean factless shot."
                ))
            }
            for fact in shot.observedFacts.facts where fact.source != .user {
                machineFactCount += 1
                let linked = fact.evidenceIDs.flatMap { evidenceByID[$0] ?? [] }
                let linksResolve = !fact.evidenceIDs.isEmpty
                    && fact.evidenceIDs.allSatisfy { evidenceByID[$0]?.count == 1 }
                if !linksResolve {
                    issues.append(QualityIssue(
                        code: "unsupported-machine-fact",
                        severity: .error,
                        shotID: shot.id,
                        detail: "Machine facts require unique, resolvable evidence links."
                    ))
                    continue
                }

                let allowedKinds = allowedEvidenceKinds(for: fact.field)
                let kindMatches = !linked.isEmpty && linked.allSatisfy { allowedKinds.contains($0.kind) }
                if !kindMatches {
                    issues.append(QualityIssue(
                        code: "evidence-kind-mismatch",
                        severity: .error,
                        shotID: shot.id,
                        detail: "Evidence kind does not support \(fact.field.rawValue)."
                    ))
                }
                let overlapsShot = segment.map { owningShot in
                    linked.allSatisfy { overlaps($0, owningShot) }
                } ?? false
                if !overlapsShot {
                    issues.append(QualityIssue(
                        code: "evidence-outside-shot",
                        severity: .error,
                        shotID: shot.id,
                        detail: "Fact evidence must overlap its owning shot."
                    ))
                }
                let payloadsValid = linked.allSatisfy { isSafePayloadReference($0.payloadRef) }
                if !payloadsValid {
                    issues.append(QualityIssue(
                        code: "invalid-evidence-payload",
                        severity: .error,
                        shotID: shot.id,
                        detail: "Evidence payload references must be non-empty workspace-relative paths."
                    ))
                }
                let textMatches = textEvidenceMatches(fact: fact, evidence: linked)
                if !textMatches {
                    issues.append(QualityIssue(
                        code: "evidence-text-mismatch",
                        severity: .error,
                        shotID: shot.id,
                        detail: "OCR/ASR-backed facts must be verifiable against raw or corrected evidence text."
                    ))
                }

                if kindMatches, overlapsShot, payloadsValid, textMatches {
                    groundedMachineFactCount += 1
                }
            }
            if let plan = shot.productionPlan {
                if !plan.isDerivedCreativePlan || !plan.sourceShotRefs.allSatisfy(graphIDs.contains) {
                    issues.append(QualityIssue(
                        code: "invalid-production-plan-provenance",
                        severity: .error,
                        shotID: shot.id,
                        detail: "Production plans must be marked derived and cite source shots."
                    ))
                }
            }
        }
        if !document.contentAnalysis.referencedShotIDs.allSatisfy(graphIDs.contains) {
            issues.append(QualityIssue(
                code: "content-analysis-orphan-shot",
                severity: .error,
                shotID: nil,
                detail: "Content analysis references an unknown shot."
            ))
        }

        let status: QualityStatus
        if issues.contains(where: { $0.code == "shot-document-mismatch" }) {
            status = .failed
        } else if !issues.isEmpty {
            status = .needsReview
        } else if document.source.degradationNote != nil {
            status = .degraded
        } else {
            status = .clean
        }
        return QualityReport(
            status: status,
            issues: issues,
            machineFactCount: machineFactCount,
            groundedMachineFactCount: groundedMachineFactCount
        )
    }

    private static func allowedEvidenceKinds(for field: FactField) -> Set<EvidenceKind> {
        switch field {
        case .visibleText:
            return [.ocr]
        case .audioSummary, .musicCue, .soundEffect:
            return [.transcript, .audio]
        default:
            return [.frame, .ocr, .cloudTimeline]
        }
    }

    private static func overlaps(_ evidence: EvidenceRef, _ shot: ShotSegment) -> Bool {
        let timeOverlap = min(evidence.timeRange.endSeconds, shot.timeRange.endSeconds)
            - max(evidence.timeRange.startSeconds, shot.timeRange.startSeconds)
        if timeOverlap > 0 { return true }
        guard let evidenceFrames = evidence.frameRange else { return false }
        return min(evidenceFrames.endFrameExclusive, shot.frameRange.endFrameExclusive)
            - max(evidenceFrames.startFrame, shot.frameRange.startFrame) > 0
    }

    private static func isSafePayloadReference(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains(".."),
              URL(string: normalized)?.scheme == nil
        else { return false }
        return true
    }

    private static func textEvidenceMatches(fact: GroundedFact, evidence: [EvidenceRef]) -> Bool {
        guard fact.field == .visibleText || fact.field == .audioSummary else { return true }
        let expected = normalizedText(fact.value)
        guard !expected.isEmpty else { return false }
        return evidence.contains { item in
            let values = [item.rawText, item.correctedText].compactMap { $0 }.map(normalizedText)
            return values.contains { !$0.isEmpty && ($0.contains(expected) || expected.contains($0)) }
        }
    }

    private static func normalizedText(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
