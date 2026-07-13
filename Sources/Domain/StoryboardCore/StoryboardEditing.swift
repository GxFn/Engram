import Foundation
import VideoUnderstanding

public enum EditablePlanField: String, Codable, Hashable, Sendable, CaseIterable {
    case purpose
    case subjectAction
    case dialogueOrVO
    case onScreenCopy
    case productionNotes
}

public enum StoryboardFieldProvenance: String, Codable, Hashable, Sendable {
    case model
    case user
}

public struct ShotRemap: Codable, Hashable, Sendable {
    public let mapping: [ShotID: [ShotID]]

    public init(mapping: [ShotID: [ShotID]]) { self.mapping = mapping }
    public func targets(for shotID: ShotID) -> [ShotID] { mapping[shotID] ?? [] }
}

public struct StoryboardDiff: Codable, Hashable, Sendable {
    public let changedShotIDs: [ShotID]
    public let changedFields: Set<EditablePlanField>
    public let fieldProvenance: [EditablePlanField: StoryboardFieldProvenance]
    public let preservedLockedFields: Set<EditablePlanField>

    public init(
        changedShotIDs: [ShotID],
        changedFields: Set<EditablePlanField> = [],
        fieldProvenance: [EditablePlanField: StoryboardFieldProvenance] = [:],
        preservedLockedFields: Set<EditablePlanField> = []
    ) {
        self.changedShotIDs = changedShotIDs
        self.changedFields = changedFields
        self.fieldProvenance = fieldProvenance
        self.preservedLockedFields = preservedLockedFields
    }
}

public struct PartialRerunPlan: Codable, Hashable, Sendable {
    public let affectedShotIDs: [ShotID]
    public let invalidatedStages: [AnalysisStage]
    public let preservedLockedFields: Set<EditablePlanField>
}

public struct StoryboardEditResult: Sendable {
    public let original: StoryboardDocumentV2
    public let document: StoryboardDocumentV2
    public let remap: ShotRemap
    public let diff: StoryboardDiff
    public let partialRerun: PartialRerunPlan

    public func undo() -> StoryboardDocumentV2 { original }
}

public enum StoryboardEditingError: Error, Hashable, Sendable {
    case shotNotFound(ShotID)
    case invalidSplitPoint
    case shotsNotAdjacent
    case productionPlanMissing(ShotID)
}

public enum StoryboardEditor {
    public static func split(
        _ document: StoryboardDocumentV2,
        shotID: ShotID,
        atSeconds: Double
    ) throws -> StoryboardEditResult {
        guard let graphIndex = document.shotGraph.shots.firstIndex(where: { $0.id == shotID }),
              let documentIndex = document.shots.firstIndex(where: { $0.id == shotID })
        else { throw StoryboardEditingError.shotNotFound(shotID) }
        let old = document.shotGraph.shots[graphIndex]
        guard atSeconds > old.timeRange.startSeconds, atSeconds < old.timeRange.endSeconds else {
            throw StoryboardEditingError.invalidSplitPoint
        }
        let fps = document.shotGraph.asset.nominalFrameRate
        let frame = min(
            old.frameRange.endFrameExclusive - 1,
            max(old.frameRange.startFrame + 1, Int((atSeconds * fps).rounded()))
        )
        let firstID = ShotID(rawValue: "\(shotID.rawValue)-a")
        let secondID = ShotID(rawValue: "\(shotID.rawValue)-b")
        let first = ShotSegment(
            id: firstID,
            timeRange: MediaTimeRange(startSeconds: old.timeRange.startSeconds, endSeconds: atSeconds),
            frameRange: FrameRange(startFrame: old.frameRange.startFrame, endFrameExclusive: frame),
            transitionIn: old.transitionIn, transitionOut: .cut,
            boundaryConfidence: old.boundaryConfidence,
            detectorEvidenceIDs: old.detectorEvidenceIDs + ["user-split:\(shotID.rawValue)"]
        )
        let second = ShotSegment(
            id: secondID,
            timeRange: MediaTimeRange(startSeconds: atSeconds, endSeconds: old.timeRange.endSeconds),
            frameRange: FrameRange(startFrame: frame, endFrameExclusive: old.frameRange.endFrameExclusive),
            transitionIn: .cut, transitionOut: old.transitionOut,
            boundaryConfidence: old.boundaryConfidence,
            detectorEvidenceIDs: old.detectorEvidenceIDs + ["user-split:\(shotID.rawValue)"]
        )
        var segments = document.shotGraph.shots
        segments.replaceSubrange(graphIndex...graphIndex, with: [first, second])
        let graph = try ShotGraph(asset: document.shotGraph.asset, shots: segments)

        let oldShot = document.shots[documentIndex]
        let splitShots = [firstID, secondID].enumerated().map { offset, id in
            StoryboardShotV2(
                id: id,
                observedFacts: oldShot.observedFacts,
                productionPlan: oldShot.productionPlan.map {
                    copiedPlan($0, shotID: id, displayNumber: documentIndex + offset + 1, sourceShotRefs: [shotID])
                },
                userLockedFields: oldShot.userLockedFields
            )
        }
        var shots = document.shots
        shots.replaceSubrange(documentIndex...documentIndex, with: splitShots)
        shots = renumbered(shots)
        let remap = ShotRemap(mapping: [shotID: [firstID, secondID]])
        let updated = rebuilt(document, graph: graph, shots: shots, remap: remap)
        return result(original: document, updated: updated, remap: remap, changed: [firstID, secondID])
    }

    public static func merge(
        _ document: StoryboardDocumentV2,
        first firstID: ShotID,
        second secondID: ShotID
    ) throws -> StoryboardEditResult {
        guard let firstIndex = document.shotGraph.shots.firstIndex(where: { $0.id == firstID }),
              firstIndex + 1 < document.shotGraph.shots.count,
              document.shotGraph.shots[firstIndex + 1].id == secondID
        else { throw StoryboardEditingError.shotsNotAdjacent }
        let first = document.shotGraph.shots[firstIndex]
        let second = document.shotGraph.shots[firstIndex + 1]
        let mergedID = ShotID(rawValue: "\(firstID.rawValue)+\(secondID.rawValue)")
        let merged = ShotSegment(
            id: mergedID,
            timeRange: MediaTimeRange(startSeconds: first.timeRange.startSeconds, endSeconds: second.timeRange.endSeconds),
            frameRange: FrameRange(startFrame: first.frameRange.startFrame, endFrameExclusive: second.frameRange.endFrameExclusive),
            transitionIn: first.transitionIn, transitionOut: second.transitionOut,
            boundaryConfidence: min(first.boundaryConfidence, second.boundaryConfidence),
            detectorEvidenceIDs: Array(Set(first.detectorEvidenceIDs + second.detectorEvidenceIDs)).sorted()
        )
        var segments = document.shotGraph.shots
        segments.replaceSubrange(firstIndex...(firstIndex + 1), with: [merged])
        let graph = try ShotGraph(asset: document.shotGraph.asset, shots: segments)
        guard let firstShot = document.shots.first(where: { $0.id == firstID }),
              let secondShot = document.shots.first(where: { $0.id == secondID })
        else { throw StoryboardEditingError.shotNotFound(firstID) }
        let combined = StoryboardShotV2(
            id: mergedID,
            observedFacts: ObservedShotFacts(
                facts: Array(Set(firstShot.observedFacts.facts + secondShot.observedFacts.facts)),
                unknownFields: Array(Set(firstShot.observedFacts.unknownFields + secondShot.observedFacts.unknownFields)),
                reviewFlags: Array(Set(firstShot.observedFacts.reviewFlags + secondShot.observedFacts.reviewFlags)).sorted()
            ),
            productionPlan: firstShot.productionPlan.map {
                copiedPlan($0, shotID: mergedID, displayNumber: firstIndex + 1, sourceShotRefs: [firstID, secondID])
            },
            userLockedFields: firstShot.userLockedFields.union(secondShot.userLockedFields)
        )
        var shots = document.shots.filter { $0.id != firstID && $0.id != secondID }
        shots.insert(combined, at: min(firstIndex, shots.count))
        shots = renumbered(shots)
        let remap = ShotRemap(mapping: [firstID: [mergedID], secondID: [mergedID]])
        let updated = rebuilt(document, graph: graph, shots: shots, remap: remap)
        return result(original: document, updated: updated, remap: remap, changed: [mergedID])
    }

    public static func editPlanField(
        _ document: StoryboardDocumentV2,
        shotID: ShotID,
        field: EditablePlanField,
        value: String?,
        lock: Bool
    ) throws -> StoryboardEditResult {
        try update(document, shotID: shotID, values: [field: value], lock: lock, provenance: .user)
    }

    public static func applyModelRefresh(
        _ document: StoryboardDocumentV2,
        shotID: ShotID,
        values: [EditablePlanField: String?]
    ) throws -> StoryboardEditResult {
        try update(document, shotID: shotID, values: values, lock: false, provenance: .model)
    }

    private static func update(
        _ document: StoryboardDocumentV2,
        shotID: ShotID,
        values: [EditablePlanField: String?],
        lock: Bool,
        provenance: StoryboardFieldProvenance
    ) throws -> StoryboardEditResult {
        guard let index = document.shots.firstIndex(where: { $0.id == shotID }) else {
            throw StoryboardEditingError.shotNotFound(shotID)
        }
        let shot = document.shots[index]
        guard var plan = shot.productionPlan else { throw StoryboardEditingError.productionPlanMissing(shotID) }
        var locks = Set(plan.userLockedFields.compactMap(EditablePlanField.init(rawValue:)))
        var applied: [EditablePlanField: String?] = [:]
        var preserved = Set<EditablePlanField>()
        for (field, value) in values {
            if provenance == .model, locks.contains(field) {
                preserved.insert(field)
            } else {
                applied[field] = value
                if lock { locks.insert(field) }
            }
        }
        plan = copiedPlan(plan, values: applied, userLockedFields: Set(locks.map(\.rawValue)))
        var shots = document.shots
        shots[index] = StoryboardShotV2(
            id: shot.id, observedFacts: shot.observedFacts, productionPlan: plan,
            userLockedFields: Set(locks.map(\.rawValue))
        )
        let updated = rebuilt(document, graph: document.shotGraph, shots: shots, remap: ShotRemap(mapping: [:]))
        let diff = StoryboardDiff(
            changedShotIDs: applied.isEmpty ? [] : [shotID],
            changedFields: Set(applied.keys),
            fieldProvenance: Dictionary(uniqueKeysWithValues: applied.keys.map { ($0, provenance) }),
            preservedLockedFields: preserved
        )
        return StoryboardEditResult(
            original: document, document: updated, remap: ShotRemap(mapping: [:]), diff: diff,
            partialRerun: PartialRerunPlan(
                affectedShotIDs: [shotID], invalidatedStages: [.synthesis, .quality, .indexing],
                preservedLockedFields: locks
            )
        )
    }

    private static func result(
        original: StoryboardDocumentV2,
        updated: StoryboardDocumentV2,
        remap: ShotRemap,
        changed: [ShotID]
    ) -> StoryboardEditResult {
        StoryboardEditResult(
            original: original, document: updated, remap: remap,
            diff: StoryboardDiff(changedShotIDs: changed),
            partialRerun: PartialRerunPlan(
                affectedShotIDs: changed, invalidatedStages: [.synthesis, .quality, .indexing],
                preservedLockedFields: Set(updated.shots.flatMap(\.userLockedFields).compactMap(EditablePlanField.init(rawValue:)))
            )
        )
    }

    private static func rebuilt(
        _ document: StoryboardDocumentV2,
        graph: ShotGraph,
        shots: [StoryboardShotV2],
        remap: ShotRemap
    ) -> StoryboardDocumentV2 {
        let refs = document.contentAnalysis.referencedShotIDs.flatMap { remap.targets(for: $0).isEmpty ? [$0] : remap.targets(for: $0) }
        let analysis = document.contentAnalysis
        return StoryboardDocumentV2(
            id: document.id, source: document.source, shotGraph: graph, shots: shots,
            contentAnalysis: ContentAnalysis(
                title: analysis.title, summary: analysis.summary, themes: analysis.themes,
                hook: analysis.hook, retentionDevices: analysis.retentionDevices,
                payoff: analysis.payoff, callToAction: analysis.callToAction,
                referencedShotIDs: refs
            )
        )
    }

    private static func renumbered(_ shots: [StoryboardShotV2]) -> [StoryboardShotV2] {
        shots.enumerated().map { index, shot in
            StoryboardShotV2(
                id: shot.id, observedFacts: shot.observedFacts,
                productionPlan: shot.productionPlan.map { copiedPlan($0, displayNumber: index + 1) },
                userLockedFields: shot.userLockedFields
            )
        }
    }

    private static func copiedPlan(
        _ plan: ShotProductionPlan,
        shotID: ShotID? = nil,
        displayNumber: Int? = nil,
        sourceShotRefs: [ShotID]? = nil,
        values: [EditablePlanField: String?] = [:],
        userLockedFields: Set<String>? = nil
    ) -> ShotProductionPlan {
        func value(_ field: EditablePlanField, _ current: String?) -> String? {
            values.keys.contains(field) ? values[field] ?? nil : current
        }
        return ShotProductionPlan(
            shotID: shotID ?? plan.shotID, sequenceID: plan.sequenceID,
            displayNumber: displayNumber ?? plan.displayNumber,
            purpose: value(.purpose, plan.purpose), narrativeBeat: plan.narrativeBeat,
            hookRole: plan.hookRole, targetDuration: plan.targetDuration,
            shotSize: plan.shotSize, angle: plan.angle, movement: plan.movement,
            lensIntent: plan.lensIntent, subjectAction: value(.subjectAction, plan.subjectAction),
            composition: plan.composition, background: plan.background,
            lightingColor: plan.lightingColor, propsWardrobe: plan.propsWardrobe,
            dialogueOrVO: value(.dialogueOrVO, plan.dialogueOrVO),
            onScreenCopy: value(.onScreenCopy, plan.onScreenCopy), musicSFX: plan.musicSFX,
            transition: plan.transition, continuity: plan.continuity,
            generationPrompt: plan.generationPrompt,
            productionNotes: value(.productionNotes, plan.productionNotes),
            sourceShotRefs: sourceShotRefs ?? plan.sourceShotRefs,
            confidence: plan.confidence,
            userLockedFields: userLockedFields ?? plan.userLockedFields,
            isDerivedCreativePlan: plan.isDerivedCreativePlan
        )
    }
}
