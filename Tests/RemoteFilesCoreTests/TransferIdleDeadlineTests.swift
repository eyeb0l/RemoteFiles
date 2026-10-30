import XCTest
@testable import RemoteFilesCore

final class TransferIdleDeadlineTests: XCTestCase {
    private func wait(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw TestFailure.waitTimedOut }
            await Task.yield()
        }
    }

    func testPositiveProgressAllowsTransferBeyondOriginalTotalBudget() async throws {
        let clock = ManualTransferClock(), transfer = ControlledTransfer(), closed = TestCounter()
        let task = Task {
            try await TransferIdleDeadline.run(idle: .seconds(60), clock: clock, close: { closed.increment() }) {
                try await transfer.run($0)
            }
        }
        try await wait { await transfer.isWaiting && clock.pendingSleeps > 0 }
        // Five real byte receipts over 250 virtual seconds exceed the old180-second total
        // budget. No wall-clock waiting and no periodic UI event can keep this timer alive.
        for _ in 0..<5 {
            clock.advance(by: .seconds(50))
            await transfer.receive(1)
            await Task.yield()
            XCTAssertEqual(closed.value, 0)
        }
        await transfer.finish(.success(5))
        let value = try await task.value
        XCTAssertEqual(value, 5)
        XCTAssertEqual(closed.value, 0)
        XCTAssertEqual(clock.pendingSleeps, 0)
    }

    func testIdleDeadlineClosesAndWaitsForOperationToDrain() async throws {
        let clock = ManualTransferClock(), transfer = ControlledTransfer(), closed = TestCounter(), returned = TestCounter()
        let task = Task {
            defer { returned.increment() }
            return try await TransferIdleDeadline.run(idle: .seconds(60), clock: clock, close: { closed.increment() }) {
                try await transfer.run($0)
            }
        }
        try await wait { await transfer.isWaiting && clock.pendingSleeps > 0 }
        clock.advance(by: .seconds(60))
        try await wait { closed.value == 1 }
        XCTAssertEqual(returned.value, 0, "The caller must retain its transfer slot while cancelled work drains")
        await transfer.finish(.failure(TestFailure.channelClosed))
        do { _ = try await task.value; XCTFail("Idle transfer must time out") }
        catch { guard case RemoteFileError.timedOut = error else { return XCTFail("Expected idle timeout, got \(error)") } }
        XCTAssertEqual(closed.value, 1)
        XCTAssertEqual(clock.pendingSleeps, 0)
    }

    func testEmptyReadsAndLateBytesCannotExtendAnExpiredDeadline() async throws {
        let clock = ManualTransferClock(), transfer = ControlledTransfer(), closed = TestCounter()
        let task = Task {
            try await TransferIdleDeadline.run(idle: .seconds(60), clock: clock, close: { closed.increment() }) {
                try await transfer.run($0)
            }
        }
        try await wait { await transfer.isWaiting && clock.pendingSleeps > 0 }
        clock.advance(by: .seconds(50))
        await transfer.receive(0)
        await transfer.receive(-1)
        clock.advance(by: .seconds(10))
        await transfer.receive(1024)
        try await wait { closed.value == 1 }
        await transfer.finish(.success(1024))
        do { _ = try await task.value; XCTFail("Empty reads and late data cannot revive the transfer") }
        catch { guard case RemoteFileError.timedOut = error else { return XCTFail("Expected idle timeout, got \(error)") } }
    }

    func testProgressMovesIdleDeadlineButSubsequentStallStillTimesOut() async throws {
        let clock = ManualTransferClock(), transfer = ControlledTransfer(), closed = TestCounter()
        let task = Task {
            try await TransferIdleDeadline.run(idle: .seconds(60), clock: clock, close: { closed.increment() }) {
                try await transfer.run($0)
            }
        }
        try await wait { await transfer.isWaiting && clock.pendingSleeps > 0 }
        clock.advance(by: .seconds(50)); await transfer.receive(1)
        clock.advance(by: .seconds(50))
        XCTAssertEqual(closed.value, 0)
        clock.advance(by: .seconds(10))
        try await wait { closed.value == 1 }
        await transfer.finish(.failure(TestFailure.channelClosed))
        do { _ = try await task.value; XCTFail("A stalled transfer must expire after its last byte") }
        catch { guard case RemoteFileError.timedOut = error else { return XCTFail("Expected idle timeout, got \(error)") } }
    }

    func testCancellationClosesImmediatelyAndDrainsBeforeReturning() async throws {
        let clock = ManualTransferClock(), transfer = ControlledTransfer(), closed = TestCounter(), returned = TestCounter()
        let task = Task {
            defer { returned.increment() }
            return try await TransferIdleDeadline.run(idle: .seconds(60), clock: clock, close: { closed.increment() }) {
                try await transfer.run($0)
            }
        }
        try await wait { await transfer.isWaiting && clock.pendingSleeps > 0 }
        task.cancel()
        try await wait { closed.value == 1 }
        XCTAssertEqual(returned.value, 0)
        await transfer.finish(.success(1))
        do { _ = try await task.value; XCTFail("Cancellation must not publish late success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(clock.pendingSleeps, 0)
    }
}

private enum TestFailure: Error { case waitTimedOut, channelClosed }

private actor ControlledTransfer {
    private var activity: TransferActivity?
    private var continuation: CheckedContinuation<Int, Error>?
    var isWaiting: Bool { continuation != nil }
    func run(_ activity: TransferActivity) async throws -> Int {
        self.activity = activity
        // Deliberately ignore task cancellation until the simulated channel drains.
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func receive(_ bytes: Int) { activity?.receivedBytes(bytes) }
    func finish(_ result: Result<Int, Error>) { continuation?.resume(with: result); continuation = nil }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

/// A monotonic clock whose sleeps are driven entirely by the test. Timer cancellation
/// removes its continuation, so structured task-group teardown cannot leak a sleeper.
private final class ManualTransferClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var sleepers: [UUID: (Instant, CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UUID> = []
    var now: Instant { lock.lock(); defer { lock.unlock() }; return instant }
    var minimumResolution: Duration { .nanoseconds(1) }
    var pendingSleeps: Int { lock.lock(); defer { lock.unlock() }; return sleepers.count }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in install(id, deadline: deadline, continuation: continuation) }
        } onCancel: { self.cancel(id) }
    }
    private func install(_ id: UUID, deadline: Instant, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled.remove(id) != nil { lock.unlock(); continuation.resume(throwing: CancellationError()) }
        else if instant >= deadline { lock.unlock(); continuation.resume() }
        else { sleepers[id] = (deadline, continuation); lock.unlock() }
    }
    private func cancel(_ id: UUID) {
        lock.lock()
        let continuation = sleepers.removeValue(forKey: id)?.1
        if continuation == nil { cancelled.insert(id) }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
    func advance(by duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        let ready = sleepers.filter { $0.value.0 <= instant }
        for id in ready.keys { sleepers.removeValue(forKey: id) }
        lock.unlock()
        for value in ready.values { value.1.resume() }
    }
}
