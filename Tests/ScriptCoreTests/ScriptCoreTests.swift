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

@Test func hookAnalysisRoundTripsThroughCodable() throws {
    let hook = HookAnalysis(
        openingHook: "A quiet cooking shot becomes a speed-run reveal.",
        retentionDevices: ["contrast", "open loop", "fast cuts"],
        payoff: "The finished plate appears in one clean cut.",
        callToAction: "Save this structure for your next demo.",
        whyItWorks: "It creates a small mystery, then pays it off with a clear visual transformation."
    )

    let data = try JSONEncoder().encode(hook)
    let decoded = try JSONDecoder().decode(HookAnalysis.self, from: data)

    #expect(decoded == hook)
}

@Test func enrichedScriptRoundTripsThroughCodable() throws {
    let hook = HookAnalysis(
        openingHook: "The first frame promises a surprising before/after.",
        retentionDevices: ["before-after contrast", "captioned open loop"],
        payoff: "The messy desk turns into a clean editing setup.",
        callToAction: nil,
        whyItWorks: "The viewer understands the transformation instantly and waits for the reveal."
    )
    let script = Script(
        id: "script-rich",
        videoSourceID: "video-rich",
        title: "Desk Reset",
        summary: "A compact creator workflow breakdown.",
        shots: [
            StoryboardShot(
                index: 0,
                startSeconds: 0,
                endSeconds: 3,
                narration: "Watch the setup change in one move.",
                visualDescription: "A cluttered desk fills the frame.",
                pacingNote: "Fast hook"
            )
        ],
        createdAt: Date(timeIntervalSince1970: 2_300),
        hookStructure: hook,
        visualElements: ["creator desk", "phone tripod", "jump cut", "clean setup"]
    )

    let data = try JSONEncoder().encode(script)
    let decoded = try JSONDecoder().decode(Script.self, from: data)

    #expect(decoded == script)
    #expect(decoded.hookStructure == hook)
    #expect(decoded.visualElements == ["creator desk", "phone tripod", "jump cut", "clean setup"])
}

@Test func legacyScriptJSONDecodesMissingHookAndVisualFields() throws {
    let legacyJSON = """
    {
      "id": "script-legacy",
      "videoSourceID": "video-legacy",
      "title": "Legacy Script",
      "summary": "Stored before v4 hook fields existed.",
      "shots": [
        {
          "index": 0,
          "startSeconds": 1.0,
          "endSeconds": 4.0,
          "narration": "Old narration",
          "visualDescription": "Old visual",
          "pacingNote": "Old pacing"
        }
      ],
      "createdAt": 2400
    }
    """

    let decoded = try JSONDecoder().decode(Script.self, from: Data(legacyJSON.utf8))

    #expect(decoded.id == "script-legacy")
    #expect(decoded.hookStructure == nil)
    #expect(decoded.visualElements == [])
    #expect(decoded.shots.count == 1)
}

@Test func scriptDefaultsPreserveExistingInitializationHashableAndSendableShape() {
    let script = Script(
        id: "script-defaults",
        videoSourceID: "video-defaults",
        title: "Defaults",
        summary: "Existing callers do not need v4 fields.",
        shots: [],
        createdAt: Date(timeIntervalSince1970: 2_500)
    )

    #expect(script.hookStructure == nil)
    #expect(script.visualElements == [])
    #expect(Set([script, script]).count == 1)
    _ = requireSendable(script)
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

private func requireSendable<Value: Sendable>(_ value: Value) -> Value {
    value
}
