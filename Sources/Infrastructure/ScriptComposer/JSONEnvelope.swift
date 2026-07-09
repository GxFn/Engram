import Foundation

/// Extracts JSON object/array blocks from a possibly prose-wrapped LLM response — models wrap the
/// JSON in explanations, ```json fences, or emit example blocks around the real one. Shared by the
/// script / paradigm / transcript composers so this fragile parse lives in one place.
enum JSONEnvelope {
    /// The first balanced block, or (when nothing balances — e.g. token-truncated output) the naive
    /// first-open…last-close slice so the decoder still gets a shot at lenient recovery.
    static func slice(_ text: String, open: Character, close: Character) -> Data? {
        if let first = candidates(text, open: open, close: close).first {
            return first
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: open),
              let end = trimmed.lastIndex(of: close),
              start <= end
        else {
            return nil
        }
        return Data(trimmed[start ... end].utf8)
    }

    /// All complete balanced `open…close` blocks, in order, scanned string-literal and escape
    /// aware — so a brace inside a quoted value or a prose sentence with braces before the real
    /// JSON doesn't derail extraction. Callers try candidates until one decodes (the old
    /// first-open to last-close slice broke whenever surrounding text contained the delimiters).
    static func candidates(
        _ text: String,
        open: Character,
        close: Character,
        limit: Int = 4
    ) -> [Data] {
        let chars = Array(text)
        var results: [Data] = []
        var searchStart = chars.startIndex

        while results.count < limit,
              let start = chars[searchStart...].firstIndex(of: open) {
            var depth = 0
            var inString = false
            var escaped = false
            var index = start
            var closedAt: Int?

            scan: while index < chars.endIndex {
                let character = chars[index]
                if escaped {
                    escaped = false
                } else if inString {
                    if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                } else if character == "\"" {
                    inString = true
                } else if character == open {
                    depth += 1
                } else if character == close {
                    depth -= 1
                    if depth == 0 {
                        closedAt = index
                        break scan
                    }
                }
                index += 1
            }

            guard let end = closedAt else {
                break // unbalanced from here on (e.g. truncated output) — no more candidates
            }
            results.append(Data(String(chars[start ... end]).utf8))
            searchStart = end + 1
        }

        return results
    }
}
