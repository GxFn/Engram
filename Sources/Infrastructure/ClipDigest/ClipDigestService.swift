import AppGroupSupport
import ClipCore
import ClipPipeline
import EngramLogging
import Foundation
import Persistence
import ScriptCore
import StoryboardCore
import SwiftData
import VideoUnderstanding

public struct FetchedArticleHTML: Sendable {
    public let url: URL
    public let html: String
    public let suggestedTitle: String?

    public init(url: URL, html: String, suggestedTitle: String? = nil) {
        self.url = url
        self.html = html
        self.suggestedTitle = suggestedTitle
    }
}

public protocol ArticleFetching: Sendable {
    func fetchHTML(from url: URL) async throws -> FetchedArticleHTML
}

public enum ArticleFetchError: Error, Equatable, Sendable {
    case invalidResponse
    case statusCode(Int)
    case emptyBody
}

public struct URLSessionArticleFetcher: ArticleFetching {
    private let timeout: TimeInterval
    private let dataForRequest: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(timeout: TimeInterval = 15) {
        self.init(timeout: timeout) { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: configuration)
            return try await session.data(for: request)
        }
    }

    public init(
        timeout: TimeInterval = 15,
        dataForRequest: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.timeout = timeout
        self.dataForRequest = dataForRequest
    }

    public func fetchHTML(from url: URL) async throws -> FetchedArticleHTML {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await dataForRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArticleFetchError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ArticleFetchError.statusCode(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw ArticleFetchError.emptyBody
        }

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArticleFetchError.emptyBody
        }

        return FetchedArticleHTML(url: httpResponse.url ?? url, html: html)
    }
}

public struct ClipDigestIndexingPayload: Sendable {
    public let clipID: String
    public let title: String?
    public let bodyText: String
    public let sourceURL: URL?

    public init(clipID: String, title: String?, bodyText: String, sourceURL: URL?) {
        self.clipID = clipID
        self.title = title
        self.bodyText = bodyText
        self.sourceURL = sourceURL
    }
}

public struct ClipDigestIndexingResult: Equatable, Sendable {
    public let preview: String?

    public init(preview: String?) {
        self.preview = preview
    }
}

public protocol ClipDigestIndexing: Sendable {
    func index(_ payload: ClipDigestIndexingPayload) async throws -> ClipDigestIndexingResult
    /// Removes a clip's entries from the retrieval indexes. Default no-op for indexers that
    /// do not own a persistent index (e.g. the preview indexer).
    func deleteClip(clipID: String) async throws
}

public extension ClipDigestIndexing {
    func deleteClip(clipID: String) async throws {}
}

/// W2.4's indexing handoff is intentionally not retrieval quality work. It
/// records deterministic paragraph boundaries so the UI can show real digest
/// progress while W2.5+ owns chunking, embedding, and vector indexes.
public struct DigestPreviewIndexer: ClipDigestIndexing {
    public init() {}

    public func index(_ payload: ClipDigestIndexingPayload) async throws -> ClipDigestIndexingResult {
        let paragraphs = payload.bodyText
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
        let preview = paragraphs
            .enumerated()
            .map { index, paragraph in "\(index + 1). \(paragraph)" }
            .joined(separator: "\n")
        return ClipDigestIndexingResult(preview: preview.isEmpty ? nil : preview)
    }
}

public enum ClipDigestServiceError: Error, Equatable, Sendable {
    case unsupportedEmptyText(String)
    case unsupportedURL(URL)
    case videoAnalyzerUnavailable(URL)
    case videoImportUnavailable
    case extractionFailed(String)
    case retryUnavailable(String)
}

public struct StoryboardEditReceipt: Sendable {
    public let legacy: Script
    public let document: StoryboardDocumentV2
    public let remap: ShotRemap
    public let diff: StoryboardDiff
    public let partialRerun: PartialRerunPlan
}

private struct PersistedStoryboardEditJournal: Codable, Sendable {
    var entries: [PersistedStoryboardEditEntry]

    static let empty = PersistedStoryboardEditJournal(entries: [])
}

private struct PersistedStoryboardEditEntry: Codable, Sendable {
    let id: String
    let previousDocument: StoryboardDocumentV2
    let document: StoryboardDocumentV2
    let remap: ShotRemap
    let diff: StoryboardDiff
    let partialRerun: PartialRerunPlan
    let previousQualityStatusRaw: String?
    let createdAt: Date
}

/// In-app capture intent for the 剪藏 library.
public enum ClipCaptureInput: Sendable, Equatable {
    case text(String)
    case url(URL)
}

public actor ClipDigestService: ClipDigesting {
    private let queueStore: ClipQueueStore
    private let recordStore: ClipRecordStore
    private let fetcher: any ArticleFetching
    private let extractor: ArticleExtractor
    private let indexer: any ClipDigestIndexing
    private let videoAnalyzer: (any VideoAnalyzing)?
    private let videoDirectoryURL: URL?
    private let videoImporter: VideoImporter?
    private let now: @Sendable () -> Date

    public init(
        queueStore: ClipQueueStore,
        recordStore: ClipRecordStore,
        fetcher: any ArticleFetching = URLSessionArticleFetcher(),
        extractor: ArticleExtractor = ArticleExtractor(),
        indexer: any ClipDigestIndexing = DigestPreviewIndexer(),
        videoAnalyzer: (any VideoAnalyzing)? = nil,
        videoDirectoryURL: URL? = nil,
        videoImporter: VideoImporter? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.queueStore = queueStore
        self.recordStore = recordStore
        self.fetcher = fetcher
        self.extractor = extractor
        self.indexer = indexer
        self.videoAnalyzer = videoAnalyzer
        self.videoDirectoryURL = videoDirectoryURL
        self.videoImporter = videoImporter ?? videoDirectoryURL.map {
            VideoImporter(videosDirectory: $0, queueStore: queueStore, now: now)
        }
        self.now = now
    }

    public static func live(
        modelContainer: ModelContainer,
        indexer: (any ClipDigestIndexing)? = nil,
        videoAnalyzer: (any VideoAnalyzing)? = nil,
        locations appGroupLocations: AppGroupLocations? = nil
    ) throws -> ClipDigestService {
        let locations: AppGroupLocations
        if let appGroupLocations {
            locations = appGroupLocations
        } else {
            locations = try EngramAppGroup.locations()
        }

        return ClipDigestService(
            queueStore: ClipQueueStore(locations: locations),
            recordStore: ClipRecordStore(modelContainer: modelContainer),
            indexer: indexer ?? DigestPreviewIndexer(),
            videoAnalyzer: videoAnalyzer,
            videoDirectoryURL: locations.videosDirectory
        )
    }

    public func digestPending() async throws {
        let items = try queueStore.pendingItems(quarantineDate: now())
        for item in items {
            try await digest(item)
        }
    }

    public func memorySnapshots() async throws -> [ClipRecordSnapshot] {
        try await recordStore.snapshots()
    }

    public func retryFailedClip(id: String) async throws {
        let clip = try await recordStore.clipForRetry(id: id, videoDirectoryURL: videoDirectoryURL)
        do {
            try queueStore.enqueue(clip)
            _ = try await recordStore.markQueuedForRetry(id: id, now: now())
        } catch {
            Log.clip.error("Failed to requeue clip \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    public func importVideo(from pickedURL: URL) async throws {
        guard let videoImporter else {
            throw ClipDigestServiceError.videoImportUnavailable
        }
        let clip = try videoImporter.importVideo(from: pickedURL)
        _ = try await recordStore.upsertQueuedClip(clip, now: now())
        Log.clip.info("Imported video clip \(clip.id, privacy: .public)")
    }

    /// In-app 剪藏 capture for the Clips library: enqueue a text/url clip and record it.
    /// Mirrors `importVideo` for the text/url side.
    public func capture(_ input: ClipCaptureInput) async throws {
        let clip: Clip
        switch input {
        case let .text(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ClipDigestServiceError.unsupportedEmptyText(text)
            }
            clip = Clip(id: UUID().uuidString, source: .text(trimmed), createdAt: now())
        case let .url(url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw ClipDigestServiceError.unsupportedURL(url)
            }
            clip = Clip(id: UUID().uuidString, source: .url(url), createdAt: now())
        }

        try queueStore.enqueue(clip)
        _ = try await recordStore.upsertQueuedClip(clip, now: now())
        Log.clip.info("Captured clip \(clip.id, privacy: .public)")
    }

    /// Deletes a clip everywhere: retrieval index, durable record, any pending queue file, and
    /// the imported video file. Index/queue/file removals are best-effort so a partial state
    /// still results in the record being gone.
    public func deleteClip(id: String) async throws {
        let snapshot = try? await recordStore.snapshot(id: id)

        try? await indexer.deleteClip(clipID: id)
        try await recordStore.delete(id: id)

        if let items = try? queueStore.pendingItems(quarantineDate: now()) {
            for item in items where item.clip.id == id {
                try? queueStore.delete(item)
            }
        }

        if let fileName = snapshot?.videoFileName, let videoDirectoryURL {
            let fileURL = videoDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            try? FileManager.default.removeItem(at: fileURL)
        }

        Log.clip.info("Deleted clip \(id, privacy: .public)")
    }

    /// Replaces a clip's indexed body text with a user-corrected version and re-indexes it, so 问答
    /// draws on the corrected content. Preserves the existing script (video breakdown) and title.
    public func updateClipText(id: String, text: String) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        let snapshot = try await recordStore.snapshot(id: id)

        try? await indexer.deleteClip(clipID: id)
        let result = try await indexer.index(ClipDigestIndexingPayload(
            clipID: id,
            title: snapshot.title,
            bodyText: normalized,
            sourceURL: snapshot.url
        ))

        _ = try await recordStore.markIndexed(
            id: id,
            title: snapshot.title,
            bodyText: normalized,
            indexPreview: result.preview,
            scriptJSON: snapshot.scriptJSON,
            now: now()
        )
        Log.clip.info("Re-indexed edited clip \(id, privacy: .public)")
    }

    /// Applies a structured edit (manual correction or AI re-analysis) to a clip's breakdown:
    /// re-encodes scriptJSON, re-renders the indexable text, and re-indexes — so 问答/洞察/投喂 all
    /// see the corrected script. Returns the updated script for immediate UI display.
    public func updateScript(id: String, transform: @Sendable (Script) -> Script) async throws -> Script {
        let snapshot = try await recordStore.snapshot(id: id)
        guard let script = ScriptCoding.decode(json: snapshot.scriptJSON) else {
            throw ClipDigestServiceError.unsupportedEmptyText("clip \(id) has no breakdown to edit")
        }

        let updated = transform(script)
        guard let json = ScriptCoding.encode(updated) else {
            throw ClipDigestServiceError.unsupportedEmptyText("re-encoding breakdown for \(id) failed")
        }
        let bodyText = ScriptRendering.indexableText(updated)

        try? await indexer.deleteClip(clipID: id)
        let result = try await indexer.index(ClipDigestIndexingPayload(
            clipID: id,
            title: updated.title.isEmpty ? snapshot.title : updated.title,
            bodyText: bodyText,
            sourceURL: snapshot.url
        ))

        _ = try await recordStore.markIndexed(
            id: id,
            title: updated.title.isEmpty ? snapshot.title : updated.title,
            bodyText: bodyText,
            indexPreview: result.preview,
            scriptJSON: json,
            now: now()
        )
        Log.clip.info("Re-indexed edited breakdown \(id, privacy: .public)")
        return updated
    }

    /// Applies split/merge/field edits to the authoritative V2 document, then regenerates the
    /// legacy projection and retrieval body so every existing consumer observes the same edit.
    public func updateStoryboard(
        id: String,
        transform: @Sendable (StoryboardDocumentV2) throws -> StoryboardDocumentV2
    ) async throws -> Script {
        let snapshot = try await recordStore.snapshot(id: id)
        guard let json = snapshot.storyboardJSON,
              let data = json.data(using: .utf8),
              let document = try? JSONDecoder().decode(StoryboardDocumentV2.self, from: data)
        else { throw ClipDigestServiceError.unsupportedEmptyText("clip \(id) has no V2 storyboard to edit") }
        let updatedDocument = try transform(document)
        return try await persistStoryboard(updatedDocument, snapshot: snapshot)
    }

    public func applyStoryboardEdit(
        id: String,
        transform: @Sendable (StoryboardDocumentV2) throws -> StoryboardEditResult
    ) async throws -> StoryboardEditReceipt {
        let snapshot = try await recordStore.snapshot(id: id)
        guard let json = snapshot.storyboardJSON,
              let data = json.data(using: .utf8),
              let document = try? JSONDecoder().decode(StoryboardDocumentV2.self, from: data)
        else { throw ClipDigestServiceError.unsupportedEmptyText("clip \(id) has no V2 storyboard to edit") }
        let result = try transform(document)
        guard result.original == document else {
            throw ClipDigestServiceError.retryUnavailable("clip \(id) edit is not based on the current durable storyboard")
        }
        var journal = try storyboardJournal(from: snapshot)
        journal.entries.append(PersistedStoryboardEditEntry(
            id: UUID().uuidString,
            previousDocument: document,
            document: result.document,
            remap: result.remap,
            diff: result.diff,
            partialRerun: result.partialRerun,
            previousQualityStatusRaw: snapshot.qualityStatusRaw,
            createdAt: now()
        ))
        journal.entries = Array(journal.entries.suffix(20))
        Log.clip.info(
            "Applying storyboard edit to \(id, privacy: .public); affected=\(result.partialRerun.affectedShotIDs.count, privacy: .public), invalidated=\(result.partialRerun.invalidatedStages.map(\.rawValue).joined(separator: ","), privacy: .public)"
        )
        let legacy = try await persistStoryboard(result.document, snapshot: snapshot, journal: journal)
        return StoryboardEditReceipt(
            legacy: legacy,
            document: result.document,
            remap: result.remap,
            diff: result.diff,
            partialRerun: result.partialRerun
        )
    }

    public func undoStoryboard(id: String) async throws -> StoryboardEditReceipt {
        let snapshot = try await recordStore.snapshot(id: id)
        var journal = try storyboardJournal(from: snapshot)
        guard let entry = journal.entries.popLast() else {
            throw ClipDigestServiceError.retryUnavailable("clip \(id) has no storyboard edit to undo")
        }
        let document = entry.previousDocument
        let legacy = try await persistStoryboard(
            document,
            snapshot: snapshot,
            journal: journal,
            qualityStatusRaw: entry.previousQualityStatusRaw
        )
        let changed = document.shotGraph.shots.map(\.id)
        return StoryboardEditReceipt(
            legacy: legacy,
            document: document,
            remap: ShotRemap(mapping: [:]),
            diff: StoryboardDiff(changedShotIDs: changed),
            partialRerun: PartialRerunPlan(
                affectedShotIDs: changed,
                invalidatedStages: [.synthesis, .quality, .indexing],
                preservedLockedFields: Set(document.shots.flatMap(\.userLockedFields).compactMap(EditablePlanField.init(rawValue:)))
            )
        )
    }

    public func reanalyzeStoryboard(id: String, shotIndex: Int) async throws -> StoryboardEditReceipt {
        let snapshot = try await recordStore.snapshot(id: id)
        guard let grounded = videoAnalyzer as? any EvidenceGroundedVideoAnalyzing,
              let sourceURL = snapshot.url,
              let json = snapshot.storyboardJSON,
              let document = try? JSONDecoder().decode(StoryboardDocumentV2.self, from: Data(json.utf8)),
              document.shotGraph.shots.indices.contains(shotIndex)
        else { throw ClipDigestServiceError.retryUnavailable("clip \(id) cannot run partial storyboard analysis") }
        let shotID = document.shotGraph.shots[shotIndex].id
        let source = VideoSource(id: id, localFileURL: sourceURL, importedAt: snapshot.createdAt)
        let refreshed = try await grounded.reanalyzeGrounded(source, document: document, shotIDs: [shotID])
        guard Self.partialRerunIsPublishable(before: document, after: refreshed, shotIDs: [shotID]) else {
            throw ClipDigestServiceError.retryUnavailable("clip \(id) partial storyboard analysis failed semantic quality or user-state preservation")
        }
        let qualityStatus = Self.recomputedQualityStatus(for: refreshed)
        var journal = try storyboardJournal(from: snapshot)
        let rerun = PartialRerunPlan(
            affectedShotIDs: [shotID],
            invalidatedStages: [.shotUnderstanding, .synthesis, .quality, .indexing],
            preservedLockedFields: Set(refreshed.shots.first(where: { $0.id == shotID })?.userLockedFields.compactMap(EditablePlanField.init(rawValue:)) ?? [])
        )
        journal.entries.append(PersistedStoryboardEditEntry(
            id: UUID().uuidString,
            previousDocument: document,
            document: refreshed,
            remap: ShotRemap(mapping: [:]),
            diff: StoryboardDiff(changedShotIDs: [shotID]),
            partialRerun: rerun,
            previousQualityStatusRaw: snapshot.qualityStatusRaw,
            createdAt: now()
        ))
        journal.entries = Array(journal.entries.suffix(20))
        Log.clip.info("Reanalyzed storyboard shot \(shotID.rawValue, privacy: .public) for \(id, privacy: .public) while preserving user locks")
        let legacy = try await persistStoryboard(
            refreshed,
            snapshot: snapshot,
            journal: journal,
            qualityStatusRaw: qualityStatus.rawValue
        )
        return StoryboardEditReceipt(
            legacy: legacy,
            document: refreshed,
            remap: ShotRemap(mapping: [:]),
            diff: StoryboardDiff(changedShotIDs: [shotID]),
            partialRerun: rerun
        )
    }

    private func persistStoryboard(
        _ updatedDocument: StoryboardDocumentV2,
        snapshot: ClipRecordSnapshot,
        journal: PersistedStoryboardEditJournal? = nil,
        qualityStatusRaw: String? = nil
    ) async throws -> Script {
        let id = snapshot.id
        let previousScript = ScriptCoding.decode(json: snapshot.scriptJSON)
        var legacy = StoryboardLegacyProjector.project(
            updatedDocument,
            createdAt: previousScript?.createdAt ?? snapshot.createdAt
        )
        if let context = previousScript?.userContext {
            legacy = legacy.withUserContext(context)
        }
        guard let legacyJSON = ScriptCoding.encode(legacy) else {
            throw ClipDigestServiceError.unsupportedEmptyText("re-encoding storyboard projection for \(id) failed")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let storyboardJSON = String(decoding: try encoder.encode(updatedDocument), as: UTF8.self)
        let journalJSON: String?
        if let journal {
            journalJSON = String(decoding: try encoder.encode(journal), as: UTF8.self)
        } else {
            journalJSON = snapshot.storyboardEditJournalJSON
        }
        let bodyText = ScriptRendering.indexableText(legacy)
        // Retrieval implementations use upsert semantics. Publishing the replacement before the
        // durable record means an indexing failure cannot destroy the last-good storyboard/journal.
        let result = try await indexer.index(ClipDigestIndexingPayload(
            clipID: id, title: legacy.title, bodyText: bodyText, sourceURL: snapshot.url
        ))
        _ = try await recordStore.markIndexed(
            id: id, title: legacy.title, bodyText: bodyText, indexPreview: result.preview,
            scriptJSON: legacyJSON, storyboardJSON: storyboardJSON,
            storyboardEditJournalJSON: journalJSON,
            activeRunID: snapshot.activeRunID, qualityStatusRaw: qualityStatusRaw ?? snapshot.qualityStatusRaw,
            analysisSchemaVersion: snapshot.analysisSchemaVersion, now: now()
        )
        Log.clip.info("Re-indexed authoritative storyboard edit \(id, privacy: .public)")
        return legacy
    }

    private func storyboardJournal(from snapshot: ClipRecordSnapshot) throws -> PersistedStoryboardEditJournal {
        guard let json = snapshot.storyboardEditJournalJSON else { return .empty }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PersistedStoryboardEditJournal.self, from: Data(json.utf8))
        } catch {
            throw ClipDigestServiceError.retryUnavailable("clip \(snapshot.id) storyboard edit journal is corrupt")
        }
    }

    private static func partialRerunIsPublishable(
        before: StoryboardDocumentV2,
        after: StoryboardDocumentV2,
        shotIDs: [ShotID]
    ) -> Bool {
        guard before.shotGraph == after.shotGraph else { return false }
        for shotID in shotIDs {
            guard let old = before.shots.first(where: { $0.id == shotID }),
                  let refreshed = after.shots.first(where: { $0.id == shotID }),
                  !refreshed.observedFacts.facts.isEmpty,
                  !refreshed.observedFacts.reviewFlags.contains(where: { $0.hasPrefix("shot-understanding-failed") })
            else { return false }
            let oldLocks = old.userLockedFields.union(old.productionPlan?.userLockedFields ?? [])
            let newLocks = refreshed.userLockedFields.union(refreshed.productionPlan?.userLockedFields ?? [])
            guard oldLocks.isSubset(of: newLocks) else { return false }
            let oldUserFacts = old.observedFacts.facts.filter { $0.source == .user }
            guard oldUserFacts.allSatisfy(refreshed.observedFacts.facts.contains) else { return false }
        }
        return true
    }

    private static func recomputedQualityStatus(for document: StoryboardDocumentV2) -> QualityStatus {
        if document.shots.contains(where: {
            $0.observedFacts.reviewFlags.contains(where: { $0.hasPrefix("shot-understanding-failed") })
        }) {
            return .failed
        }
        if document.shots.contains(where: { $0.observedFacts.facts.isEmpty }) { return .partial }
        if document.shots.contains(where: { !$0.observedFacts.reviewFlags.isEmpty }) { return .needsReview }
        if document.source.degradationNote != nil { return .degraded }
        return .clean
    }

    private func digest(_ item: ClipQueueItem) async throws {
        var clip = item.clip
        var scriptJSON: String?
        var storyboardJSON: String?
        var activeRunID: String?
        var qualityStatusRaw: String?
        var analysisSchemaVersion: Int?
        _ = try await recordStore.prepareQueuedClipForDigest(clip, now: now())

        do {
            switch clip.source {
            case let .text(text):
                clip.bodyText = try normalizedRequired(text, fallback: clip.bodyText)
                _ = try await recordStore.transition(id: clip.id, to: .indexing, now: now())

            case let .url(url):
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    throw ClassifiedDigestFailure(
                        reason: "Unsupported URL scheme for \(url.absoluteString)",
                        retryable: false,
                        underlyingDescription: String(describing: ClipDigestServiceError.unsupportedURL(url))
                    )
                }

                _ = try await recordStore.transition(id: clip.id, to: .fetching, now: now())
                let fetched = try await fetcher.fetchHTML(from: url)
                let article = try extractor.extract(
                    html: fetched.html,
                    fallbackTitle: clip.title ?? fetched.suggestedTitle
                )
                clip.title = clip.title ?? article.title
                clip.bodyText = article.bodyText
                _ = try await recordStore.updateFetchedBody(
                    id: clip.id,
                    title: clip.title,
                    bodyText: article.bodyText,
                    now: now()
                )
                _ = try await recordStore.transition(id: clip.id, to: .indexing, now: now())

            case let .videoFile(url):
                _ = try await recordStore.transition(id: clip.id, to: .transcribing, now: now())
                guard let videoAnalyzer else {
                    throw ClassifiedDigestFailure(
                        reason: "Video analyzer is not configured for \(url.lastPathComponent)",
                        retryable: false,
                        underlyingDescription: String(describing: ClipDigestServiceError.videoAnalyzerUnavailable(url))
                    )
                }

                let source = VideoSource(id: clip.id, localFileURL: url, importedAt: clip.createdAt)
                let clipID = clip.id
                let recordStage: @Sendable (ClipState) async -> Void = { [recordStore, now, clipID] stage in
                    do {
                        _ = try await recordStore.transition(id: clipID, to: stage, now: now())
                    } catch {
                        Log.clip.error(
                            "Failed to record video stage \(stage.rawValue, privacy: .public) for clip \(clipID, privacy: .public): \(String(describing: error), privacy: .public)"
                        )
                    }
                }
                let script: Script
                if let grounded = videoAnalyzer as? any EvidenceGroundedVideoAnalyzing {
                    let result = try await grounded.analyzeGrounded(source, onStage: recordStage)
                    guard result.run.status == .completed, result.quality.status != .failed else {
                        throw ClassifiedDigestFailure(
                            reason: "Evidence-grounded storyboard did not pass its final quality gate (run=\(result.run.status.rawValue), quality=\(result.quality.status.rawValue)).",
                            retryable: true,
                            underlyingDescription: "V2 final commit rejected"
                        )
                    }
                    script = result.legacy
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    storyboardJSON = String(decoding: try encoder.encode(result.document), as: UTF8.self)
                    activeRunID = result.run.id
                    qualityStatusRaw = result.quality.status.rawValue
                    analysisSchemaVersion = result.document.source.schemaVersion
                } else {
                    script = try await videoAnalyzer.analyze(source, onStage: recordStage)
                }
                // A re-digest (Retry) replaces scriptJSON wholesale — graft the user's 背景说明
                // from the previous breakdown so their supplied context survives regeneration.
                var enriched = script
                if script.userContext == nil,
                   let previous = try? await recordStore.snapshot(id: clip.id),
                   let context = ScriptCoding.decode(json: previous.scriptJSON)?.userContext {
                    enriched = script.withUserContext(context)
                }
                // A PHPicker import stores a UUID temp filename as the title — the breakdown's AI
                // title is the meaningful name, so it wins over empty or auto-generated ones.
                let storedTitle = clip.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if storedTitle.isEmpty || UUID(uuidString: storedTitle) != nil {
                    clip.title = enriched.title
                }
                clip.bodyText = ScriptRendering.indexableText(enriched)
                scriptJSON = try ClipRecordScriptJSON.encode(enriched)
                _ = try await recordStore.updateFetchedBody(
                    id: clip.id,
                    title: clip.title,
                    bodyText: clip.bodyText ?? "",
                    now: now()
                )
            }

            let sourceURL: URL?
            let bodyText: String
            if case let .url(url) = clip.source {
                sourceURL = url
                bodyText = try normalizedRequired(clip.bodyText, fallback: nil)
            } else if case .videoFile = clip.source {
                sourceURL = nil
                bodyText = try renderedScriptRequired(clip.bodyText)
            } else {
                sourceURL = nil
                bodyText = try normalizedRequired(clip.bodyText, fallback: nil)
            }
            let indexingResult = try await indexer.index(ClipDigestIndexingPayload(
                clipID: clip.id,
                title: clip.title,
                bodyText: bodyText,
                sourceURL: sourceURL
            ))
            _ = try await recordStore.markIndexed(
                id: clip.id,
                title: clip.title,
                bodyText: bodyText,
                indexPreview: indexingResult.preview,
                scriptJSON: scriptJSON,
                storyboardJSON: storyboardJSON,
                activeRunID: activeRunID,
                qualityStatusRaw: qualityStatusRaw,
                analysisSchemaVersion: analysisSchemaVersion,
                now: now()
            )
            try queueStore.delete(item)
            Log.clip.info("Digested queued clip \(clip.id, privacy: .public)")
        } catch is CancellationError {
            // Cancellation (user navigation, BGTask expiry) is not a failure: keep the pending queue
            // file and the non-terminal record state so the next digest run resumes this clip —
            // marking it failed here permanently bricked an interrupted 拆解.
            Log.clip.info("Digest cancelled for clip \(clip.id, privacy: .public); will resume on next run")
            throw CancellationError()
        } catch {
            try await recordFailure(for: item, error: classify(error))
        }
    }

    private func recordFailure(for item: ClipQueueItem, error: ClassifiedDigestFailure) async throws {
        _ = try await recordStore.markFailed(
            id: item.clip.id,
            reason: error.reason,
            retryable: error.retryable,
            now: now()
        )
        _ = try queueStore.moveToFailed(item, reason: error.reason, failedAt: now())
        Log.clip.error("Failed to digest clip \(item.clip.id, privacy: .public): \(error.reason, privacy: .public)")
    }

    private func classify(_ error: Error) -> ClassifiedDigestFailure {
        if let classified = error as? ClassifiedDigestFailure {
            return classified
        }
        if let urlError = error as? URLError {
            let retryable: Bool
            switch urlError.code {
            case .badURL, .unsupportedURL:
                retryable = false
            default:
                retryable = true
            }
            return ClassifiedDigestFailure(
                reason: "Network error \(urlError.code.rawValue): \(urlError.localizedDescription)",
                retryable: retryable,
                underlyingDescription: String(describing: error)
            )
        }
        if let fetchError = error as? ArticleFetchError {
            let retryable: Bool
            switch fetchError {
            case let .statusCode(code):
                retryable = code >= 500 || code == 408 || code == 429
            case .invalidResponse, .emptyBody:
                retryable = false
            }
            return ClassifiedDigestFailure(
                reason: "Fetch failed: \(fetchError)",
                retryable: retryable,
                underlyingDescription: String(describing: error)
            )
        }
        if error is ArticleExtractionError {
            return ClassifiedDigestFailure(
                reason: "Article extraction failed: \(error)",
                retryable: false,
                underlyingDescription: String(describing: error)
            )
        }
        if let videoError = error as? VideoUnderstandingError {
            return classify(videoError)
        }
        return ClassifiedDigestFailure(
            reason: String(describing: error),
            retryable: false,
            underlyingDescription: String(describing: error)
        )
    }

    private func classify(_ error: VideoUnderstandingError) -> ClassifiedDigestFailure {
        switch error {
        case .noAudioTrack:
            return ClassifiedDigestFailure(
                reason: "Video has no audio track.",
                retryable: false,
                underlyingDescription: String(describing: error)
            )
        case let .transcriptionUnavailable(message):
            return ClassifiedDigestFailure(
                reason: "Video transcription unavailable: \(message)",
                retryable: true,
                underlyingDescription: String(describing: error)
            )
        case let .visionUnavailable(message):
            return ClassifiedDigestFailure(
                reason: "Video vision unavailable after fallback boundary: \(message)",
                retryable: true,
                underlyingDescription: String(describing: error)
            )
        case let .visionConfigurationInvalid(message):
            // Fix Settings (key/endpoint) → Retry; deliberately NOT degraded to transcript-only.
            return ClassifiedDigestFailure(
                reason: "云端 AI 配置无效：\(message)",
                retryable: true,
                underlyingDescription: String(describing: error)
            )
        case let .unreadableAsset(message):
            return ClassifiedDigestFailure(
                reason: "Video asset unreadable: \(message)",
                retryable: false,
                underlyingDescription: String(describing: error)
            )
        }
    }

    private func normalizedRequired(_ primary: String?, fallback: String?) throws -> String {
        let value = primary ?? fallback
        let normalized = value.map { text in
            text.components(separatedBy: CharacterSet.newlines)
                .map {
                    $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        guard let normalized, !normalized.isEmpty else {
            throw ClassifiedDigestFailure(
                reason: "Clip text is empty",
                retryable: false,
                underlyingDescription: String(describing: ClipDigestServiceError.unsupportedEmptyText(primary ?? ""))
            )
        }
        return normalized
    }

    private func renderedScriptRequired(_ bodyText: String?) throws -> String {
        guard let bodyText, !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClassifiedDigestFailure(
                reason: "Video script text is empty",
                retryable: false,
                underlyingDescription: String(describing: ClipDigestServiceError.unsupportedEmptyText(bodyText ?? ""))
            )
        }
        return bodyText
    }
}

private struct ClassifiedDigestFailure: Error, Sendable {
    let reason: String
    let retryable: Bool
    let underlyingDescription: String
}
