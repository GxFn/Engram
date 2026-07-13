import Foundation
@testable import SettingsFeature
import Testing

@Test func cloudSettingsKeepArkLASAndTemporaryStagingIndependent() {
    var settings = VisionBackendSettings(
        requestedMode: .lasDeep,
        ark: ArkBackendSettings(
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            textModelID: "ep-text",
            frameModelID: "ep-frame",
            hasAPIKey: true
        ),
        las: LASBackendSettings(
            isEnabled: true,
            region: .cnBeijing,
            videoStoryboardOperatorID: "las-video-storyboard",
            videoFineUnderstandingOperatorID: "las-video-fine-understanding",
            scriptGenerationOperatorID: "las-script-generation",
            enhancedASROperatorID: "las-doubao-enhanced-asr",
            hasAPIKey: true
        ),
        staging: TOSStagingSettings(
            bucket: "engram-personal",
            objectPrefix: "engram/private/",
            credentialReferenceID: "tos-sts-personal",
            temporaryCredentialExpiresAt: Date(timeIntervalSince1970: 7_200),
            hasTemporaryCredentials: true
        )
    )

    let originalArk = settings.ark
    let originalStaging = settings.staging
    settings.las.videoFineUnderstandingOperatorID = "las-video-fine-understanding-v2"

    #expect(settings.requestedMode == .lasDeep)
    #expect(settings.ark == originalArk)
    #expect(settings.staging == originalStaging)
    #expect(settings.las.operatorBaseURL.absoluteString == "https://operator.las.cn-beijing.volces.com")
    #expect(settings.las.operatorProcessURL.path == "/api/v1/process")
    #expect(settings.staging.endpoint.absoluteString == "https://tos-cn-beijing.volces.com")
}

@Test func settingsModelHasNoReusableWholeVideoConsentAndReportsExactMissingLASRoles() {
    let settings = VisionBackendSettings(
        requestedMode: .lasDeep,
        las: LASBackendSettings(
            isEnabled: true,
            region: .cnBeijing,
            videoStoryboardOperatorID: "storyboard",
            videoFineUnderstandingOperatorID: "",
            scriptGenerationOperatorID: "script",
            enhancedASROperatorID: "asr",
            hasAPIKey: true
        ),
        staging: TOSStagingSettings()
    )

    #expect(settings.missingLASConfigurationRoles == [.videoFineUnderstanding, .mediaStaging])
    #expect(settings.requiresRunScopedConsent)
    #expect(Mirror(reflecting: settings).children.contains { $0.label == "allowsFullVideoUpload" } == false)
}

