import Foundation

public struct ExtractedArticle: Equatable, Sendable {
    public let title: String?
    public let bodyText: String

    public init(title: String?, bodyText: String) {
        self.title = title
        self.bodyText = bodyText
    }
}

public enum ArticleExtractionError: Error, Equatable, Sendable {
    case emptyBody
}

public struct ArticleExtractor: Sendable {
    public init() {}

    public func extract(html: String, fallbackTitle: String? = nil) throws -> ExtractedArticle {
        let title = normalizedText(firstBlock(named: "title", in: html)) ?? fallbackTitle
        let contentHTML = firstBlock(named: "article", in: html)
            ?? firstBlock(named: "main", in: html)
            ?? html
        let cleanedHTML = removeBlocks(
            named: ["script", "style", "nav", "noscript", "header", "footer", "aside"],
            from: contentHTML
        )
        let paragraphText = paragraphBodies(in: cleanedHTML)
            .map(decodeEntities)
            .compactMap(normalizedText)
        let bodyText = paragraphText.isEmpty
            ? normalizedText(decodeEntities(stripTags(from: cleanedHTML)))
            : paragraphText.joined(separator: "\n\n")

        guard let bodyText, !bodyText.isEmpty else {
            throw ArticleExtractionError.emptyBody
        }

        return ExtractedArticle(title: normalizedText(decodeEntities(stripTags(from: title ?? ""))), bodyText: bodyText)
    }

    private func firstBlock(named tag: String, in html: String) -> String? {
        let pattern = "<\(tag)\\b[^>]*>(.*?)</\(tag)>"
        return firstCapture(pattern: pattern, in: html)
    }

    private func paragraphBodies(in html: String) -> [String] {
        captures(pattern: "<p\\b[^>]*>(.*?)</p>", in: html)
    }

    private func removeBlocks(named tags: [String], from html: String) -> String {
        tags.reduce(html) { current, tag in
            replacing(pattern: "<\(tag)\\b[^>]*>.*?</\(tag)>", in: current, with: " ")
        }
    }

    private func stripTags(from html: String) -> String {
        replacing(pattern: "<[^>]+>", in: html, with: " ")
    }

    private func firstCapture(pattern: String, in string: String) -> String? {
        captures(pattern: pattern, in: string).first
    }

    private func captures(pattern: String, in string: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: string)
            else {
                return nil
            }
            return String(string[captureRange])
        }
    }

    private func replacing(pattern: String, in string: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return string
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: replacement)
    }

    private func normalizedText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
