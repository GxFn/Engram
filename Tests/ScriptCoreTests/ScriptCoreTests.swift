import Foundation
import Testing
import VideoUnderstanding
@testable import ScriptCore

@Test func scriptRoundTripsThroughCodable() throws {
    let script = Script(
        id: "script-1",
        videoSourceID: "video-1",
        title: "Launch Plan",
        summary: "A concise product launch storyboard.",
        shots: [
            StoryboardShot(
                index: 0,
                startSeconds: 0,
                endSeconds: 4.5,
                narration: "Here is the setup.",
                visualDescription: "Phone on desk with the app open.",
                pacingNote: "Calm open"
            )
        ],
        createdAt: Date(timeIntervalSince1970: 1_900)
    )

    let data = try JSONEncoder().encode(script)
    let decoded = try JSONDecoder().decode(Script.self, from: data)
    #expect(decoded == script)
}

@Test func emptyShotsRenderTitleAndSummaryOnly() {
    let script = Script(
        id: "script-empty",
        videoSourceID: "video-empty",
        title: "Empty Storyboard",
        summary: "No storyboard shots are available yet.",
        shots: [],
        createdAt: Date(timeIntervalSince1970: 2_000)
    )

    #expect(ScriptRendering.indexableText(script) == "Empty Storyboard\n\nNo storyboard shots are available yet.")
}

@Test func multipleShotsRenderAsParagraphFriendlyBlocks() {
    let script = Script(
        id: "script-multi",
        videoSourceID: "video-multi",
        title: "Kitchen Demo",
        summary: "A two-shot cooking demo.",
        shots: [
            StoryboardShot(
                index: 1,
                startSeconds: 5,
                endSeconds: 8.25,
                narration: "Then plate the noodles.",
                visualDescription: "A bowl slides into frame.",
                pacingNote: "Quick payoff"
            ),
            StoryboardShot(
                index: 0,
                startSeconds: 0,
                endSeconds: 4,
                narration: "Start with the sauce.",
                visualDescription: "Close-up of sauce simmering.",
                pacingNote: "Warm intro"
            )
        ],
        createdAt: Date(timeIntervalSince1970: 2_100)
    )

    let paragraphs = ScriptRendering.indexableText(script).components(separatedBy: "\n\n")

    #expect(paragraphs == [
        "Kitchen Demo",
        "A two-shot cooking demo.",
        "Shot 1 (0s-4s)\nNarration: Start with the sauce.\nVisual: Close-up of sauce simmering.\nPacing: Warm intro",
        "Shot 2 (5s-8.3s)\nNarration: Then plate the noodles.\nVisual: A bowl slides into frame.\nPacing: Quick payoff"
    ])
}

@Test func missingNarrationDoesNotRenderAnEmptyNarrationLine() {
    let script = Script(
        id: "script-no-narration",
        videoSourceID: "video-no-narration",
        title: "Silent Cutaway",
        summary: "The visual carries the beat.",
        shots: [
            StoryboardShot(
                index: 0,
                startSeconds: 9,
                endSeconds: 12,
                narration: nil,
                visualDescription: "A quiet cutaway to the street outside.",
                pacingNote: nil
            ),
            StoryboardShot(
                index: 1,
                startSeconds: 12,
                endSeconds: 14,
                narration: "  ",
                visualDescription: "The presenter returns to camera.",
                pacingNote: " "
            )
        ],
        createdAt: Date(timeIntervalSince1970: 2_200)
    )

    let text = ScriptRendering.indexableText(script)

    #expect(!text.contains("Narration: \n"))
    #expect(!text.contains("Narration:  "))
    #expect(!text.contains("Pacing: \n"))
    #expect(text.contains("Visual: A quiet cutaway to the street outside."))
    #expect(text.contains("Visual: The presenter returns to camera."))
}
