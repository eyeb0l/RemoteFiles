import Foundation

/// Managed downloads may run for longer than a preview's total time budget, while still
/// closing their dedicated SSH channel if the server stops supplying bytes.
public protocol ManagedRemoteFileDownloading: Sendable {
    func downloadManagedFile(profile: ConnectionProfile, path: String, allowedRoot: String,
                             destination: URL, limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry
    /// Saved index roots and paths must remain exact canonical names. Adapters opt in
    /// separately; supporting ordinary managed transfers does not satisfy this contract.
    func downloadManagedSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String,
                                     destination: URL, limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry
}

public extension ManagedRemoteFileDownloading {
    func downloadManagedSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String,
                                     destination: URL, limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        throw RemoteFileError.unsupportedFile
    }
}

struct TransferActivity: Sendable {
    let receivedBytes: @Sendable (Int) -> Void
    static let ignored = TransferActivity(receivedBytes: { _ in })
}

enum TransferIdleDeadline {
    /// Structured children keep the caller occupied until the channel operation drains.
    /// Only positive byte receipts reset the deadline; status/progress UI updates do not.
    static func run<C: Clock, T: Sendable>(idle: Duration, clock: C,
        close: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable (TransferActivity) async throws -> T) async throws -> T where C.Duration == Duration {
        precondition(idle > .zero)
        let state = IdleState(clock: clock, interval: idle)
        let activity = TransferActivity { state.received($0) }
        let closeAfterTimeout: @Sendable () -> Void = {
            if state.claimExpirationClose() { close() }
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let value = try await withThrowingTaskGroup(of: T?.self) { group in
                    group.addTask {
                        defer { state.finish() }
                        return try await operation(activity)
                    }
                    group.addTask {
                        while let deadline = state.nextDeadline {
                            try await clock.sleep(until: deadline, tolerance: nil)
                            try Task.checkCancellation()
                            if state.expireIfIdle() {
                                closeAfterTimeout()
                                throw RemoteFileError.timedOut
                            }
                        }
                        return nil
                    }
                    defer { group.cancelAll() }
                    while let result = try await group.next() {
                        if let value = result { return value }
                    }
                    throw CancellationError()
                }
                try Task.checkCancellation()
                if state.didExpire { closeAfterTimeout(); throw RemoteFileError.timedOut }
                return value
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if state.didExpire { closeAfterTimeout(); throw RemoteFileError.timedOut }
                throw error
            }
        } onCancel: { close() }
    }
}

private final class IdleState<C: Clock>: @unchecked Sendable where C.Duration == Duration {
    private let lock = NSLock()
    private let clock: C
    private let interval: Duration
    private var deadline: C.Instant
    private var finished = false
    private var expired = false
    private var expirationCloseClaimed = false

    init(clock: C, interval: Duration) {
        self.clock = clock; self.interval = interval
        deadline = clock.now.advanced(by: interval)
    }
    var nextDeadline: C.Instant? {
        lock.lock(); defer { lock.unlock() }
        return finished || expired ? nil : deadline
    }
    var didExpire: Bool {
        lock.lock(); defer { lock.unlock() }
        return expired
    }
    func received(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let now = clock.now
        // A late packet cannot revive a channel whose idle budget already elapsed,
        // including when the timer task has not yet been scheduled.
        guard !finished, !expired, now < deadline else { return }
        deadline = now.advanced(by: interval)
    }
    func expireIfIdle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !expired, clock.now >= deadline else { return false }
        expired = true
        return true
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        // Preserve an elapsed deadline even if the worker wins the scheduling race.
        if !finished, clock.now >= deadline { expired = true }
        finished = true
    }
    func claimExpirationClose() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard expired, !expirationCloseClaimed else { return false }
        expirationCloseClaimed = true
        return true
    }
}
