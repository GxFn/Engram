import AppGroupSupport
import Foundation
import Persistence
import SwiftData
import Testing

@Test func appGroupLocationsUseConfiguredGroupContainer() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    var requestedIdentifier: String?
    let locations = try EngramAppGroup.locations(containerURL: { identifier in
        requestedIdentifier = identifier
        return root
    })

    #expect(requestedIdentifier == "group.com.gxfn.engram")
    #expect(locations.groupIdentifier == "group.com.gxfn.engram")
    #expect(locations.usesAppGroupContainer)
    #expect(locations.rootDirectory == root)
    #expect(locations.storeURL == root.appendingPathComponent("Engram.store"))
    #expect(locations.queueDirectory == root.appendingPathComponent("queue", isDirectory: true))
    #expect(locations.modelsDirectory == root.appendingPathComponent("Models", isDirectory: true))
    #expect(FileManager.default.fileExists(atPath: locations.queueDirectory.path))
    #expect(FileManager.default.fileExists(atPath: locations.modelsDirectory.path))
}

@Test func appGroupLocationsFallbackWhenContainerIsUnavailable() throws {
    let fallbackRoot = try makeTemporaryDirectory()
        .appendingPathComponent("FallbackAppSupport", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fallbackRoot.deletingLastPathComponent()) }

    let locations = try EngramAppGroup.locations(
        containerURL: { _ in nil },
        fallbackBaseURL: fallbackRoot
    )

    #expect(!locations.usesAppGroupContainer)
    #expect(locations.rootDirectory == fallbackRoot)
    #expect(locations.storeURL.lastPathComponent == "Engram.store")
    #expect(FileManager.default.fileExists(atPath: locations.rootDirectory.path))
    #expect(FileManager.default.fileExists(atPath: locations.queueDirectory.path))
    #expect(FileManager.default.fileExists(atPath: locations.modelsDirectory.path))
}

@Test func persistenceStackStoresSwiftDataAtAppGroupStoreURL() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let storeURL = try PersistenceStack.storeURL(appGroupContainerURL: { _ in root })
    #expect(storeURL == root.appendingPathComponent("Engram.store"))

    let container = try PersistenceStack.makeContainer(appGroupContainerURL: { _ in root })
    let context = ModelContext(container)
    let record = ClipRecord(
        id: UUID().uuidString,
        title: "Shared store",
        note: nil,
        bodyText: "Stored through the App Group path.",
        urlString: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        stateRaw: "indexed"
    )

    context.insert(record)
    try context.save()

    #expect(FileManager.default.fileExists(atPath: storeURL.path))
}

@Test func persistenceStackFallsBackWhenAppGroupContainerIsUnavailable() throws {
    let fallbackRoot = try makeTemporaryDirectory()
        .appendingPathComponent("FallbackAppSupport", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fallbackRoot.deletingLastPathComponent()) }

    let storeURL = try PersistenceStack.storeURL(
        appGroupContainerURL: { _ in nil },
        fallbackBaseURL: fallbackRoot
    )

    #expect(storeURL == fallbackRoot.appendingPathComponent("Engram.store"))
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
