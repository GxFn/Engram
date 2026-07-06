import Foundation
import Testing
@testable import VideoUnderstanding

@Test func videoUnderstandingTypesRoundTripThroughCodable() throws {
    let source = VideoSource(
        id: "video-1",
        localFileURL: URL(fileURLWithPath: "/tmp/source.mov"),
        importedAt: Date(timeIntervalSince1970: 1_800),
        durationSeconds: 42.5
    )
    try roundTrip(source)

    let segment = TranscriptSegment(startSeconds: 1.25, endSeconds: 3.5, text: "Opening line")
    try roundTrip(segment)

    let frame = SampledFrame(timestampSeconds: 2.0, jpegData: Data([0x01, 0x02, 0x03]))
    try roundTrip(frame)

    let description = FrameDescription(timestampSeconds: 2.0, description: "A presenter points at a whiteboard.")
    try roundTrip(description)
}

@Test func videoUnderstandingErrorsRoundTripThroughCodable() throws {
    let errors: [VideoUnderstandingError] = [
        .noAudioTrack,
        .transcriptionUnavailable("speech recognizer unavailable"),
        .visionUnavailable("image model unavailable"),
        .unreadableAsset("cannot open file")
    ]

    for error in errors {
        try roundTrip(error)
    }
}

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws {
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(Value.self, from: data)
    #expect(decoded == value)
}
