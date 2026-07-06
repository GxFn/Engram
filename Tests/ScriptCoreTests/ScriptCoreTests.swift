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
        "## 分镜 1 (0s–4s)\n台词: Start with the sauce.\n画面: Close-up of sauce simmering.\n节奏: Warm intro",
        "## 分镜 2 (5s–8.3s)\n台词: Then plate the noodles.\n画面: A bowl slides into frame.\n节奏: Quick payoff"
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

    #expect(!text.contains("台词: \n"))
    #expect(!text.contains("台词:  "))
    #expect(!text.contains("节奏: \n"))
    #expect(text.contains("画面: A quiet cutaway to the street outside."))
    #expect(text.contains("画面: The presenter returns to camera."))
}
