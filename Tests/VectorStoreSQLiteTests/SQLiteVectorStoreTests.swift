import Foundation
import RAGCore
import Testing
@testable import VectorStoreSQLite

@Test func staticallyLinkedSQLiteVecReportsVendoredVersions() {
    #expect(SQLiteVecBuild.sqliteVersion == "3.53.3")
    #expect(SQLiteVecBuild.sqliteVecVersion == "v0.1.10-alpha.4")
}

@Test func vectorStoreIndexesOneHundredChunksAndReturnsDeterministicTopK() async throws {
    let url = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let configuration = SQLiteIndexConfiguration.file(
        url,
        embeddingEngineID: "test-embedding",
        expectedDimension: 3
    )
    let store = SQLiteVectorStore(configuration: configuration)
    let chunks = makeChunks()

    try await store.upsert(vectorEntries(for: chunks))

    let results = try await store.query(vector: [99, 4, 1], topK: 3)
    #expect(results.map(\.chunkID) == ["chunk-099", "chunk-098", "chunk-097"])

    let tieA = Chunk(id: "tie-a", clipID: "tie", text: "same vector a", indexInClip: 0)
    let tieB = Chunk(id: "tie-b", clipID: "tie", text: "same vector b", indexInClip: 1)
    try await store.upsert([
        (chunk: tieB, vector: [500, 0, 0]),
        (chunk: tieA, vector: [500, 0, 0]),
    ])

    let tieResults = try await store.query(vector: [500, 0, 0], topK: 2)
    #expect(tieResults.map(\.chunkID) == ["tie-a", "tie-b"])
}

@Test func keywordIndexUsesFTS5TrigramForChineseSubstringSearch() async throws {
    let url = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let keywordIndex = FTS5KeywordIndex(configuration: .file(url))
    try await keywordIndex.index(makeChunks())

    let results = try await keywordIndex.query(text: "中文子串", topK: 10)
    #expect(results.map(\.chunkID) == ["chunk-007", "chunk-042", "chunk-070"])
}

@Test func upsertReplacesExistingVectorForAChunk() async throws {
    let url = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = SQLiteVectorStore(
        configuration: .file(url, embeddingEngineID: "test-embedding", expectedDimension: 3)
    )
    let replaced = Chunk(id: "replace-me", clipID: "clip-replace", text: "replace me", indexInClip: 0)
    let neighbor = Chunk(id: "neighbor", clipID: "clip-replace", text: "near the old vector", indexInClip: 1)

    try await store.upsert([
        (chunk: replaced, vector: [0, 0, 0]),
        (chunk: neighbor, vector: [9, 9, 9]),
    ])
    #expect(try await store.query(vector: [0, 0, 0], topK: 1).map(\.chunkID) == ["replace-me"])

    try await store.upsert([(chunk: replaced, vector: [10, 10, 10])])

    #expect(try await store.query(vector: [0, 0, 0], topK: 1).map(\.chunkID) == ["neighbor"])
    #expect(try await store.query(vector: [10, 10, 10], topK: 1).map(\.chunkID) == ["replace-me"])
}

@Test func vectorStoreRejectsDimensionMismatchInsteadOfMixingIndexes() async throws {
    let url = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = SQLiteVectorStore(
        configuration: .file(url, embeddingEngineID: "test-embedding")
    )
    let chunk = Chunk(id: "dimensioned", clipID: "clip-dimension", text: "dimensioned", indexInClip: 0)

    try await store.upsert([(chunk: chunk, vector: [1, 2, 3])])

    do {
        try await store.upsert([(chunk: chunk, vector: [1, 2])])
        Issue.record("Expected dimension mismatch")
    } catch SQLiteIndexError.dimensionMismatch(let engineID, let expected, let actual) {
        #expect(engineID == "test-embedding:dimensioned")
        #expect(expected == 3)
        #expect(actual == 2)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func deleteClipCleansBothVectorAndKeywordIndexesInSameDatabase() async throws {
    let url = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let configuration = SQLiteIndexConfiguration.file(
        url,
        embeddingEngineID: "test-embedding",
        expectedDimension: 3
    )
    let vectorStore = SQLiteVectorStore(configuration: configuration)
    let keywordIndex = FTS5KeywordIndex(configuration: configuration)
    let chunks = makeChunks()

    try await vectorStore.upsert(vectorEntries(for: chunks))
    try await keywordIndex.index(chunks)

    try await vectorStore.deleteClip(clipID: "clip-a")
    try await keywordIndex.deleteClip(clipID: "clip-a")

    let vectorResults = try await vectorStore.query(vector: [7, 2, 1], topK: 20).map(\.chunkID)
    #expect(vectorResults.allSatisfy { numericSuffix($0) >= 50 })

    let keywordResults = try await keywordIndex.query(text: "中文子串", topK: 10)
    #expect(keywordResults.map(\.chunkID) == ["chunk-070"])
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-sqlite-\(UUID().uuidString)")
        .appendingPathExtension("db")
}

private func makeChunks() -> [Chunk] {
    (0..<100).map { index in
        let id = String(format: "chunk-%03d", index)
        let clipID = index < 50 ? "clip-a" : "clip-b"
        let text: String
        if [7, 42, 70].contains(index) {
            text = "第\(index)段包含中文子串检索测试，方便验证 trigram。"
        } else {
            text = "Memory chunk \(index) for local retrieval testing."
        }
        return Chunk(
            id: id,
            clipID: clipID,
            text: text,
            indexInClip: index,
            startOffset: index * 10,
            endOffset: index * 10 + text.count,
            preview: text
        )
    }
}

private func vectorEntries(for chunks: [Chunk]) -> [(chunk: Chunk, vector: [Float])] {
    chunks.map { chunk in
        let index = numericSuffix(chunk.id)
        return (chunk: chunk, vector: [Float(index), Float(index % 5), 1])
    }
}

private func numericSuffix(_ chunkID: String) -> Int {
    Int(chunkID.suffix(3)) ?? 0
}
