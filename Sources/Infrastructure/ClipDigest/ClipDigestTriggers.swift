import ClipPipeline
import Dispatch
import EngramLogging
import Foundation

#if canImport(Darwin)
import Darwin

@_silgen_name("notify_register_dispatch")
private func engram_notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ outToken: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping @convention(block) (Int32) -> Void
) -> UInt32

@_silgen_name("notify_cancel")
private func engram_notify_cancel(_ token: Int32) -> UInt32

private let engramNotifyStatusOK: UInt32 = 0
#endif

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks

private final class BackgroundTaskCompletion: @unchecked Sendable {
    private let task: BGTask

    init(task: BGTask) {
        self.task = task
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}
#endif

public final class ClipEnqueueNotificationObserver: @unchecked Sendable {
    private let notificationName: String
    private let handler: @Sendable () -> Void
    private let lock = NSLock()
    private var token: Int32 = 0
    private var started = false

    public init(
        notificationName: String = ClipQueueWriter.notificationName,
        handler: @escaping @Sendable () -> Void
    ) {
        self.notificationName = notificationName
        self.handler = handler
    }

    deinit {
        cancel()
    }

    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        #if canImport(Darwin)
        var localToken: Int32 = 0
        let status = notificationName.withCString { name in
            engram_notify_register_dispatch(name, &localToken, DispatchQueue.main) { [handler] (_: Int32) in
                handler()
            }
        }
        if status == engramNotifyStatusOK {
            lock.lock()
            token = localToken
            lock.unlock()
        } else {
            Log.clip.error("Darwin clip notification registration failed: \(status, privacy: .public)")
        }
        #else
        Log.clip.info("Darwin clip notification observer unavailable on this platform")
        #endif
    }

    public func cancel() {
        lock.lock()
        let tokenToCancel = token
        token = 0
        started = false
        lock.unlock()

        #if canImport(Darwin)
        if tokenToCancel != 0 {
            _ = engram_notify_cancel(tokenToCancel)
        }
        #endif
    }
}

public protocol ClipDigestBackgroundScheduling: Sendable {
    @discardableResult
    func register(handler: @escaping @Sendable () async -> Bool) -> Bool

    @discardableResult
    func submit() -> Bool
}

public final class ClipDigestBackgroundScheduler: ClipDigestBackgroundScheduling, @unchecked Sendable {
    public static let identifier = "com.gxfn.engram.digest"

    private let lock = NSLock()
    private var registered = false

    public init() {}

    @discardableResult
    public func register(handler: @escaping @Sendable () async -> Bool) -> Bool {
        lock.lock()
        guard !registered else {
            lock.unlock()
            return true
        }
        registered = true
        lock.unlock()

        #if os(iOS) && canImport(BackgroundTasks)
        let success = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let completion = BackgroundTaskCompletion(task: processingTask)
            let work = Task { [completion, handler] in
                let success = await handler()
                completion.setTaskCompleted(success: success)
            }
            processingTask.expirationHandler = {
                work.cancel()
            }
        }
        if !success {
            Log.clip.error("BGProcessingTask registration rejected for \(Self.identifier, privacy: .public)")
        }
        return success
        #else
        return false
        #endif
    }

    @discardableResult
    public func submit() -> Bool {
        #if os(iOS) && canImport(BackgroundTasks)
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            Log.clip.error("BGProcessingTask submit failed: \(String(describing: error), privacy: .public)")
            return false
        }
        #else
        return false
        #endif
    }
}
