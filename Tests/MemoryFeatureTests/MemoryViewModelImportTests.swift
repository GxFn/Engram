import ClipCore
import Foundation
import MemoryFeature
import Testing

@MainActor
@Test func memoryViewModelImportVideoTriggersClientAndRefreshesQueuedClip() async throws {
    let pickedURL = URL(fileURLWithPath: "/tmp/picked-video.mov")
    let copiedURL = URL(fileURLWithPath: "/tmp/videos/imported-video.mov")
    let recorder = ImportRecorder()
    let viewModel = MemoryViewModel(client: MemoryClient(
        loadItems: { await recorder.clips },
        digestPending: {},
        retryClip: { _ in },
        importVideo: { url in
            await recorder.append(url)
            await recorder.setClips([
                MemoryClip(
                    id: "imported-video",
                    title: "Imported Video",
                    sourceURL: copiedURL,
                    note: nil,
                    bodyText: nil,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_050),
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_050),
                    state: .queued,
                    failureReason: nil,
                    failureRetryable: false,
                    indexPreview: nil
                ),
            ])
        }
    ))

    await viewModel.importVideo(.file(pickedURL))

    #expect(await recorder.urls == [pickedURL])
    #expect(viewModel.items.map(\.id) == ["imported-video"])
    #expect(viewModel.items.first?.state == .queued)
    #expect(viewModel.items.first?.sourceURL == copiedURL)
    #expect(viewModel.errorMessage == nil)
}

@MainActor
@Test func memoryViewModelCancelImportDoesNotCallImporterOrRefresh() async {
    let recorder = ImportRecorder()
    let viewModel = MemoryViewModel(client: MemoryClient(
        loadItems: {
            Issue.record("Cancel path must not refresh memory items")
            return []
        },
        digestPending: {},
        retryClip: { _ in },
        importVideo: { url in
            await recorder.append(url)
        }
    ))

    await viewModel.importVideo(.cancelled)

    #expect(await recorder.urls.isEmpty)
    #expect(viewModel.items.isEmpty)
    #expect(viewModel.errorMessage == nil)
}

private actor ImportRecorder {
    private var storage: [URL] = []
    private var clipStorage: [MemoryClip] = []

    var urls: [URL] {
        storage
    }

    var clips: [MemoryClip] {
        clipStorage
    }

    func append(_ url: URL) {
        storage.append(url)
    }

    func setClips(_ clips: [MemoryClip]) {
        clipStorage = clips
    }
}
