import Foundation

/// The product Keychain accounts are process-global. Swift Testing may execute suites in
/// parallel, so tests that rotate those accounts share this async mutex.
actor AppShellKeychainTestMutex {
    static let shared = AppShellKeychainTestMutex()

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    func withMainActorLock<T: Sendable>(
        _ operation: @MainActor @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
