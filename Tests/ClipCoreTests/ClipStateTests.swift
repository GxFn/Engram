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

@Test func videoClipWalksThroughProcessingStates() {
    #expect(ClipState.queued.canTransition(to: .transcribing))
    #expect(ClipState.transcribing.canTransition(to: .analyzing))
    #expect(ClipState.analyzing.canTransition(to: .scripting))
    #expect(ClipState.scripting.canTransition(to: .indexed))
}

@Test func videoProcessingStatesCanFail() {
    #expect(ClipState.transcribing.canTransition(to: .failed))
    #expect(ClipState.analyzing.canTransition(to: .failed))
    #expect(ClipState.scripting.canTransition(to: .failed))
}

@Test func videoStateMachineRejectsShortcuts() {
    #expect(!ClipState.queued.canTransition(to: .analyzing))
    #expect(!ClipState.queued.canTransition(to: .scripting))
    #expect(!ClipState.transcribing.canTransition(to: .scripting))
    #expect(!ClipState.transcribing.canTransition(to: .indexed))
    #expect(!ClipState.analyzing.canTransition(to: .indexed))
    #expect(!ClipState.scripting.canTransition(to: .transcribing))
}

@Test func allowedTransitionMatrixStaysIntentional() {
    let allowed: Set<Transition> = [
        Transition(.queued, .fetching),
        Transition(.queued, .indexing),
        Transition(.queued, .transcribing),
        Transition(.fetching, .indexing),
        Transition(.fetching, .failed),
        Transition(.indexing, .indexed),
        Transition(.indexing, .failed),
        Transition(.transcribing, .analyzing),
        Transition(.transcribing, .failed),
        Transition(.analyzing, .scripting),
        Transition(.analyzing, .failed),
        Transition(.scripting, .indexed),
        Transition(.scripting, .failed),
        Transition(.failed, .queued),
    ]

    for current in ClipState.allCases {
        for next in ClipState.allCases {
            #expect(current.canTransition(to: next) == allowed.contains(Transition(current, next)))
        }
    }
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

private struct Transition: Hashable {
    let current: ClipState
    let next: ClipState

    init(_ current: ClipState, _ next: ClipState) {
        self.current = current
        self.next = next
    }
}
