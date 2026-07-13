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
            hasAPIKey: true
        ),
        staging: TOSStagingSettings(
            bucket: "engram-personal",
            objectPrefix: "engram/private/",
            credentialReferenceID: "tos-sts-personal",
            temporaryCredentialExpiresAt: Date().addingTimeInterval(7_200),
            hasTemporaryCredentials: true
        )
    )

    let originalArk = settings.ark
    let originalStaging = settings.staging
    settings.las.isEnabled = false

    #expect(settings.requestedMode == .lasDeep)
    #expect(settings.ark == originalArk)
    #expect(settings.staging == originalStaging)
    #expect(settings.las.operatorBaseURL.absoluteString == "https://operator.las.cn-beijing.volces.com")
    #expect(settings.las.operatorSubmitURL.path == "/api/v1/submit")
    #expect(settings.las.operatorPollURL.path == "/api/v1/poll")
    #expect(settings.las.videoStoryboardOperatorID == LASBackendSettings.videoStoryboardContractID)
    #expect(settings.las.videoFineUnderstandingOperatorID == LASBackendSettings.videoFineUnderstandingContractID)
    #expect(settings.staging.endpoint.absoluteString == "https://tos-cn-beijing.volces.com")
}

@Test func settingsModelHasNoReusableWholeVideoConsentAndReportsExactMissingLASRoles() {
    let settings = VisionBackendSettings(
        requestedMode: .lasDeep,
        las: LASBackendSettings(
            isEnabled: true,
            region: .cnBeijing,
            hasAPIKey: true
        ),
        staging: TOSStagingSettings()
    )

    #expect(settings.missingLASConfigurationRoles == [.mediaStaging])
    #expect(settings.requiresRunScopedConsent)
    #expect(Mirror(reflecting: settings).children.contains { $0.label == "allowsFullVideoUpload" } == false)
}
