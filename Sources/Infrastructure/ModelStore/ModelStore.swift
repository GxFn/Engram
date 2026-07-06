import EngineKit
import EngramLogging
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

public enum ModelInstallationError: Error, Equatable, LocalizedError, Sendable {
    case sourceMissing(path: String)
    case sourceNotDirectory(path: String)
    case sourceOverlapsDestination
    case missingRequiredFiles([String])

    public var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "Selected model folder could not be found."
        case .sourceNotDirectory:
            return "Selected item is not a model folder."
        case .sourceOverlapsDestination:
            return "Choose a model folder outside Engram's model storage."
        case .missingRequiredFiles(let files):
            return "Selected folder is missing MLX model files: \(files.joined(separator: ", "))."
        }
    }
}

/// Manages local model artifacts under Application Support/Models.
///
/// Remote hub integration is intentionally bounded. The store resolves, imports,
/// scans, accounts, and deletes verified local MLX assets; a missing remote
/// model fails explicitly until large-file network prompts and resumable
/// background behavior are designed.
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

        for manifest in try manifests() where try containsPayloadFile(in: manifest.directory) {
            models.insert(manifest.model)
        }

        return models.sorted { $0.id < $1.id }
    }

    public func delete(_ model: ModelIdentity) throws {
        for url in try directories(for: model) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func storageBytes(for model: ModelIdentity) throws -> Int64 {
        try directories(for: model).reduce(0) { total, directory in
            try total + regularFileBytes(in: directory)
        }
    }

    public func isDownloaded(_ model: ModelIdentity) throws -> Bool {
        for directory in try directories(for: model) where try containsPayloadFile(in: directory) {
            return true
        }

        return false
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

    @discardableResult
    public func installLocalModel(_ model: ModelIdentity, from sourceURL: URL) throws -> DownloadResult {
        try ensureModelsDirectory()

        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ModelInstallationError.sourceMissing(path: source.path)
        }

        guard isDirectory.boolValue else {
            throw ModelInstallationError.sourceNotDirectory(path: source.path)
        }

        try validateModelDirectory(source)

        let destination = directoryURL(for: model).standardizedFileURL
        if source.path == destination.path {
            try removeModelStoreManifests(under: destination)
            try writeManifest(for: model, in: destination)
            let storageBytes = try regularFileBytes(in: destination)
            Log.store.info("Registered local model \(model.id, privacy: .public) in place")
            return DownloadResult(model: model, localURL: destination, storageBytes: storageBytes)
        }

        guard !isOverlapping(source, destination) else {
            throw ModelInstallationError.sourceOverlapsDestination
        }

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let temporaryDirectory = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).installing-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try FileManager.default.copyItem(at: source, to: temporaryDirectory)
        try removeModelStoreManifests(under: temporaryDirectory)
        try writeManifest(for: model, in: temporaryDirectory)
        try replaceDirectory(at: destination, with: temporaryDirectory)

        let storageBytes = try regularFileBytes(in: destination)
        Log.store.info("Installed local model \(model.id, privacy: .public) from a verified folder")
        return DownloadResult(model: model, localURL: destination, storageBytes: storageBytes)
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

    private func directories(for model: ModelIdentity) throws -> [URL] {
        var seenPaths = Set<String>()
        var directories: [URL] = []

        func append(_ directory: URL) {
            let path = directory.standardizedFileURL.path
            guard !seenPaths.contains(path) else {
                return
            }

            seenPaths.insert(path)
            directories.append(directory)
        }

        append(directoryURL(for: model))

        for manifest in try manifests() where manifest.model == model {
            append(manifest.directory)
        }

        return directories
    }

    private func validateModelDirectory(_ directory: URL) throws {
        var hasConfig = false
        var hasTokenizer = false
        var hasWeights = false

        try visitRegularFiles(under: directory) { fileURL in
            let fileName = fileURL.lastPathComponent.lowercased()
            let fileExtension = fileURL.pathExtension.lowercased()

            if fileName == "config.json" {
                hasConfig = true
            }

            if Self.tokenizerFileNames.contains(fileName) {
                hasTokenizer = true
            }

            if Self.weightFileExtensions.contains(fileExtension) {
                hasWeights = true
            }
        }

        var missingFiles: [String] = []
        if !hasConfig {
            missingFiles.append("config.json")
        }
        if !hasTokenizer {
            missingFiles.append("tokenizer.json or tokenizer.model")
        }
        if !hasWeights {
            missingFiles.append("model weights")
        }

        guard missingFiles.isEmpty else {
            throw ModelInstallationError.missingRequiredFiles(missingFiles)
        }
    }

    private nonisolated static let tokenizerFileNames: Set<String> = [
        "merges.txt",
        "tokenizer.json",
        "tokenizer.model",
        "vocab.json",
    ]

    private nonisolated static let weightFileExtensions: Set<String> = [
        "bin",
        "gguf",
        "npz",
        "safetensors",
    ]

    private func writeManifest(for model: ModelIdentity, in directory: URL) throws {
        let data = try JSONEncoder().encode(model)
        try data.write(to: directory.appendingPathComponent(Self.manifestFileName), options: .atomic)
    }

    private func removeModelStoreManifests(under directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }

        try visitRegularFiles(under: directory) { fileURL in
            if fileURL.lastPathComponent == Self.manifestFileName {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func replaceDirectory(at destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: source, to: destination)
            return
        }

        let backup = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).replacing-\(UUID().uuidString)",
            isDirectory: true
        )
        try? fileManager.removeItem(at: backup)
        try fileManager.moveItem(at: destination, to: backup)

        do {
            try fileManager.moveItem(at: source, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            try? fileManager.moveItem(at: backup, to: destination)
            throw error
        }
    }

    private nonisolated func isOverlapping(_ source: URL, _ destination: URL) -> Bool {
        source.path.hasPrefix(destination.path + "/") || destination.path.hasPrefix(source.path + "/")
    }

    private struct ManifestRecord {
        let model: ModelIdentity
        let directory: URL
    }

    private func manifests() throws -> [ManifestRecord] {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else {
            return []
        }

        var records: [ManifestRecord] = []
        try visitDirectories(under: modelsDirectory) { directory in
            let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                return
            }

            let data = try Data(contentsOf: manifestURL)
            let model = try JSONDecoder().decode(ModelIdentity.self, from: data)
            records.append(ManifestRecord(model: model, directory: directory))
        }

        return records
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
