/// Paragraph-first chunker for local retrieval indexing.
///
/// The implementation stays pure domain logic: no model, persistence, network,
/// tokenizer, or platform framework dependency is involved.
public struct ParagraphChunker: Chunker {
    public init() {}

    public func chunk(clipID: String, text: String, config: ChunkingConfig = ChunkingConfig()) -> [Chunk] {
        let characters = Array(text)
        let target = max(config.targetCharacters, 1)
        let overlap = max(0, min(config.overlapCharacters, max(target - 1, 0)))
        let paragraphs = Self.paragraphs(in: characters)
        let segments = paragraphs.flatMap { Self.hardSplit($0, characters: characters, target: target) }
        let baseChunks = Self.greedyMerge(segments, target: target)

        return baseChunks.enumerated().map { index, base in
            let overlapText = index == 0 ? "" : Self.suffix(baseChunks[index - 1].text, maxCharacters: overlap)
            let chunkText = overlapText.isEmpty ? base.text : "\(overlapText)\n\n\(base.text)"
            let overlapStart = overlapText.isEmpty
                ? base.startOffset
                : max(baseChunks[index - 1].startOffset, baseChunks[index - 1].endOffset - overlapText.count)

            return Chunk(
                id: "\(clipID)-chunk-\(index)",
                clipID: clipID,
                text: chunkText,
                indexInClip: index,
                startOffset: overlapStart,
                endOffset: base.endOffset,
                preview: Self.preview(for: chunkText)
            )
        }
    }
}

private extension ParagraphChunker {
    struct Segment {
        let text: String
        let startOffset: Int
        let endOffset: Int
        let paragraphIndex: Int
    }

    struct BaseChunk {
        let text: String
        let startOffset: Int
        let endOffset: Int
    }

    static func paragraphs(in characters: [Character]) -> [Segment] {
        var result: [Segment] = []
        var currentStart: Int?
        var currentEnd: Int?
        var lineStart = 0
        var lineEnd = 0
        var paragraphIndex = 0

        func flush() {
            guard let start = currentStart, let end = currentEnd, start < end else {
                currentStart = nil
                currentEnd = nil
                return
            }

            result.append(Segment(
                text: String(characters[start..<end]),
                startOffset: start,
                endOffset: end,
                paragraphIndex: paragraphIndex
            ))
            paragraphIndex += 1
            currentStart = nil
            currentEnd = nil
        }

        while lineStart <= characters.count {
            lineEnd = lineStart
            while lineEnd < characters.count, !isNewline(characters[lineEnd]) {
                lineEnd += 1
            }

            let lineRange = lineStart..<lineEnd
            if let contentStart = firstNonWhitespace(in: lineRange, characters: characters),
               let contentEnd = lastNonWhitespace(in: lineRange, characters: characters) {
                if currentStart == nil {
                    currentStart = contentStart
                }
                currentEnd = contentEnd + 1
            } else {
                flush()
            }

            if lineEnd >= characters.count {
                break
            }
            if characters[lineEnd] == "\r",
               lineEnd + 1 < characters.count,
               characters[lineEnd + 1] == "\n" {
                lineStart = lineEnd + 2
            } else {
                lineStart = lineEnd + 1
            }
        }

        flush()
        return result
    }

    static func hardSplit(_ segment: Segment, characters: [Character], target: Int) -> [Segment] {
        guard segment.text.count > target else {
            return [segment]
        }

        var result: [Segment] = []
        var cursor = segment.startOffset
        while cursor < segment.endOffset {
            let limit = min(cursor + target, segment.endOffset)
            let split = limit == segment.endOffset
                ? segment.endOffset
                : preferredBoundary(in: cursor..<limit, characters: characters) ?? limit
            let trimmed = trimmedRange(cursor..<split, characters: characters)
            if trimmed.lowerBound < trimmed.upperBound {
                result.append(Segment(
                    text: String(characters[trimmed]),
                    startOffset: trimmed.lowerBound,
                    endOffset: trimmed.upperBound,
                    paragraphIndex: segment.paragraphIndex
                ))
            }

            cursor = max(split, cursor + 1)
            while cursor < segment.endOffset, isWhitespace(characters[cursor]) {
                cursor += 1
            }
        }

        return result
    }

    static func greedyMerge(_ segments: [Segment], target: Int) -> [BaseChunk] {
        var result: [BaseChunk] = []
        var current: [Segment] = []

        func appendCurrent() {
            guard let first = current.first, let last = current.last else {
                return
            }
            result.append(BaseChunk(
                text: joinedText(current),
                startOffset: first.startOffset,
                endOffset: last.endOffset
            ))
            current.removeAll()
        }

        for segment in segments {
            let candidate = current + [segment]
            if !current.isEmpty, joinedText(candidate).count > target {
                appendCurrent()
            }
            current.append(segment)
        }

        appendCurrent()
        return result
    }

    static func joinedText(_ segments: [Segment]) -> String {
        var text = ""
        var previousParagraphIndex: Int?

        for segment in segments {
            if text.isEmpty {
                text = segment.text
            } else if previousParagraphIndex == segment.paragraphIndex {
                text += " \(segment.text)"
            } else {
                text += "\n\n\(segment.text)"
            }
            previousParagraphIndex = segment.paragraphIndex
        }

        return text
    }

    static func preferredBoundary(in range: Range<Int>, characters: [Character]) -> Int? {
        guard !range.isEmpty else {
            return nil
        }

        for index in stride(from: range.upperBound - 1, through: range.lowerBound, by: -1) {
            let character = characters[index]
            if isSentenceBoundary(character) || isNewline(character) {
                return index + 1
            }
        }

        for index in stride(from: range.upperBound - 1, through: range.lowerBound, by: -1) {
            if isWhitespace(characters[index]) {
                return index
            }
        }

        return nil
    }

    static func trimmedRange(_ range: Range<Int>, characters: [Character]) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, isWhitespace(characters[lower]) {
            lower += 1
        }
        while upper > lower, isWhitespace(characters[upper - 1]) {
            upper -= 1
        }
        return lower..<upper
    }

    static func firstNonWhitespace(in range: Range<Int>, characters: [Character]) -> Int? {
        for index in range where !isWhitespace(characters[index]) {
            return index
        }
        return nil
    }

    static func lastNonWhitespace(in range: Range<Int>, characters: [Character]) -> Int? {
        guard !range.isEmpty else {
            return nil
        }
        for index in stride(from: range.upperBound - 1, through: range.lowerBound, by: -1)
            where !isWhitespace(characters[index]) {
            return index
        }
        return nil
    }

    static func suffix(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0, text.count > maxCharacters else {
            return maxCharacters == 0 ? "" : text
        }
        return String(text.suffix(maxCharacters))
    }

    static func preview(for text: String) -> String {
        String(text.split(whereSeparator: { isWhitespace($0) }).joined(separator: " ").prefix(160))
    }

    static func isNewline(_ character: Character) -> Bool {
        character == "\n" || character == "\r"
    }

    static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace
        }
    }

    static func isSentenceBoundary(_ character: Character) -> Bool {
        switch character {
        case ".", "!", "?", ";", ":", "。", "！", "？", "；", "：":
            true
        default:
            false
        }
    }
}
