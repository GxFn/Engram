import Foundation

/// Extracts the outermost JSON object/array from a possibly prose-wrapped LLM response — models
/// occasionally wrap the JSON in explanation or ```json fences. Returns the `open`…`close` slice as
/// Data, or nil when no balanced pair is present. Shared by the script / paradigm / transcript
/// composers so this fragile parse lives in one place.
enum JSONEnvelope {
    static func slice(_ text: String, open: Character, close: Character) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: open),
              let end = trimmed.lastIndex(of: close),
              start <= end
        else {
            return nil
        }
        return Data(trimmed[start ... end].utf8)
    }
}
