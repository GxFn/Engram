import Testing
@testable import ClipCore

@Test func urlClipWalksThroughFetching() {
    #expect(ClipState.queued.canTransition(to: .fetching))
    #expect(ClipState.fetching.canTransition(to: .indexing))
    #expect(ClipState.indexing.canTransition(to: .indexed))
}

@Test func textClipSkipsFetching() {
    #expect(ClipState.queued.canTransition(to: .indexing))
}

@Test func failedClipCanOnlyRetryViaQueue() {
    for state in ClipState.allCases {
        let allowed = ClipState.failed.canTransition(to: state)
        #expect(allowed == (state == .queued))
    }
}

@Test func indexedIsTerminal() {
    for state in ClipState.allCases {
        #expect(!ClipState.indexed.canTransition(to: state))
    }
}
