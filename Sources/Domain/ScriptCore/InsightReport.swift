import Foundation

/// A cross-video insight report (v6 P3): the LLM's structured synthesis over a set of hooks —
/// recurring 套路, common reasons-they-work, topic clusters, and reusable 起号 advice. Every
/// section carries an evidence trail (source clip ids) so an insight is verifiable, not black-box.
/// Derived from breakdowns; persisted by the shell so it can be revisited and re-run.
public struct InsightReport: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let scopeDescription: String
    public let sourceCount: Int
    public let createdAt: Date
    public let sections: [InsightSection]

    public init(
        id: String,
        title: String,
        scopeDescription: String,
        sourceCount: Int,
        createdAt: Date,
        sections: [InsightSection]
    ) {
        self.id = id
        self.title = title
        self.scopeDescription = scopeDescription
        self.sourceCount = sourceCount
        self.createdAt = createdAt
        self.sections = sections
    }
}

public struct InsightSection: Sendable, Hashable, Codable, Identifiable {
    public let heading: String
    public let body: String
    /// Source clip ids backing this section — the evidence trail.
    public let evidenceClipIDs: [String]

    public var id: String { heading }

    public init(heading: String, body: String, evidenceClipIDs: [String]) {
        self.heading = heading
        self.body = body
        self.evidenceClipIDs = evidenceClipIDs
    }
}
