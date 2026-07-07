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

public enum ModelDownloadError: Error, Equatable, LocalizedError, Sendable {
    case repositoryUnavailable(String)
    case incompleteSnapshot(String)
    case noMatchingSnapshotFiles(String)
    case downloadFailed(modelID: String, file: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .repositoryUnavailable(let modelID):
            return "Public model download is unavailable for \(modelID)."
        case .incompleteSnapshot(let modelID):
            return "Downloaded model files for \(modelID) did not pass validation."
        case .noMatchingSnapshotFiles(let modelID):
            return "No MLX model files were found for \(modelID)."
        case .downloadFailed(let modelID, let file, let reason):
            return "Could not download \(file) for \(modelID): \(reason)"
        }
    }
}

public protocol ModelSnapshotDownloading: Sendable {
    func downloadSnapshot(
        for model: ModelIdentity,
        into downloadBase: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL
}

public struct HuggingFaceModelSnapshotDownloader: ModelSnapshotDownloading {
    public init() {}

    public func downloadSnapshot(
        for model: ModelIdentity,
        into downloadBase: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)

        let selectedFilenames = try await Self.snapshotFilenames(for: model)
        guard !selectedFilenames.isEmpty else {
            throw ModelDownloadError.noMatchingSnapshotFiles(model.id)
        }

        let snapshotDirectory = downloadBase
            .appendingPathComponent(".snapshot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: snapshotDirectory)

        do {
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            progressHandler(Progress(totalUnitCount: 0))

            var completedBytes: Int64 = 0
            var preferredSource: RemoteModelSource?
            for filename in selectedFilenames {
                try Task.checkCancellation()

                let destination = snapshotDirectory.appendingPathComponent(filename, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                Log.store.info("Downloading model file \(filename, privacy: .public) for \(model.id, privacy: .public)")
                let downloadedFile = try await Self.downloadFile(
                    named: filename,
                    modelID: model.id,
                    preferredSource: preferredSource
                )
                preferredSource = downloadedFile.source

                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: downloadedFile.temporaryURL, to: destination)

                completedBytes += try Self.regularFileBytes(at: destination)
                let progress = Progress(totalUnitCount: 0)
                progress.completedUnitCount = completedBytes
                progressHandler(progress)
            }

            return snapshotDirectory
        } catch {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    public static let modelSnapshotPatterns: [String] = [
        "README.md",
        "added_tokens.json",
        "chat_template.jinja",
        "chat_template.json",
        "config.json",
        "generation_config.json",
        "merges.txt",
        "model.safetensors",
        "model.safetensors.index.json",
        "preprocessor_config.json",
        "processor_config.json",
        "special_tokens_map.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "vocab.json",
        "*.safetensors",
    ]

    private static let qwenTextModelSnapshotFilenames = [
        "README.md",
        "added_tokens.json",
        "config.json",
        "merges.txt",
        "model.safetensors.index.json",
        "special_tokens_map.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "vocab.json",
        "model.safetensors",
    ]

    private static let knownModelSnapshotFilenames: [String: [String]] = [
        "mlx-community/Qwen3-1.7B-4bit": qwenTextModelSnapshotFilenames,
        "mlx-community/Qwen3-4B-4bit": qwenTextModelSnapshotFilenames,
    ]

    private static let modelScopeFallbackRepositories: [String: String] = [
        "mlx-community/Qwen3-1.7B-4bit": "lmstudio-community/Qwen3-1.7B-MLX-4bit",
        "mlx-community/Qwen3-4B-4bit": "lmstudio-community/Qwen3-4B-MLX-4bit",
    ]

    static func knownSnapshotFilenames(for modelID: String) -> [String]? {
        knownModelSnapshotFilenames[modelID]
    }

    static func fileURLs(for modelID: String, filename: String) -> [URL] {
        remoteSources(for: modelID).map { fileURL(source: $0, filename: filename) }
    }

    static func selectedSnapshotFilenames(from filenames: [String]) -> [String] {
        filenames
            .filter(matchesModelSnapshotPattern)
            .sorted()
    }

    private static func matchesModelSnapshotPattern(_ filename: String) -> Bool {
        modelSnapshotPatterns.contains { pattern in
            if pattern == filename {
                return true
            }

            if pattern.hasPrefix("*."), let suffix = pattern.dropFirst().nilIfEmpty {
                return filename.hasSuffix(String(suffix))
            }

            return false
        }
    }

    private static func snapshotFilenames(for model: ModelIdentity) async throws -> [String] {
        if let knownFilenames = knownSnapshotFilenames(for: model.id) {
            Log.store.info("Using bundled file list for public model \(model.id, privacy: .public)")
            return knownFilenames
        }

        let filenames = try await Self.remoteFilenames(for: model)
        return Self.selectedSnapshotFilenames(from: filenames)
    }

    private static func remoteFilenames(for model: ModelIdentity) async throws -> [String] {
        let url = try modelInfoURL(for: model)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let session = makeURLSession(
            timeoutIntervalForRequest: 30,
            timeoutIntervalForResource: 60
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            Log.store.info("Fetching public model metadata for \(model.id, privacy: .public)")
            let (data, response) = try await session.data(for: request)
            try validateHTTPResponse(response, modelID: model.id, file: "model metadata")
            let decoded = try JSONDecoder().decode(HuggingFaceModelInfoResponse.self, from: data)
            return decoded.siblings.map(\.rfilename)
        } catch let error as ModelDownloadError {
            throw error
        } catch {
            throw ModelDownloadError.downloadFailed(
                modelID: model.id,
                file: "model metadata",
                reason: userFacingNetworkReason(for: error)
            )
        }
    }

    private static func downloadFile(
        named filename: String,
        modelID: String,
        preferredSource: RemoteModelSource?
    ) async throws -> DownloadedFile {
        let timeout = timeout(for: filename)
        var failureReasons: [String] = []

        for source in remoteSources(for: modelID, preferredSource: preferredSource) {
            do {
                Log.store.info(
                    "Trying model source \(source.displayName, privacy: .public) for \(filename, privacy: .public)"
                )
                let temporaryURL = try await downloadFile(
                    named: filename,
                    modelID: modelID,
                    source: source,
                    timeout: timeout
                )
                return DownloadedFile(temporaryURL: temporaryURL, source: source)
            } catch {
                let reason = userFacingNetworkReason(for: error)
                failureReasons.append("\(source.displayName): \(reason)")
                Log.store.error(
                    "Model source \(source.displayName, privacy: .public) failed for \(filename, privacy: .public): \(reason, privacy: .public)"
                )
            }
        }

        throw ModelDownloadError.downloadFailed(
            modelID: modelID,
            file: filename,
            reason: failureReasons.joined(separator: "; ")
        )
    }

    private static func downloadFile(
        named filename: String,
        modelID: String,
        source: RemoteModelSource,
        timeout: DownloadTimeout
    ) async throws -> URL {
        let url = fileURL(source: source, filename: filename)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout.request
        let session = makeURLSession(
            timeoutIntervalForRequest: timeout.request,
            timeoutIntervalForResource: timeout.resource
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            let (temporaryURL, response) = try await session.download(for: request)
            try validateHTTPResponse(response, modelID: modelID, file: filename)
            return temporaryURL
        } catch let error as ModelDownloadError {
            throw error
        } catch {
            throw ModelDownloadError.downloadFailed(
                modelID: modelID,
                file: filename,
                reason: userFacingNetworkReason(for: error)
            )
        }
    }

    private static func timeout(for filename: String) -> DownloadTimeout {
        if filename.hasSuffix(".safetensors"), !filename.hasSuffix(".index.json") {
            return DownloadTimeout(request: 120, resource: 3_600)
        }

        return DownloadTimeout(request: 30, resource: 120)
    }

    private static func makeURLSession(
        timeoutIntervalForRequest: TimeInterval,
        timeoutIntervalForResource: TimeInterval
    ) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = timeoutIntervalForRequest
        configuration.timeoutIntervalForResource = timeoutIntervalForResource
        return URLSession(configuration: configuration)
    }

    private static func userFacingNetworkReason(for error: Error) -> String {
        if let downloadError = error as? ModelDownloadError,
           let description = downloadError.errorDescription {
            return description
        }

        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }

        switch urlError.code {
        case .timedOut:
            return "request timed out while contacting Hugging Face"
        case .notConnectedToInternet:
            return "device is not connected to the internet"
        case .networkConnectionLost:
            return "network connection was interrupted"
        case .cannotFindHost, .cannotConnectToHost:
            return "could not connect to Hugging Face"
        default:
            return urlError.localizedDescription
        }
    }

    private static func remoteSources(
        for modelID: String,
        preferredSource: RemoteModelSource? = nil
    ) -> [RemoteModelSource] {
        var sources = [
            RemoteModelSource(
                displayName: "Hugging Face",
                repositoryID: modelID,
                revision: "main",
                kind: .huggingFace
            ),
        ]

        if let modelScopeRepository = modelScopeFallbackRepositories[modelID] {
            sources.append(RemoteModelSource(
                displayName: "ModelScope",
                repositoryID: modelScopeRepository,
                revision: "master",
                kind: .modelScope
            ))
        }

        if let preferredSource,
           let preferredIndex = sources.firstIndex(of: preferredSource) {
            sources.remove(at: preferredIndex)
            sources.insert(preferredSource, at: 0)
        }

        return sources
    }

    private static func validateHTTPResponse(
        _ response: URLResponse,
        modelID: String,
        file: String
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ModelDownloadError.downloadFailed(
                modelID: modelID,
                file: file,
                reason: "HTTP \(httpResponse.statusCode)"
            )
        }
    }

    private static func modelInfoURL(for model: ModelIdentity) throws -> URL {
        guard let url = URL(string: "https://huggingface.co/api/models/\(model.id)/revision/main") else {
            throw ModelDownloadError.repositoryUnavailable(model.id)
        }
        return url
    }

    private static func fileURL(source: RemoteModelSource, filename: String) -> URL {
        var url = source.kind.baseURL
        for component in source.repositoryID.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        url.appendPathComponent("resolve", isDirectory: false)
        url.appendPathComponent(source.revision, isDirectory: false)
        for component in filename.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }

    private static func regularFileBytes(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return Int64((attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }

    private struct HuggingFaceModelInfoResponse: Decodable {
        let siblings: [Sibling]

        struct Sibling: Decodable {
            let rfilename: String
        }
    }

    private struct DownloadTimeout {
        let request: TimeInterval
        let resource: TimeInterval
    }

    private struct DownloadedFile {
        let temporaryURL: URL
        let source: RemoteModelSource
    }

    private struct RemoteModelSource: Equatable {
        let displayName: String
        let repositoryID: String
        let revision: String
        let kind: RemoteModelSourceKind
    }

    private enum RemoteModelSourceKind: Equatable {
        case huggingFace
        case modelScope

        var baseURL: URL {
            switch self {
            case .huggingFace:
                URL(string: "https://huggingface.co")!
            case .modelScope:
                URL(string: "https://modelscope.cn/models")!
            }
        }
    }
}

private extension Substring {
    var nilIfEmpty: Substring? {
        isEmpty ? nil : self
    }
}

/// Manages local model artifacts under Application Support/Models.
///
/// The store resolves, downloads, imports, scans, measures, and deletes verified
/// local MLX assets. Public downloads use the Hugging Face Hub without app
/// credentials, then materialize the same canonical model directory used by
/// MLXEngine and local Files imports.
public actor ModelStore {
    private static let manifestFileName = ".engram-model.json"

    private let modelsDirectory: URL
    private let snapshotDownloader: any ModelSnapshotDownloading

    public init(
        modelsDirectory: URL? = nil,
        snapshotDownloader: any ModelSnapshotDownloading = HuggingFaceModelSnapshotDownloader()
    ) {
        self.modelsDirectory = modelsDirectory ?? Self.defaultModelsDirectory()
        self.snapshotDownloader = snapshotDownloader
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

    @discardableResult
    public func download(
        _ model: ModelIdentity,
        progressHandler: @Sendable @escaping (DownloadState) -> Void = { _ in }
    ) async throws -> DownloadResult {
        if try isDownloaded(model) {
            let url = try localURL(for: model)
            let storageBytes = try storageBytes(for: model)
            progressHandler(DownloadState(completedBytes: storageBytes, totalBytes: storageBytes))
            return DownloadResult(model: model, localURL: url, storageBytes: storageBytes)
        }

        try ensureModelsDirectory()
        progressHandler(DownloadState(completedBytes: 0, totalBytes: nil))
        Log.store.info("Starting public model download \(model.id, privacy: .public)")

        do {
            let stagingDirectory = try downloadStagingDirectory()
            let snapshotURL = try await snapshotDownloader.downloadSnapshot(
                for: model,
                into: stagingDirectory
            ) { progress in
                progressHandler(DownloadState(
                    completedBytes: progress.completedUnitCount,
                    totalBytes: progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
                ))
            }
            defer { removeStagingSnapshot(snapshotURL, under: stagingDirectory) }

            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
                throw ModelDownloadError.repositoryUnavailable(model.id)
            }

            let result = try installLocalModel(model, from: snapshotURL)
            progressHandler(DownloadState(completedBytes: result.storageBytes, totalBytes: result.storageBytes))
            Log.store.info("Finished public model download \(model.id, privacy: .public)")
            return result
        } catch is CancellationError {
            Log.store.info("Cancelled public model download \(model.id, privacy: .public)")
            throw CancellationError()
        } catch {
            Log.store.error("Public model download failed \(model.id, privacy: .public): \(String(describing: error), privacy: .public)")
            if error is ModelInstallationError {
                throw ModelDownloadError.incompleteSnapshot(model.id)
            }
            throw error
        }
    }

    private func downloadStagingDirectory() throws -> URL {
        let directory = modelsDirectory.appendingPathComponent(".downloads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func removeStagingSnapshot(_ snapshotURL: URL, under stagingDirectory: URL) {
        let snapshotPath = snapshotURL.standardizedFileURL.path
        let stagingPath = stagingDirectory.standardizedFileURL.path
        guard snapshotPath.hasPrefix(stagingPath + "/") else {
            return
        }

        try? FileManager.default.removeItem(at: snapshotURL)
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
