#if os(iOS)
import XCTest
import RemoteFilesCore
@testable import RemoteFilesUI

@MainActor private final class ReaderPublicationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { self.continuation = $0 }
    }
    func waitUntilSuspended() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while continuation == nil {
            guard ContinuousClock.now < deadline else { throw GateTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
    private struct GateTimeout: Error {}
}

@MainActor final class ReaderCancellationTests: XCTestCase {
    private enum Stage { case resources, decoded }
    private func verifyRejectedPublication(stage: Stage, cancel: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory)
        await model.setDemo(true)
        let profile = model.metadata.connections[0]
        let entry = RemoteEntry(name: "report.md", path: "/Projects/report.md", kind: .file)
        let gate = ReaderPublicationGate()
        defer { gate.resume() }
        var current = true
        var operations: [String] = []
        let task = Task {
            try await ReaderReloadPublication.perform(
                clearImages: true,
                isCurrent: { current },
                clearResources: {
                    operations.append("resources")
                    if stage == .resources { await gate.suspend() }
                },
                clearDecoded: {
                    operations.append("decoded")
                    if stage == .decoded { await gate.suspend() }
                },
                publish: {
                    operations.append("publish")
                    model.cache(Data("New report".utf8), id: profile.id, path: entry.path)
                    model.connectionStates[profile.id] = "Connected"
                    await model.recordRecent(profile: profile, entry: entry)
                })
        }
        try await gate.waitUntilSuspended()
        XCTAssertNil(model.cachedDocument(profile.id, path: entry.path))
        XCTAssertTrue(model.metadata.recents.isEmpty)
        if cancel { task.cancel() } else { current = false }
        gate.resume()
        if cancel {
            do { _ = try await task.value; XCTFail("Cancelled publication must throw CancellationError") }
            catch is CancellationError { }
        } else {
            let published = try await task.value
            XCTAssertFalse(published, "A superseded request must not publish")
        }
        XCTAssertEqual(operations, stage == .resources ? ["resources"] : ["resources", "decoded"])
        XCTAssertNil(model.cachedDocument(profile.id, path: entry.path), "Cancelled or superseded content must not enter the cache")
        XCTAssertTrue(model.metadata.recents.isEmpty, "Cancelled or superseded reads must not enter Recents")
        XCTAssertNil(model.connectionStates[profile.id])
        print("READER REGRESSION stage=\(stage), cancel=\(cancel), operations=\(operations), cached=\(model.cachedDocument(profile.id, path: entry.path) != nil), recents=\(model.metadata.recents.count)")
        await model.disconnect()
    }
    func testCancellationDuringResourceClearDoesNotPublish() async throws {
        try await verifyRejectedPublication(stage: .resources, cancel: true)
    }
    func testCancellationDuringDecodedClearDoesNotPublish() async throws {
        try await verifyRejectedPublication(stage: .decoded, cancel: true)
    }
    func testSupersessionDuringResourceClearDoesNotPublish() async throws {
        try await verifyRejectedPublication(stage: .resources, cancel: false)
    }
    func testSupersessionDuringDecodedClearDoesNotPublish() async throws {
        try await verifyRejectedPublication(stage: .decoded, cancel: false)
    }
    func testValidRefreshClearsThenPublishesCacheAndRecent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory)
        await model.setDemo(true)
        let profile = model.metadata.connections[0]
        let entry = RemoteEntry(name: "report.md", path: "/Projects/report.md", kind: .file)
        var operations: [String] = []
        let published = try await ReaderReloadPublication.perform(
            clearImages: true, isCurrent: { true },
            clearResources: { operations.append("resources") },
            clearDecoded: { operations.append("decoded") },
            publish: {
                operations.append("publish")
                model.cache(Data("New report".utf8), id: profile.id, path: entry.path)
                await model.recordRecent(profile: profile, entry: entry)
            })
        XCTAssertTrue(published)
        XCTAssertEqual(operations, ["resources", "decoded", "publish"])
        XCTAssertEqual(model.cachedDocument(profile.id, path: entry.path), Data("New report".utf8))
        XCTAssertEqual(model.metadata.recents.first?.path, entry.path)
        await model.disconnect()
    }
    func testNonRefreshPublishesWithoutClearingImages() async throws {
        var operations: [String] = []
        let published = try await ReaderReloadPublication.perform(
            clearImages: false, isCurrent: { true },
            clearResources: { operations.append("resources") },
            clearDecoded: { operations.append("decoded") },
            publish: { operations.append("publish") })
        XCTAssertTrue(published)
        XCTAssertEqual(operations, ["publish"])
    }
    func testAlreadyCancelledRequestDoesNoWork() async throws {
        var operations: [String] = []
        let task = Task {
            try await ReaderReloadPublication.perform(
                clearImages: true, isCurrent: { true },
                clearResources: { operations.append("resources") },
                clearDecoded: { operations.append("decoded") },
                publish: { operations.append("publish") })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Already-cancelled work must throw CancellationError") }
        catch is CancellationError { }
        XCTAssertTrue(operations.isEmpty)
    }
}
#endif
