import Foundation

/// Pure-domain Script JSON codec so feature modules can read a persisted script
/// without depending on any Infrastructure (SwiftData/persistence) target.
public enum ScriptCoding {
    /// Decodes a persisted script JSON blob. Returns nil for empty or malformed
    /// input so callers (e.g. Memory detail) can gracefully fall back to plain body text.
    public static func decode(json: String?) -> Script? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Script.self, from: data)
    }
}
