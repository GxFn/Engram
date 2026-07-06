import EngineKit
import Foundation

public struct DownloadState: Sendable, Equatable {
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public let fractionCompleted: Double?

    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes

        guard let totalBytes, totalBytes > 0 else {
            self.fractionCompleted = nil
            return
        }

        self.fractionCompleted = min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

public struct DownloadResult: Sendable, Equatable {
    public let model: ModelIdentity
    public let localURL: URL
    public let storageBytes: Int64

    public init(model: ModelIdentity, localURL: URL, storageBytes: Int64) {
        self.model = model
        self.localURL = localURL
        self.storageBytes = storageBytes
    }
}

/// Manages local model artifacts under Application Support/Models.
///
/// Remote hub integration is intentionally bounded in W1.2. The store can
/// resolve, scan, account, and delete local assets now; a missing remote model
/// fails explicitly until the onboarding/download slice wires product decisions
/// such as large-file network prompts and resumable background behavior.
public actor ModelStore {
    private static let manifestFileName = ".engram-model.json"

    private let modelsDirectory: URL

    public init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory ?? Self.defaultModelsDirectory()
    }

    public func localURL(for model: ModelIdentity) throws -> URL {
        try ensureModelsDirectory()
        return directoryURL(for: model)
    }

    public func downloadedModels() throws -> [ModelIdentity] {
        try ensureModelsDirectory()

        var models = Set<ModelIdentity>()
        for model in ModelCatalog.launchLineup where try isDownloaded(model) {
            models.insert(model)
        }

        for manifestModel in try manifestModels() where try containsPayloadFile(in: directoryURL(for: manifestModel)) {
            models.insert(manifestModel)
        }

        return models.sorted { $0.id < $1.id }
    }

    public func delete(_ model: ModelIdentity) throws {
        let url = directoryURL(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try FileManager.default.removeItem(at: url)
    }

    public func storageBytes(for model: ModelIdentity) throws -> Int64 {
        try regularFileBytes(in: directoryURL(for: model))
    }

    public func isDownloaded(_ model: ModelIdentity) throws -> Bool {
        try containsPayloadFile(in: directoryURL(for: model))
    }

    public func download(_ model: ModelIdentity) throws {
        if try isDownloaded(model) {
            return
        }

        let url = try localURL(for: model)
        throw EngineError.notImplemented(
            "remote model download deferred; place verified model artifacts at \(url.path)"
        )
    }

    private nonisolated static func defaultModelsDirectory() -> URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }

    private func ensureModelsDirectory() throws {
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )
    }

    private func directoryURL(for model: ModelIdentity) -> URL {
        model.id.split(separator: "/").reduce(modelsDirectory) { url, pathComponent in
            url.appendingPathComponent(String(pathComponent), isDirectory: true)
        }
    }

    private func manifestModels() throws -> [ModelIdentity] {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else {
            return []
        }

        var models: [ModelIdentity] = []
        try visitDirectories(under: modelsDirectory) { directory in
            let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                return
            }

            let data = try Data(contentsOf: manifestURL)
            models.append(try JSONDecoder().decode(ModelIdentity.self, from: data))
        }

        return models
    }

    private func containsPayloadFile(in directory: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return false
        }

        var foundPayload = false
        try visitRegularFiles(under: directory) { fileURL in
            if fileURL.lastPathComponent != Self.manifestFileName {
                foundPayload = true
            }
        }

        return foundPayload
    }

    private func regularFileBytes(in directory: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return 0
        }

        var total: Int64 = 0
        try visitRegularFiles(under: directory) { fileURL in
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values.fileSize ?? 0)
        }

        return total
    }

    private func visitDirectories(under root: URL, _ body: (URL) throws -> Void) throws {
        try body(root)

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try body(url)
            }
        }
    }

    private func visitRegularFiles(under root: URL, _ body: (URL) throws -> Void) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                try body(url)
            }
        }
    }
}
