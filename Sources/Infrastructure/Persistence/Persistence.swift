import AppGroupSupport
import ClipCore
import Foundation
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
    public var createdAt: Date
    public var stateRaw: String

    public init(
        id: String,
        title: String?,
        note: String?,
        bodyText: String?,
        urlString: String?,
        createdAt: Date,
        stateRaw: String
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.bodyText = bodyText
        self.urlString = urlString
        self.createdAt = createdAt
        self.stateRaw = stateRaw
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
