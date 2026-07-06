import Foundation
import RAGCore

public struct RetrievalEvalClipFixture: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let title: String
    public let bodyText: String

    public init(id: String, title: String, bodyText: String) {
        self.id = id
        self.title = title
        self.bodyText = bodyText
    }
}

public struct RetrievalEvalChunkFixture: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let clipID: String
    public let text: String

    public init(id: String, clipID: String, text: String) {
        self.id = id
        self.clipID = clipID
        self.text = text
    }

    public var chunk: Chunk {
        Chunk(
            id: id,
            clipID: clipID,
            text: text,
            indexInClip: 0,
            preview: String(text.prefix(180))
        )
    }
}

public struct RetrievalEvalQuestion: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let question: String
    public let relevantClipIDs: [String]

    public init(id: String, question: String, relevantClipIDs: [String]) {
        self.id = id
        self.question = question
        self.relevantClipIDs = relevantClipIDs
    }
}

public struct RetrievalEvalSuite: Sendable, Hashable, Codable {
    public let clips: [RetrievalEvalClipFixture]
    public let chunks: [RetrievalEvalChunkFixture]
    public let questions: [RetrievalEvalQuestion]

    public init(
        clips: [RetrievalEvalClipFixture],
        chunks: [RetrievalEvalChunkFixture],
        questions: [RetrievalEvalQuestion]
    ) {
        self.clips = clips
        self.chunks = chunks
        self.questions = questions
    }

    public static func bundled() throws -> RetrievalEvalSuite {
        try bundled(bundle: .module)
    }

    public static func bundled(bundle: Bundle) throws -> RetrievalEvalSuite {
        let url = bundle.url(
            forResource: "retrieval-eval",
            withExtension: "json",
            subdirectory: "BenchSuite"
        ) ?? bundle.url(
            forResource: "retrieval-eval",
            withExtension: "json"
        )

        guard let url else {
            throw RetrievalEvalError.missingSuiteResource
        }

        return try load(from: url)
    }

    public static func load(from url: URL) throws -> RetrievalEvalSuite {
        let data = try Data(contentsOf: url)
        let suite = try JSONDecoder().decode(RetrievalEvalSuite.self, from: data)
        try suite.validate()
        return suite
    }

    public func validate() throws {
        guard (20...50).contains(questions.count) else {
            throw RetrievalEvalError.invalidSuite("expected 20-50 questions, got \(questions.count)")
        }
        guard !clips.isEmpty else {
            throw RetrievalEvalError.invalidSuite("clips must not be empty")
        }
        guard !chunks.isEmpty else {
            throw RetrievalEvalError.invalidSuite("chunks must not be empty")
        }

        try Self.requireUnique(clips.map(\.id), label: "clip ids")
        try Self.requireUnique(chunks.map(\.id), label: "chunk ids")
        try Self.requireUnique(questions.map(\.id), label: "question ids")

        let clipIDs = Set(clips.map(\.id))
        for chunk in chunks {
            guard clipIDs.contains(chunk.clipID) else {
                throw RetrievalEvalError.invalidSuite("chunk \(chunk.id) references missing clip \(chunk.clipID)")
            }
            guard !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RetrievalEvalError.invalidSuite("chunk \(chunk.id) is empty")
            }
        }

        for question in questions {
            guard !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RetrievalEvalError.invalidSuite("question \(question.id) is empty")
            }
            guard !question.relevantClipIDs.isEmpty else {
                throw RetrievalEvalError.invalidSuite("question \(question.id) has no relevant clips")
            }
            for clipID in question.relevantClipIDs where !clipIDs.contains(clipID) {
                throw RetrievalEvalError.invalidSuite("question \(question.id) references missing clip \(clipID)")
            }
        }
    }

    private static func requireUnique(_ values: [String], label: String) throws {
        var seen = Set<String>()
        for value in values {
            guard seen.insert(value).inserted else {
                throw RetrievalEvalError.invalidSuite("duplicate \(label): \(value)")
            }
        }
    }
}

public enum RetrievalEvalError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingSuiteResource
    case invalidSuite(String)
    case noRetrievalClient

    public var description: String {
        switch self {
        case .missingSuiteResource:
            "Missing BenchSuite/retrieval-eval.json"
        case .invalidSuite(let reason):
            "Invalid retrieval eval suite: \(reason)"
        case .noRetrievalClient:
            "Retrieval evaluation is not wired."
        }
    }
}
