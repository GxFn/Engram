import AppGroupSupport
import ClipCore
import Foundation
import ScriptCore
import SwiftData

/// SwiftData projection of a Clip. Kept deliberately close to the domain type;
/// mapping stays trivial and the domain layer never imports SwiftData.
@Model
public final class ClipRecord {
    @Attribute(.unique) public var id: String
    public var title: String?
    public var note: String?
    public var bodyText: String?
    public var urlString: String?
    public var sourceKindRaw: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var stateRaw: String
    public var failureReason: String?
    public var failureRetryable: Bool
    public var indexPreview: String?
    public var scriptJSON: String?
    public var videoFileName: String?

    public init(
        id: String,
        title: String?,
        note: String?,
        bodyText: String?,
        urlString: String?,
        sourceKindRaw: String? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        stateRaw: String,
        failureReason: String? = nil,
        failureRetryable: Bool = false,
        indexPreview: String? = nil,
        scriptJSON: String? = nil,
        videoFileName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.bodyText = bodyText
        self.urlString = urlString
        self.sourceKindRaw = sourceKindRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.stateRaw = stateRaw
        self.failureReason = failureReason
        self.failureRetryable = failureRetryable
        self.indexPreview = indexPreview
        self.scriptJSON = scriptJSON
        self.videoFileName = videoFileName
    }
}

public struct ClipRecordSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let note: String?
    public let bodyText: String?
    public let url: URL?
    public let createdAt: Date
    public let updatedAt: Date
    public let state: ClipState
    public let failureReason: String?
    public let failureRetryable: Bool
    public let indexPreview: String?
    public let scriptJSON: String?
    public let videoFileName: String?
    public let sourceKind: ClipSourceKind

    public init(
        id: String,
        title: String?,
        note: String?,
        bodyText: String?,
        url: URL?,
        createdAt: Date,
        updatedAt: Date,
        state: ClipState,
        failureReason: String?,
        failureRetryable: Bool,
        indexPreview: String?,
        scriptJSON: String? = nil,
        videoFileName: String? = nil,
        sourceKind: ClipSourceKind = .text
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.bodyText = bodyText
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.failureReason = failureReason
        self.failureRetryable = failureRetryable
        self.indexPreview = indexPreview
        self.scriptJSON = scriptJSON
        self.videoFileName = videoFileName
        self.sourceKind = sourceKind
    }
}

public enum ClipRecordScriptJSON {
    public static func encode(_ script: Script) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(script)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String) throws -> Script {
        try JSONDecoder().decode(Script.self, from: Data(json.utf8))
    }
}

public enum ClipRecordStoreError: Error, Equatable, Sendable {
    case missingRecord(String)
    case illegalTransition(id: String, from: ClipState, to: ClipState)
    case retryUnavailable(String)
}

@ModelActor
public actor ClipRecordStore {
    public func upsertQueuedClip(_ clip: Clip, now: Date = Date()) throws -> ClipRecordSnapshot {
        let record = try record(for: clip.id)
        if let record {
            let current = state(of: record)
            if current != .queued {
                try ensureTransition(id: clip.id, from: current, to: .queued)
            }
            apply(clip, to: record)
            record.updatedAt = now
            record.stateRaw = ClipState.queued.rawValue
            record.failureReason = nil
            record.failureRetryable = false
            record.indexPreview = nil
            record.scriptJSON = nil
        } else {
            let newRecord = ClipRecord(
                id: clip.id,
                title: clip.title,
                note: clip.note,
                bodyText: bodyText(from: clip),
                urlString: urlString(from: clip),
                sourceKindRaw: sourceKindRaw(from: clip),
                createdAt: clip.createdAt,
                updatedAt: now,
                stateRaw: ClipState.queued.rawValue,
                videoFileName: videoFileName(from: clip)
            )
            modelContext.insert(newRecord)
        }
        try modelContext.save()
        return try snapshot(id: clip.id)
    }

    public func prepareQueuedClipForDigest(_ clip: Clip, now: Date = Date()) throws -> ClipRecordSnapshot {
        let record = try record(for: clip.id)
        if let record {
            let current = state(of: record)
            switch current {
            case .queued:
                break
            case .failed:
                try ensureTransition(id: clip.id, from: current, to: .queued)
            case .fetching, .indexing, .transcribing, .analyzing, .scripting:
                break
            case .indexed:
                return makeSnapshot(record)
            }
            apply(clip, to: record)
            record.updatedAt = now
            record.stateRaw = ClipState.queued.rawValue
            record.failureReason = nil
            record.failureRetryable = false
            record.indexPreview = nil
            record.scriptJSON = nil
        } else {
            let newRecord = ClipRecord(
                id: clip.id,
                title: clip.title,
                note: clip.note,
                bodyText: bodyText(from: clip),
                urlString: urlString(from: clip),
                sourceKindRaw: sourceKindRaw(from: clip),
                createdAt: clip.createdAt,
                updatedAt: now,
                stateRaw: ClipState.queued.rawValue,
                videoFileName: videoFileName(from: clip)
            )
            modelContext.insert(newRecord)
        }
        try modelContext.save()
        return try snapshot(id: clip.id)
    }

    public func transition(id: String, to next: ClipState, now: Date = Date()) throws -> ClipRecordSnapshot {
        let record = try requiredRecord(for: id)
        let current = state(of: record)
        if current != next {
            try ensureTransition(id: id, from: current, to: next)
            record.stateRaw = next.rawValue
        }
        record.updatedAt = now
        try modelContext.save()
        return makeSnapshot(record)
    }

    public func updateFetchedBody(
        id: String,
        title: String?,
        bodyText: String,
        now: Date = Date()
    ) throws -> ClipRecordSnapshot {
        let record = try requiredRecord(for: id)
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record.title = title
        }
        record.bodyText = bodyText
        record.updatedAt = now
        try modelContext.save()
        return makeSnapshot(record)
    }

    public func markIndexed(
        id: String,
        title: String?,
        bodyText: String?,
        indexPreview: String?,
        scriptJSON: String? = nil,
        now: Date = Date()
    ) throws -> ClipRecordSnapshot {
        let record = try requiredRecord(for: id)
        let current = state(of: record)
        if current != .indexed {
            try ensureTransition(id: id, from: current, to: .indexed)
            record.stateRaw = ClipState.indexed.rawValue
        }
        if let title {
            record.title = title
        }
        if let bodyText {
            record.bodyText = bodyText
        }
        record.indexPreview = indexPreview
        record.scriptJSON = scriptJSON
        record.failureReason = nil
        record.failureRetryable = false
        record.updatedAt = now
        try modelContext.save()
        return makeSnapshot(record)
    }

    public func markFailed(
        id: String,
        reason: String,
        retryable: Bool,
        now: Date = Date()
    ) throws -> ClipRecordSnapshot {
        let record = try requiredRecord(for: id)
        let current = state(of: record)
        if current != .failed {
            try ensureTransition(id: id, from: current, to: .failed)
            record.stateRaw = ClipState.failed.rawValue
        }
        record.failureReason = reason
        record.failureRetryable = retryable
        record.updatedAt = now
        try modelContext.save()
        return makeSnapshot(record)
    }

    public func clipForRetry(id: String, videoDirectoryURL: URL? = nil) throws -> Clip {
        let record = try requiredRecord(for: id)
        let current = state(of: record)
        guard current == .failed, record.failureRetryable else {
            throw ClipRecordStoreError.retryUnavailable(id)
        }

        let source: ClipSource
        if sourceKind(of: record) == .videoFile,
           let url = retryVideoURL(from: record, videoDirectoryURL: videoDirectoryURL) {
            source = .videoFile(url)
        } else if let urlString = record.urlString, let url = URL(string: urlString) {
            source = .url(url)
        } else if let bodyText = record.bodyText, !bodyText.isEmpty {
            source = .text(bodyText)
        } else {
            throw ClipRecordStoreError.retryUnavailable(id)
        }

        return Clip(
            id: record.id,
            source: source,
            title: record.title,
            note: record.note,
            bodyText: record.bodyText,
            createdAt: record.createdAt,
            state: .queued
        )
    }

    public func markQueuedForRetry(id: String, now: Date = Date()) throws -> ClipRecordSnapshot {
        let record = try requiredRecord(for: id)
        let current = state(of: record)
        if current != .queued {
            try ensureTransition(id: id, from: current, to: .queued)
            record.stateRaw = ClipState.queued.rawValue
        }
        record.failureReason = nil
        record.failureRetryable = false
        record.updatedAt = now
        try modelContext.save()
        return makeSnapshot(record)
    }

    public func snapshots() throws -> [ClipRecordSnapshot] {
        var descriptor = FetchDescriptor<ClipRecord>(
            sortBy: [
                SortDescriptor(\.createdAt, order: .reverse),
                SortDescriptor(\.id, order: .forward),
            ]
        )
        descriptor.includePendingChanges = true
        return try modelContext.fetch(descriptor).map(makeSnapshot)
    }

    public func snapshot(id: String) throws -> ClipRecordSnapshot {
        try makeSnapshot(requiredRecord(for: id))
    }

    private func record(for id: String) throws -> ClipRecord? {
        let targetID = id
        var descriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate<ClipRecord> { record in
                record.id == targetID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func requiredRecord(for id: String) throws -> ClipRecord {
        guard let record = try record(for: id) else {
            throw ClipRecordStoreError.missingRecord(id)
        }
        return record
    }

    private func apply(_ clip: Clip, to record: ClipRecord) {
        record.title = clip.title
        record.note = clip.note
        record.bodyText = bodyText(from: clip)
        record.urlString = urlString(from: clip)
        record.sourceKindRaw = sourceKindRaw(from: clip)
        record.videoFileName = videoFileName(from: clip)
    }

    private func ensureTransition(id: String, from current: ClipState, to next: ClipState) throws {
        guard current.canTransition(to: next) else {
            throw ClipRecordStoreError.illegalTransition(id: id, from: current, to: next)
        }
    }

    private func state(of record: ClipRecord) -> ClipState {
        ClipState(rawValue: record.stateRaw) ?? .failed
    }

    private func makeSnapshot(_ record: ClipRecord) -> ClipRecordSnapshot {
        ClipRecordSnapshot(
            id: record.id,
            title: record.title,
            note: record.note,
            bodyText: record.bodyText,
            url: record.urlString.flatMap(URL.init(string:)),
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            state: state(of: record),
            failureReason: record.failureReason,
            failureRetryable: record.failureRetryable,
            indexPreview: record.indexPreview,
            scriptJSON: record.scriptJSON,
            videoFileName: record.videoFileName,
            sourceKind: clipSourceKind(of: record)
        )
    }

    private func clipSourceKind(of record: ClipRecord) -> ClipSourceKind {
        switch sourceKind(of: record) {
        case .videoFile:
            return .video
        case .url:
            return .url
        case .text:
            return .text
        case .none:
            // Legacy records without an explicit kind: infer from available fields.
            if record.videoFileName != nil {
                return .video
            }
            if record.urlString != nil {
                return .url
            }
            return .text
        }
    }
}

private enum ClipRecordSourceKind: String {
    case text
    case url
    case videoFile
}

private func sourceKind(of record: ClipRecord) -> ClipRecordSourceKind? {
    record.sourceKindRaw.flatMap(ClipRecordSourceKind.init(rawValue:))
}

private func bodyText(from clip: Clip) -> String? {
    if let bodyText = clip.bodyText {
        return bodyText
    }
    if case let .text(text) = clip.source {
        return text
    }
    return nil
}

private func urlString(from clip: Clip) -> String? {
    switch clip.source {
    case let .url(url), let .videoFile(url):
        return url.absoluteString
    case .text:
        return nil
    }
}

private func videoFileName(from clip: Clip) -> String? {
    guard case let .videoFile(url) = clip.source else {
        return nil
    }
    let fileName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return fileName.isEmpty ? nil : fileName
}

private func retryVideoURL(from record: ClipRecord, videoDirectoryURL: URL?) -> URL? {
    if let videoDirectoryURL,
       let fileName = normalizedVideoFileName(record.videoFileName) {
        return videoDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }
    return record.urlString.flatMap(URL.init(string:))
}

private func normalizedVideoFileName(_ fileName: String?) -> String? {
    guard let fileName else {
        return nil
    }
    let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: trimmed).lastPathComponent
}

private func sourceKindRaw(from clip: Clip) -> String {
    switch clip.source {
    case .text:
        return ClipRecordSourceKind.text.rawValue
    case .url:
        return ClipRecordSourceKind.url.rawValue
    case .videoFile:
        return ClipRecordSourceKind.videoFile.rawValue
    }
}

public enum PersistenceStack {
    public static func makeContainer(
        inMemory: Bool = false,
        appGroupContainerURL: ((String) -> URL?)? = nil,
        fallbackBaseURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let storeURL = try storeURL(
                appGroupContainerURL: appGroupContainerURL,
                fallbackBaseURL: fallbackBaseURL,
                fileManager: fileManager
            )
            configuration = ModelConfiguration("Engram", url: storeURL)
        }

        return try ModelContainer(for: ClipRecord.self, configurations: configuration)
    }

    public static func storeURL(
        appGroupContainerURL: ((String) -> URL?)? = nil,
        fallbackBaseURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let resolver = appGroupContainerURL ?? {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
        return try EngramAppGroup.locations(
            fileManager: fileManager,
            containerURL: resolver,
            fallbackBaseURL: fallbackBaseURL
        ).storeURL
    }
}
