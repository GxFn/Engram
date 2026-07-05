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
    /// M1 uses the default app container; M2 moves storage into the App Group
    /// container so the Share Extension writes the same store.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: ClipRecord.self, configurations: configuration)
    }
}
