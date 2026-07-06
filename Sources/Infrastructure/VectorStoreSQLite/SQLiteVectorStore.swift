import CSQLiteVec
import Foundation
import RAGCore

public enum SQLiteVecBuild {
    public static var sqliteVersion: String {
        String(cString: engram_sqlite_version())
    }

    public static var sqliteVecVersion: String {
        String(cString: engram_sqlite_vec_version())
    }
}

public enum SQLiteIndexLocation: Sendable, Hashable {
    case inMemory(identifier: String)
    case file(URL)
}

public struct SQLiteIndexConfiguration: Sendable, Hashable {
    public let location: SQLiteIndexLocation
    public let embeddingEngineID: String
    public let expectedDimension: Int?

    public init(
        location: SQLiteIndexLocation,
        embeddingEngineID: String = "unconfigured",
        expectedDimension: Int? = nil
    ) {
        self.location = location
        self.embeddingEngineID = embeddingEngineID
        self.expectedDimension = expectedDimension
    }

    public static func inMemory(
        identifier: String = UUID().uuidString,
        embeddingEngineID: String = "unconfigured",
        expectedDimension: Int? = nil
    ) -> SQLiteIndexConfiguration {
        SQLiteIndexConfiguration(
            location: .inMemory(identifier: identifier),
            embeddingEngineID: embeddingEngineID,
            expectedDimension: expectedDimension
        )
    }

    public static func file(
        _ url: URL,
        embeddingEngineID: String = "unconfigured",
        expectedDimension: Int? = nil
    ) -> SQLiteIndexConfiguration {
        SQLiteIndexConfiguration(
            location: .file(url),
            embeddingEngineID: embeddingEngineID,
            expectedDimension: expectedDimension
        )
    }
}

public enum SQLiteIndexError: Error, Sendable, Equatable, CustomStringConvertible {
    case database(String)
    case invalidVector(String)
    case dimensionMismatch(engineID: String, expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .database(let message):
            "SQLite index error: \(message)"
        case .invalidVector(let reason):
            "Invalid vector: \(reason)"
        case .dimensionMismatch(let engineID, let expected, let actual):
            "Embedding dimension mismatch for \(engineID): expected \(expected), got \(actual)"
        }
    }
}

/// Dense index backed by statically linked SQLite + sqlite-vec. The concrete
/// database URL is injected by the app composition root in a later package.
public actor SQLiteVectorStore: VectorStore, ChunkResolver {
    private let configuration: SQLiteIndexConfiguration
    private let database: SQLiteConnection
    private var schemaReady = false

    public init() {
        self.init(configuration: .inMemory())
    }

    public init(configuration: SQLiteIndexConfiguration) {
        self.configuration = configuration
        self.database = SQLiteConnection(location: configuration.location)
    }

    public init(
        databaseURL: URL,
        embeddingEngineID: String = "unconfigured",
        expectedDimension: Int? = nil
    ) {
        self.init(
            configuration: .file(
                databaseURL,
                embeddingEngineID: embeddingEngineID,
                expectedDimension: expectedDimension
            )
        )
    }

    public func upsert(_ entries: [(chunk: Chunk, vector: [Float])]) async throws {
        guard !entries.isEmpty else {
            return
        }

        let dimension = try validateBatch(entries.map(\.vector))
        try ensureSchema()
        try ensureVectorTable(dimension: dimension)

        let tableName = vectorTableName(dimension: dimension)
        try database.transaction {
            for entry in entries {
                let rowID = try upsertChunk(entry.chunk)
                try rejectStoredDimensionMismatch(chunkID: entry.chunk.id, rowID: rowID, dimension: dimension)
                try database.execute(sql: "DELETE FROM \(tableName) WHERE rowid = ?", bindings: [.int64(rowID)])
                try database.execute(
                    sql: "INSERT INTO \(tableName)(rowid, embedding) VALUES (?, ?)",
                    bindings: [.int64(rowID), .text(Self.vectorJSON(entry.vector))]
                )
                try database.execute(
                    sql: """
                    INSERT INTO engram_chunk_vectors(chunk_rowid, engine_id, dimension, table_name)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(chunk_rowid, engine_id) DO UPDATE SET
                        dimension = excluded.dimension,
                        table_name = excluded.table_name
                    """,
                    bindings: [
                        .int64(rowID),
                        .text(configuration.embeddingEngineID),
                        .int64(Int64(dimension)),
                        .text(tableName),
                    ]
                )
            }
        }
    }

    public func query(vector: [Float], topK: Int) async throws -> [ScoredChunk] {
        guard topK > 0 else {
            return []
        }

        let dimension = try validateVector(vector)
        try ensureSchema()

        guard try hasVectorTable(dimension: dimension) else {
            return []
        }

        let tableName = vectorTableName(dimension: dimension)
        return try database.query(
            sql: """
            SELECT c.chunk_id, v.distance
            FROM \(tableName) AS v
            INNER JOIN engram_chunk_vectors AS cv
                ON cv.chunk_rowid = v.rowid
            INNER JOIN engram_chunks AS c
                ON c.rowid = cv.chunk_rowid
            WHERE v.embedding MATCH ?
                AND v.k = ?
                AND cv.engine_id = ?
                AND cv.dimension = ?
            ORDER BY v.distance ASC, c.chunk_id ASC
            LIMIT ?
            """,
            bindings: [
                .text(Self.vectorJSON(vector)),
                .int64(Int64(topK)),
                .text(configuration.embeddingEngineID),
                .int64(Int64(dimension)),
                .int64(Int64(topK)),
            ]
        ) { statement in
            let chunkID = try statement.text(at: 0)
            let distance = sqlite3_column_double(statement.raw, 1)
            return ScoredChunk(chunkID: chunkID, score: 1.0 / (1.0 + distance))
        }
    }

    public func deleteClip(clipID: String) async throws {
        try ensureSchema()
        let rows = try database.query(
            sql: """
            SELECT cv.chunk_rowid, cv.table_name
            FROM engram_chunk_vectors AS cv
            INNER JOIN engram_chunks AS c ON c.rowid = cv.chunk_rowid
            WHERE c.clip_id = ? AND cv.engine_id = ?
            ORDER BY cv.chunk_rowid ASC
            """,
            bindings: [.text(clipID), .text(configuration.embeddingEngineID)]
        ) { statement in
            (try statement.int64(at: 0), try statement.text(at: 1))
        }

        try database.transaction {
            for row in rows {
                try database.execute(sql: "DELETE FROM \(row.1) WHERE rowid = ?", bindings: [.int64(row.0)])
            }
            try database.execute(
                sql: """
                DELETE FROM engram_chunk_vectors
                WHERE engine_id = ?
                    AND chunk_rowid IN (SELECT rowid FROM engram_chunks WHERE clip_id = ?)
                """,
                bindings: [.text(configuration.embeddingEngineID), .text(clipID)]
            )
            try pruneChunksWithoutIndexes(clipID: clipID)
        }
    }

    public func resolve(chunkIDs: [String]) async throws -> [String: Chunk] {
        guard !chunkIDs.isEmpty else {
            return [:]
        }

        try ensureSchema()
        let placeholders = Array(repeating: "?", count: chunkIDs.count).joined(separator: ", ")
        let chunks = try database.query(
            sql: """
            SELECT chunk_id, clip_id, text, index_in_clip, start_offset, end_offset, preview
            FROM engram_chunks
            WHERE chunk_id IN (\(placeholders))
            """,
            bindings: chunkIDs.map(SQLiteBinding.text)
        ) { statement in
            Chunk(
                id: try statement.text(at: 0),
                clipID: try statement.text(at: 1),
                text: try statement.text(at: 2),
                indexInClip: try statement.int(at: 3),
                startOffset: try statement.optionalInt(at: 4),
                endOffset: try statement.optionalInt(at: 5),
                preview: try statement.optionalText(at: 6)
            )
        }

        return Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
    }

    private func ensureSchema() throws {
        guard !schemaReady else {
            return
        }
        try database.open()
        try createSharedChunkSchema(database)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS engram_vector_tables(
            engine_id TEXT NOT NULL,
            dimension INTEGER NOT NULL,
            table_name TEXT NOT NULL,
            PRIMARY KEY(engine_id, dimension)
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS engram_chunk_vectors(
            chunk_rowid INTEGER NOT NULL,
            engine_id TEXT NOT NULL,
            dimension INTEGER NOT NULL,
            table_name TEXT NOT NULL,
            PRIMARY KEY(chunk_rowid, engine_id),
            FOREIGN KEY(chunk_rowid) REFERENCES engram_chunks(rowid) ON DELETE CASCADE
        )
        """)
        schemaReady = true
    }

    private func ensureVectorTable(dimension: Int) throws {
        let tableName = vectorTableName(dimension: dimension)
        try database.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS \(tableName) USING vec0(embedding float[\(dimension)])")
        try database.execute(
            sql: """
            INSERT INTO engram_vector_tables(engine_id, dimension, table_name)
            VALUES (?, ?, ?)
            ON CONFLICT(engine_id, dimension) DO UPDATE SET table_name = excluded.table_name
            """,
            bindings: [
                .text(configuration.embeddingEngineID),
                .int64(Int64(dimension)),
                .text(tableName),
            ]
        )
    }

    private func hasVectorTable(dimension: Int) throws -> Bool {
        try database.query(
            sql: """
            SELECT table_name
            FROM engram_vector_tables
            WHERE engine_id = ? AND dimension = ?
            LIMIT 1
            """,
            bindings: [.text(configuration.embeddingEngineID), .int64(Int64(dimension))]
        ) { _ in true }.first == true
    }

    private func validateBatch(_ vectors: [[Float]]) throws -> Int {
        let dimension = try validateVector(vectors[0])
        for vector in vectors.dropFirst() {
            let actual = try validateVector(vector)
            guard actual == dimension else {
                throw SQLiteIndexError.dimensionMismatch(
                    engineID: configuration.embeddingEngineID,
                    expected: dimension,
                    actual: actual
                )
            }
        }
        return dimension
    }

    private func validateVector(_ vector: [Float]) throws -> Int {
        guard !vector.isEmpty else {
            throw SQLiteIndexError.invalidVector("vector must not be empty")
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw SQLiteIndexError.invalidVector("vector contains NaN or infinity")
        }
        if let expectedDimension = configuration.expectedDimension, vector.count != expectedDimension {
            throw SQLiteIndexError.dimensionMismatch(
                engineID: configuration.embeddingEngineID,
                expected: expectedDimension,
                actual: vector.count
            )
        }
        return vector.count
    }

    private func rejectStoredDimensionMismatch(chunkID: String, rowID: Int64, dimension: Int) throws {
        let storedDimensions = try database.query(
            sql: """
            SELECT dimension
            FROM engram_chunk_vectors
            WHERE chunk_rowid = ? AND engine_id = ?
            """,
            bindings: [.int64(rowID), .text(configuration.embeddingEngineID)]
        ) { statement in
            try statement.int(at: 0)
        }

        if let storedDimension = storedDimensions.first, storedDimension != dimension {
            throw SQLiteIndexError.dimensionMismatch(
                engineID: "\(configuration.embeddingEngineID):\(chunkID)",
                expected: storedDimension,
                actual: dimension
            )
        }
    }

    private func upsertChunk(_ chunk: Chunk) throws -> Int64 {
        try database.execute(
            sql: """
            INSERT INTO engram_chunks(
                chunk_id,
                clip_id,
                text,
                index_in_clip,
                start_offset,
                end_offset,
                preview
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(chunk_id) DO UPDATE SET
                clip_id = excluded.clip_id,
                text = excluded.text,
                index_in_clip = excluded.index_in_clip,
                start_offset = excluded.start_offset,
                end_offset = excluded.end_offset,
                preview = excluded.preview
            """,
            bindings: [
                .text(chunk.id),
                .text(chunk.clipID),
                .text(chunk.text),
                .int64(Int64(chunk.indexInClip)),
                .optionalInt(chunk.startOffset),
                .optionalInt(chunk.endOffset),
                .optionalText(chunk.preview),
            ]
        )

        let rowIDs = try database.query(
            sql: "SELECT rowid FROM engram_chunks WHERE chunk_id = ? LIMIT 1",
            bindings: [.text(chunk.id)]
        ) { statement in
            try statement.int64(at: 0)
        }

        guard let rowID = rowIDs.first else {
            throw SQLiteIndexError.database("missing rowid after chunk upsert for \(chunk.id)")
        }
        return rowID
    }

    private func pruneChunksWithoutIndexes(clipID: String) throws {
        try Self.pruneChunksWithoutIndexes(database: database, clipID: clipID)
    }

    fileprivate static func pruneChunksWithoutIndexes(database: SQLiteConnection, clipID: String) throws {
        try database.execute(
            sql: """
            DELETE FROM engram_chunks
            WHERE clip_id = ?
                AND rowid NOT IN (SELECT chunk_rowid FROM engram_chunk_vectors)
                AND (
                    NOT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'engram_chunk_fts')
                    OR rowid NOT IN (SELECT rowid FROM engram_chunk_fts)
                )
            """,
            bindings: [.text(clipID)]
        )
    }

    private func vectorTableName(dimension: Int) -> String {
        let engineComponent = configuration.embeddingEngineID
            .unicodeScalars
            .map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
            }
            .joined()
        let safeEngineComponent = engineComponent.isEmpty ? "unconfigured" : engineComponent
        return "engram_vec_\(safeEngineComponent)_f32_\(dimension)"
    }

    private static func vectorJSON(_ vector: [Float]) -> String {
        "[" + vector.map { String(Double($0)) }.joined(separator: ",") + "]"
    }
}

/// Sparse index backed by the same SQLite database with FTS5 trigram tokenization.
public actor FTS5KeywordIndex: KeywordIndex {
    private let configuration: SQLiteIndexConfiguration
    private let database: SQLiteConnection
    private var schemaReady = false

    public init() {
        self.init(configuration: .inMemory())
    }

    public init(configuration: SQLiteIndexConfiguration) {
        self.configuration = configuration
        self.database = SQLiteConnection(location: configuration.location)
    }

    public init(databaseURL: URL) {
        self.init(configuration: .file(databaseURL))
    }

    public func index(_ chunks: [Chunk]) async throws {
        guard !chunks.isEmpty else {
            return
        }

        try ensureSchema()
        try database.transaction {
            for chunk in chunks {
                let rowID = try upsertChunk(chunk)
                try database.execute(sql: "DELETE FROM engram_chunk_fts WHERE rowid = ?", bindings: [.int64(rowID)])
                try database.execute(
                    sql: """
                    INSERT INTO engram_chunk_fts(rowid, chunk_id, clip_id, text)
                    VALUES (?, ?, ?, ?)
                    """,
                    bindings: [
                        .int64(rowID),
                        .text(chunk.id),
                        .text(chunk.clipID),
                        .text(chunk.text),
                    ]
                )
            }
        }
    }

    public func query(text: String, topK: Int) async throws -> [ScoredChunk] {
        guard topK > 0 else {
            return []
        }

        let queryText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queryText.isEmpty else {
            return []
        }

        try ensureSchema()

        if queryText.count < 3 {
            return try database.query(
                sql: """
                SELECT chunk_id
                FROM engram_chunk_fts
                WHERE text LIKE ?
                ESCAPE '\'
                ORDER BY chunk_id ASC
                LIMIT ?
                """,
                bindings: [.text("%\(Self.escapeLike(queryText))%"), .int64(Int64(topK))]
            ) { statement in
                ScoredChunk(chunkID: try statement.text(at: 0), score: 1.0)
            }
        }

        return try database.query(
            sql: """
            SELECT chunk_id, rank
            FROM engram_chunk_fts
            WHERE engram_chunk_fts MATCH ?
            ORDER BY rank ASC, chunk_id ASC
            LIMIT ?
            """,
            bindings: [.text(Self.ftsPhrase(queryText)), .int64(Int64(topK))]
        ) { statement in
            let chunkID = try statement.text(at: 0)
            let rank = sqlite3_column_double(statement.raw, 1)
            return ScoredChunk(chunkID: chunkID, score: -rank)
        }
    }

    public func deleteClip(clipID: String) async throws {
        try ensureSchema()
        try database.transaction {
            try database.execute(
                sql: """
                DELETE FROM engram_chunk_fts
                WHERE rowid IN (SELECT rowid FROM engram_chunks WHERE clip_id = ?)
                """,
                bindings: [.text(clipID)]
            )
            try SQLiteVectorStore.pruneChunksWithoutIndexes(database: database, clipID: clipID)
        }
    }

    private func ensureSchema() throws {
        guard !schemaReady else {
            return
        }
        try database.open()
        try createSharedChunkSchema(database)
        try database.execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS engram_chunk_fts
        USING fts5(
            chunk_id UNINDEXED,
            clip_id UNINDEXED,
            text,
            tokenize = 'trigram'
        )
        """)
        schemaReady = true
    }

    private func upsertChunk(_ chunk: Chunk) throws -> Int64 {
        try database.execute(
            sql: """
            INSERT INTO engram_chunks(
                chunk_id,
                clip_id,
                text,
                index_in_clip,
                start_offset,
                end_offset,
                preview
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(chunk_id) DO UPDATE SET
                clip_id = excluded.clip_id,
                text = excluded.text,
                index_in_clip = excluded.index_in_clip,
                start_offset = excluded.start_offset,
                end_offset = excluded.end_offset,
                preview = excluded.preview
            """,
            bindings: [
                .text(chunk.id),
                .text(chunk.clipID),
                .text(chunk.text),
                .int64(Int64(chunk.indexInClip)),
                .optionalInt(chunk.startOffset),
                .optionalInt(chunk.endOffset),
                .optionalText(chunk.preview),
            ]
        )

        let rowIDs = try database.query(
            sql: "SELECT rowid FROM engram_chunks WHERE chunk_id = ? LIMIT 1",
            bindings: [.text(chunk.id)]
        ) { statement in
            try statement.int64(at: 0)
        }

        guard let rowID = rowIDs.first else {
            throw SQLiteIndexError.database("missing rowid after keyword chunk upsert for \(chunk.id)")
        }
        return rowID
    }

    private static func ftsPhrase(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func escapeLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

private func createSharedChunkSchema(_ database: SQLiteConnection) throws {
    try database.execute(sql: """
    CREATE TABLE IF NOT EXISTS engram_chunks(
        rowid INTEGER PRIMARY KEY AUTOINCREMENT,
        chunk_id TEXT NOT NULL UNIQUE,
        clip_id TEXT NOT NULL,
        text TEXT NOT NULL,
        index_in_clip INTEGER NOT NULL,
        start_offset INTEGER,
        end_offset INTEGER,
        preview TEXT
    )
    """)
    try database.execute(sql: "CREATE INDEX IF NOT EXISTS idx_engram_chunks_clip_id ON engram_chunks(clip_id)")
}

private enum SQLiteBinding {
    case int64(Int64)
    case null
    case text(String)

    static func optionalInt(_ value: Int?) -> SQLiteBinding {
        value.map { .int64(Int64($0)) } ?? .null
    }

    static func optionalText(_ value: String?) -> SQLiteBinding {
        value.map(SQLiteBinding.text) ?? .null
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    private let location: SQLiteIndexLocation
    private var raw: OpaquePointer?

    init(location: SQLiteIndexLocation) {
        self.location = location
    }

    deinit {
        if let raw {
            sqlite3_close(raw)
        }
    }

    func open() throws {
        guard raw == nil else {
            return
        }

        let path: String
        let flags: Int32
        switch location {
        case .inMemory(let identifier):
            path = "file:\(identifier)?mode=memory&cache=shared"
            flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        case .file(let url):
            path = url.path
            flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        }

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &handle, flags, nil)
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to allocate sqlite handle"
            if let handle {
                sqlite3_close(handle)
            }
            throw SQLiteIndexError.database(message)
        }

        raw = handle

        let registerResult = engram_sqlite_vec_register(handle)
        guard registerResult == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw SQLiteIndexError.database("sqlite-vec static registration failed: \(message)")
        }

        try execute(sql: "PRAGMA foreign_keys = ON")
    }

    func execute(sql: String, bindings: [SQLiteBinding] = []) throws {
        try open()
        let statement = try SQLiteStatement(connection: self, sql: sql)
        try statement.bind(bindings)
        let result = sqlite3_step(statement.raw)
        guard result == SQLITE_DONE else {
            throw SQLiteIndexError.database(lastErrorMessage())
        }
    }

    func query<Value>(
        sql: String,
        bindings: [SQLiteBinding] = [],
        map: (SQLiteStatement) throws -> Value
    ) throws -> [Value] {
        try open()
        let statement = try SQLiteStatement(connection: self, sql: sql)
        try statement.bind(bindings)

        var values: [Value] = []
        while true {
            let result = sqlite3_step(statement.raw)
            switch result {
            case SQLITE_ROW:
                values.append(try map(statement))
            case SQLITE_DONE:
                return values
            default:
                throw SQLiteIndexError.database(lastErrorMessage())
            }
        }
    }

    func transaction(_ operation: () throws -> Void) throws {
        try execute(sql: "BEGIN IMMEDIATE")
        do {
            try operation()
            try execute(sql: "COMMIT")
        } catch {
            try? execute(sql: "ROLLBACK")
            throw error
        }
    }

    fileprivate func prepare(sql: String, statement: inout OpaquePointer?) throws {
        try open()
        let result = sqlite3_prepare_v2(raw, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw SQLiteIndexError.database(lastErrorMessage())
        }
    }

    fileprivate func lastErrorMessage() -> String {
        guard let raw else {
            return "sqlite connection is not open"
        }
        return String(cString: sqlite3_errmsg(raw))
    }
}

private final class SQLiteStatement {
    let raw: OpaquePointer

    init(connection: SQLiteConnection, sql: String) throws {
        var statement: OpaquePointer?
        try connection.prepare(sql: sql, statement: &statement)
        guard let statement else {
            throw SQLiteIndexError.database("unable to prepare statement")
        }
        raw = statement
    }

    deinit {
        sqlite3_finalize(raw)
    }

    func bind(_ bindings: [SQLiteBinding]) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .int64(let value):
                result = sqlite3_bind_int64(raw, index, value)
            case .null:
                result = sqlite3_bind_null(raw, index)
            case .text(let value):
                result = sqlite3_bind_text(raw, index, value, -1, sqliteTransient)
            }
            guard result == SQLITE_OK else {
                throw SQLiteIndexError.database("bind failed at index \(index)")
            }
        }
    }

    func text(at index: Int32) throws -> String {
        guard let value = sqlite3_column_text(raw, index) else {
            throw SQLiteIndexError.database("expected text at column \(index)")
        }
        return String(cString: value)
    }

    func optionalText(at index: Int32) throws -> String? {
        guard sqlite3_column_type(raw, index) != SQLITE_NULL else {
            return nil
        }
        return try text(at: index)
    }

    func int(at index: Int32) throws -> Int {
        Int(try int64(at: index))
    }

    func optionalInt(at index: Int32) throws -> Int? {
        guard sqlite3_column_type(raw, index) != SQLITE_NULL else {
            return nil
        }
        return try int(at: index)
    }

    func int64(at index: Int32) throws -> Int64 {
        sqlite3_column_int64(raw, index)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
