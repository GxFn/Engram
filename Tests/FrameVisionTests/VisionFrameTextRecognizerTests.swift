import Foundation
import Testing
import VideoUnderstanding
@testable import FrameVision

@Test func ocrDedupDropsConsecutiveDuplicateCaptionsButKeepsReappearances() {
    let texts = [
        FrameText(timestampSeconds: 0, lines: ["什么叫四个掮客"]),
        FrameText(timestampSeconds: 1.5, lines: ["什么叫四个掮客"]),   // caption held across frames → dropped
        FrameText(timestampSeconds: 3, lines: ["我已经找好四个掮客了"]),
        FrameText(timestampSeconds: 4.5, lines: ["什么叫四个掮客"]),   // genuinely reappears → kept
    ]

    let deduped = VisionFrameTextRecognizer.deduped(texts)

    #expect(deduped.map(\.timestampSeconds) == [0, 3, 4.5])
}

@Test func ocrNormalizedKeyIgnoresSpacingAndCase() {
    #expect(
        VisionFrameTextRecognizer.normalizedKey(["Hello World"])
            == VisionFrameTextRecognizer.normalizedKey(["helloworld"])
    )
    #expect(
        VisionFrameTextRecognizer.normalizedKey(["字幕 A"]) != VisionFrameTextRecognizer.normalizedKey(["字幕 B"])
    )
}
