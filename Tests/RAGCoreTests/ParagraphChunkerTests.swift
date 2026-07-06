import Testing
@testable import RAGCore

@Test func paragraphBoundariesSplitBeforeSentenceSplitting() {
    let text = """
    Alpha paragraph.

    Beta paragraph.
    """
    let chunks = ParagraphChunker().chunk(
        clipID: "clip-a",
        text: text,
        config: ChunkingConfig(targetCharacters: 18, overlapCharacters: 0)
    )

    #expect(chunks.map(\.text) == ["Alpha paragraph.", "Beta paragraph."])
    #expect(chunks.map(\.indexInClip) == [0, 1])
    #expect(chunks.map(\.id) == ["clip-a-chunk-0", "clip-a-chunk-1"])
}

@Test func overlapPrefixesTheNextChunkWithThePreviousTail() {
    let text = """
    First memory paragraph.

    Second memory paragraph.

    Third memory paragraph.
    """
    let chunks = ParagraphChunker().chunk(
        clipID: "clip-b",
        text: text,
        config: ChunkingConfig(targetCharacters: 26, overlapCharacters: 8)
    )

    #expect(chunks.count == 3)
    #expect(chunks[1].text.hasPrefix("\(String(chunks[0].text.suffix(8)))\n\n"))
    #expect(chunks[2].text.hasPrefix("\(String(chunks[1].text.suffix(8)))\n\n"))
}

@Test func longParagraphsHardSplitOnSentencePunctuation() {
    let text = "First sentence is useful. Second sentence is also useful. Third sentence closes the example."
    let chunks = ParagraphChunker().chunk(
        clipID: "clip-c",
        text: text,
        config: ChunkingConfig(targetCharacters: 34, overlapCharacters: 0)
    )

    #expect(chunks.count == 3)
    #expect(chunks.allSatisfy { $0.text.count <= 34 })
    #expect(chunks[0].text == "First sentence is useful.")
    #expect(chunks[1].text == "Second sentence is also useful.")
    #expect(chunks[2].text == "Third sentence closes the example.")
}

@Test func emptyAndWhitespaceInputProducesNoChunks() {
    let chunks = ParagraphChunker().chunk(
        clipID: "clip-empty",
        text: " \n\t\n\n  ",
        config: ChunkingConfig()
    )

    #expect(chunks.isEmpty)
}

@Test func unicodeAndChineseTextUseCharacterCounts() {
    let text = """
    第一段包含中文字符用于测试。

    第二段继续保留顺序和偏移。
    """
    let chunks = ParagraphChunker().chunk(
        clipID: "clip-cn",
        text: text,
        config: ChunkingConfig(targetCharacters: 15, overlapCharacters: 0)
    )

    #expect(chunks.count == 2)
    #expect(chunks[0].text == "第一段包含中文字符用于测试。")
    #expect(chunks[1].text == "第二段继续保留顺序和偏移。")
    #expect(chunks[0].text.count == 14)
    #expect(chunks[0].startOffset == 0)
    #expect(chunks[1].startOffset == 16)
}

@Test func chunkIDsOrderAndMetadataAreDeterministic() {
    let text = """
    Clip metadata starts here.

    Clip metadata continues here.
    """
    let chunker = ParagraphChunker()
    let firstRun = chunker.chunk(
        clipID: "clip-meta",
        text: text,
        config: ChunkingConfig(targetCharacters: 32, overlapCharacters: 5)
    )
    let secondRun = chunker.chunk(
        clipID: "clip-meta",
        text: text,
        config: ChunkingConfig(targetCharacters: 32, overlapCharacters: 5)
    )

    #expect(firstRun == secondRun)
    #expect(firstRun.map(\.id) == ["clip-meta-chunk-0", "clip-meta-chunk-1"])
    #expect(firstRun.map(\.clipID) == ["clip-meta", "clip-meta"])
    #expect(firstRun[0].startOffset == 0)
    #expect(firstRun[0].endOffset == 26)
    #expect(firstRun[0].preview == "Clip metadata starts here.")
    #expect(firstRun[1].startOffset != nil)
    #expect(firstRun[1].endOffset == text.count)
}
