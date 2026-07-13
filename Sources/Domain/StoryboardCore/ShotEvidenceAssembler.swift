import Foundation
import VideoUnderstanding

public enum ShotEvidenceClassification: String, Codable, Hashable, Sendable {
    case multimodal
    case visualOnly
    case speechOnly
    case evidencePoor
}

public struct ShotEvidence: Codable, Hashable, Sendable, Identifiable {
    public let id: ShotID
    public let evidenceIDs: [EvidenceID]
    public let classification: ShotEvidenceClassification

    public init(id: ShotID, evidenceIDs: [EvidenceID], classification: ShotEvidenceClassification) {
        self.id = id
        self.evidenceIDs = evidenceIDs
        self.classification = classification
    }
}

public struct EvidenceCoverageReport: Codable, Hashable, Sendable {
    public let totalShots: Int
    public let shotsWithEvidence: Int
    public let orphanEvidenceIDs: [EvidenceID]
    public let sharedEvidenceIDs: [EvidenceID]

    public init(
        totalShots: Int,
        shotsWithEvidence: Int,
        orphanEvidenceIDs: [EvidenceID],
        sharedEvidenceIDs: [EvidenceID]
    ) {
        self.totalShots = totalShots
        self.shotsWithEvidence = shotsWithEvidence
        self.orphanEvidenceIDs = orphanEvidenceIDs
        self.sharedEvidenceIDs = sharedEvidenceIDs
    }
}

public struct ShotEvidenceAssemblyResult: Codable, Hashable, Sendable {
    public let shots: [ShotEvidence]
    public let coverage: EvidenceCoverageReport

    public init(shots: [ShotEvidence], coverage: EvidenceCoverageReport) {
        self.shots = shots
        self.coverage = coverage
    }
}

public enum ShotEvidenceAssembler {
    public static func assemble(graph: ShotGraph, evidence: [EvidenceRef]) -> ShotEvidenceAssemblyResult {
        let sortedEvidence = evidence.sorted { $0.id < $1.id }
        var matchCounts: [EvidenceID: Int] = [:]
        var assembled: [ShotEvidence] = []

        for shot in graph.shots {
            let matched = sortedEvidence.filter { overlaps($0, shot) }
            for item in matched {
                matchCounts[item.id, default: 0] += 1
            }
            assembled.append(ShotEvidence(
                id: shot.id,
                evidenceIDs: matched.map(\.id),
                classification: classification(for: matched)
            ))
        }

        let orphan = sortedEvidence.map(\.id).filter { matchCounts[$0, default: 0] == 0 }
        let shared = sortedEvidence.map(\.id).filter { matchCounts[$0, default: 0] > 1 }
        return ShotEvidenceAssemblyResult(
            shots: assembled,
            coverage: EvidenceCoverageReport(
                totalShots: graph.shots.count,
                shotsWithEvidence: assembled.filter { !$0.evidenceIDs.isEmpty }.count,
                orphanEvidenceIDs: orphan,
                sharedEvidenceIDs: shared
            )
        )
    }

    private static func overlaps(_ evidence: EvidenceRef, _ shot: ShotSegment) -> Bool {
        let timeOverlap = min(evidence.timeRange.endSeconds, shot.timeRange.endSeconds)
            - max(evidence.timeRange.startSeconds, shot.timeRange.startSeconds)
        if timeOverlap > 0 { return true }
        guard let evidenceFrames = evidence.frameRange else { return false }
        return min(evidenceFrames.endFrameExclusive, shot.frameRange.endFrameExclusive)
            - max(evidenceFrames.startFrame, shot.frameRange.startFrame) > 0
    }

    private static func classification(for evidence: [EvidenceRef]) -> ShotEvidenceClassification {
        let hasVisual = evidence.contains { $0.kind == .frame || $0.kind == .ocr }
        let hasSpeech = evidence.contains { $0.kind == .transcript }
        if hasVisual && hasSpeech { return .multimodal }
        if hasVisual { return .visualOnly }
        if hasSpeech { return .speechOnly }
        return .evidencePoor
    }
}
