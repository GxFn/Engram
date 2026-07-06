import Foundation

public struct AppGroupLocations: Equatable, Sendable {
    public let groupIdentifier: String
    public let rootDirectory: URL
    public let storeURL: URL
    public let queueDirectory: URL
    public let modelsDirectory: URL
    public let usesAppGroupContainer: Bool

    public init(
        groupIdentifier: String,
        rootDirectory: URL,
        storeURL: URL,
        queueDirectory: URL,
        modelsDirectory: URL,
        usesAppGroupContainer: Bool
    ) {
        self.groupIdentifier = groupIdentifier
        self.rootDirectory = rootDirectory
        self.storeURL = storeURL
        self.queueDirectory = queueDirectory
        self.modelsDirectory = modelsDirectory
        self.usesAppGroupContainer = usesAppGroupContainer
    }
}

public enum EngramAppGroup {
    public static let identifier = "group.com.gxfn.engram"
    public static let storeFileName = "Engram.store"
    public static let queueDirectoryName = "queue"
    public static let modelsDirectoryName = "Models"
    public static let fallbackDirectoryName = "Engram"

    public static func locations(
        fileManager: FileManager = .default,
        containerURL: (String) -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        },
        fallbackBaseURL: URL? = nil
    ) throws -> AppGroupLocations {
        let groupContainerURL = containerURL(identifier)
        let rootDirectory = groupContainerURL ?? defaultFallbackBaseURL(
            fileManager: fileManager,
            fallbackBaseURL: fallbackBaseURL
        )
        let locations = AppGroupLocations(
            groupIdentifier: identifier,
            rootDirectory: rootDirectory,
            storeURL: rootDirectory.appendingPathComponent(storeFileName, isDirectory: false),
            queueDirectory: rootDirectory.appendingPathComponent(queueDirectoryName, isDirectory: true),
            modelsDirectory: rootDirectory.appendingPathComponent(modelsDirectoryName, isDirectory: true),
            usesAppGroupContainer: groupContainerURL != nil
        )

        try fileManager.createDirectory(at: locations.rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: locations.queueDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: locations.modelsDirectory, withIntermediateDirectories: true)

        return locations
    }

    private static func defaultFallbackBaseURL(
        fileManager: FileManager,
        fallbackBaseURL: URL?
    ) -> URL {
        if let fallbackBaseURL {
            return fallbackBaseURL
        }

        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport.appendingPathComponent(fallbackDirectoryName, isDirectory: true)
        }

        return fileManager.temporaryDirectory.appendingPathComponent(fallbackDirectoryName, isDirectory: true)
    }
}
