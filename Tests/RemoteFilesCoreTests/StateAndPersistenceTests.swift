import Foundation
import XCTest
@testable import RemoteFilesCore

@MainActor
final class StateAndPersistenceTests: XCTestCase {
    private func profile(id: UUID = UUID()) -> ConnectionProfile {
        .init(id: id, name: "Fixture Mac", host: "fixture.invalid", username: "fixture", identityID: UUID(), startingDirectory: "/Approved fixtures")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFiles-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testMetadataConnectionsFavouritesAndRecentsSurviveRelaunchWithoutSecrets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/library-v1.json")
        let store = try MetadataStore(fileURL: url)
        let connection = profile()
        var value = AppMetadata()
        value.connections = [connection]
        value.identities = [.init(id: connection.identityID, name: "Fixture public identity", publicKey: "ssh-ed25519 fixture-public-key",
                                  fingerprint: "SHA256:fixture-public-fingerprint", requiresPassphrase: true, keychainReference: "fixture-reference")]
        value.favourites = [.init(connectionID: connection.id, path: "/Approved fixtures/東京", name: "Reports", visitedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        value.recents = [.init(connectionID: connection.id, path: "/Approved fixtures/東京/Weekly review.md", name: "Weekly review.md", visitedAt: Date(timeIntervalSince1970: 1_700_000_123))]
        try await store.save(value)

        let relaunched = try MetadataStore(fileURL: url)
        let restored = await relaunched.snapshot()
        XCTAssertEqual(restored.version, 1)
        XCTAssertEqual(restored.connections, value.connections)
        XCTAssertEqual(restored.identities, value.identities)
        XCTAssertEqual(restored.favourites, value.favourites)
        XCTAssertEqual(restored.recents, value.recents)
        let identity = try await relaunched.identity(id: connection.identityID)
        XCTAssertEqual(identity.keychainReference, "fixture-reference")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "connections", "identities", "favourites", "recents"])
        let savedIdentity = try XCTUnwrap((json["identities"] as? [[String: Any]])?.first)
        XCTAssertNil(savedIdentity["privateKey"])
        XCTAssertNil(savedIdentity["passphrase"])
        XCTAssertNil(json["documents"])
    }

    func testCorruptAndFutureMetadataFailClosedWithoutOverwritingExistingBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library-v1.json")
        let corrupt = Data("{\"connections\": incomplete".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try MetadataStore(fileURL: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)

        var future = AppMetadata()
        future.version = 9
        let futureBytes = try JSONEncoder().encode(future)
        try futureBytes.write(to: url)
        XCTAssertThrowsError(try MetadataStore(fileURL: url))
        XCTAssertEqual(try Data(contentsOf: url), futureBytes)
    }

    func testRecentRemovalPersistsOnRelaunchPreservesOtherEntriesAndDoesNotRemoveFileOrFavourite() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("original.txt"); let original = Data("untouched file".utf8); try original.write(to: file)
        let url = directory.appendingPathComponent("library.json"), connection = profile()
        let first = SavedLocation(connectionID: connection.id, path: file.path, name: "original.txt")
        let samePathOtherAccount = SavedLocation(connectionID: UUID(), path: file.path, name: "other account")
        let other = SavedLocation(connectionID: connection.id, path: "/other.txt", name: "other.txt")
        var metadata = AppMetadata(); metadata.connections = [connection]; metadata.favourites = [first]; metadata.recents = [first, samePathOtherAccount, other]
        let store = try MetadataStore(fileURL: url); try await store.save(metadata)
        try await store.removeRecent(id: first.id)
        let bytes = try Data(contentsOf: url)
        try await store.removeRecent(id: first.id)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Repeated removal is a no-op")
        let restored = await (try MetadataStore(fileURL: url)).snapshot()
        XCTAssertEqual(restored.recents, [samePathOtherAccount, other]); XCTAssertEqual(restored.favourites, [first]); XCTAssertEqual(restored.connections, [connection])
        XCTAssertEqual(try Data(contentsOf: file), original)
        var stale = metadata
        stale.favourites.append(other)
        try await store.save(stale)
        let afterStaleSave = await store.snapshot()
        XCTAssertEqual(afterStaleSave.recents, [samePathOtherAccount, other], "A concurrent save captured before removal cannot restore that ID")
        XCTAssertEqual(afterStaleSave.favourites, [first, other], "Other metadata changes still persist")
        var reopened = restored; let fresh = SavedLocation(connectionID: connection.id, path: file.path, name: first.name)
        reopened.recents.insert(fresh, at: 0); try await store.save(reopened)
        try await store.removeRecent(id: first.id)
        let snapshot = await store.snapshot(); XCTAssertEqual(snapshot.recents.first, fresh, "A newly opened entry has a new identity")
    }

    func testFailedRecentRemovalPreservesSavedSnapshot() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("library"), url = parent.appendingPathComponent("state.json")
        let store = try MetadataStore(fileURL: url)
        let location = SavedLocation(connectionID: UUID(), path: "/report.md", name: "report.md")
        var metadata = AppMetadata(); metadata.recents = [location]; try await store.save(metadata)
        try FileManager.default.removeItem(at: parent)
        try Data("owned blocker".utf8).write(to: parent)
        do { try await store.removeRecent(id: location.id); XCTFail("Removal must report a failed persistence write") } catch { }
        let snapshot = await store.snapshot(); XCTAssertEqual(snapshot.recents, [location])
        XCTAssertEqual(try String(contentsOf: parent, encoding: .utf8), "owned blocker")
    }

    func testFailedMetadataWriteDoesNotPublishAnUnsavedSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("blocking file".utf8).write(to: blocked)
        let store = try MetadataStore(fileURL: blocked.appendingPathComponent("library.json"))
        var value = AppMetadata()
        value.connections = [profile()]
        do { try await store.save(value); XCTFail("Writing through a regular file must fail") } catch {}
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.connections.isEmpty)
        XCTAssertEqual(try String(contentsOf: blocked, encoding: .utf8), "blocking file")
    }

    func testDemoFolderFixturesIncludeCanonicalStartLargeEmptyHiddenUnicodeAndSymlink() async throws {
        let service = DemoRemoteFileService(delayNanoseconds: 0)
        let connection = profile()
        let root = try await service.listDirectory(profile: connection, path: ".")
        XCTAssertEqual(root.path, "/Projects")
        XCTAssertTrue(root.entries.contains(where: { $0.name == ".config" }))
        XCTAssertTrue(root.entries.contains(where: { $0.name == "Notes — 東京.txt" }))
        XCTAssertTrue(root.entries.contains(where: { $0.kind == .symlink }))
        let thousand = try await service.listDirectory(profile: connection, path: "/Projects/Thousand files")
        XCTAssertEqual(thousand.entries.count, 1_000)
        XCTAssertEqual(Set(thousand.entries.map(\.id)).count, 1_000)
        let empty = try await service.listDirectory(profile: connection, path: "/Projects/Empty")
        XCTAssertTrue(empty.entries.isEmpty)
        let link = try await service.resolveEntry(profile: connection, path: "/Projects/Latest report")
        XCTAssertEqual(link.path, "/Projects/Weekly review.md")
        XCTAssertEqual(link.kind, .file)
    }

    func testDemoReaderFixturesLimitsAndInjectedFailure() async throws {
        let service = DemoRemoteFileService(delayNanoseconds: 0)
        let connection = profile()
        let empty = try await service.readFile(profile: connection, path: "/Projects/Empty.txt", limit: 10)
        XCTAssertTrue(empty.isEmpty)
        let binary = try await service.readFile(profile: connection, path: "/Projects/Binary.txt", limit: 10)
        XCTAssertEqual(DocumentPolicy.decode(binary, filename: "Binary.txt"), .unsupportedEncodingOrBinary)
        for path in ["/Projects/Weekly review.md", "/Projects/Too large.md"] {
            do {
                _ = try await service.readFile(profile: connection, path: path, limit: 4)
                XCTFail("An over-limit fixture must fail")
            } catch RemoteFileError.tooLarge(let limit) { XCTAssertEqual(limit, 4) }
        }
        await service.configure(delayNanoseconds: 0, failure: "Permission denied: fixture")
        do {
            _ = try await service.listDirectory(profile: connection, path: "/Projects")
            XCTFail("Injected failure must reach the caller")
        } catch RemoteFileError.unavailable(let message) { XCTAssertEqual(message, "Permission denied: fixture") }
        await service.configure(delayNanoseconds: 0, failure: nil)
        let recovered = try await service.listDirectory(profile: connection, path: "/Projects/Empty")
        XCTAssertTrue(recovered.entries.isEmpty)
    }

    func testDemoCancellationStopsSlowResponse() async throws {
        let service = DemoRemoteFileService(delayNanoseconds: 5_000_000_000)
        let connection = profile()
        let request = Task { try await service.readFile(profile: connection, path: "/Projects/Weekly review.md", limit: 10_000) }
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request returned bytes") }
        catch is CancellationError {}
    }

    func testConcurrentReadsAndListsShareOnlyInFlightWork() async throws {
        let base = ControlledFileService()
        let service = CoalescingFileService(base: base)
        let connection = profile()
        let reads = (0..<8).map { _ in Task { try await service.readFile(profile: connection, path: "/report.md", limit: 100) } }
        let lists = (0..<8).map { _ in Task { try await service.listDirectory(profile: connection, path: "/reports") } }
        try await waitForStarts(base, reads: 1, lists: 1)
        for _ in 0..<24 { await Task.yield() }
        await base.release()
        for request in reads {
            let bytes = try await request.value
            XCTAssertEqual(bytes, Data("fixture".utf8))
        }
        for request in lists {
            let directory = try await request.value
            XCTAssertEqual(directory.path, "/reports")
        }
        var counts = await base.counts()
        XCTAssertEqual(counts.reads, 1)
        XCTAssertEqual(counts.lists, 1)
        // Explicit refresh is fresh work; coalescing is not a content cache.
        _ = try await service.readFile(profile: connection, path: "/report.md", limit: 100)
        counts = await base.counts()
        XCTAssertEqual(counts.reads, 2)
    }

    func testDifferentProfilesAndPreviewLimitsNeverShareReads() async throws {
        let base = ControlledFileService()
        let service = CoalescingFileService(base: base)
        let first = profile(), second = profile()
        let requests = [
            Task { try await service.readFile(profile: first, path: "/report.md", limit: 100) },
            Task { try await service.readFile(profile: second, path: "/report.md", limit: 100) },
            Task { try await service.readFile(profile: first, path: "/report.md", limit: 200) },
        ]
        try await waitForStarts(base, reads: 3)
        await base.release()
        for request in requests { _ = try await request.value }
        let counts = await base.counts()
        XCTAssertEqual(counts.reads, 3)
    }

    func testCancellingSharedReadCancelsUnderlyingWorkAndAllowsRetry() async throws {
        let base = ControlledFileService()
        let service = CoalescingFileService(base: base)
        let connection = profile()
        let first = Task { try await service.readFile(profile: connection, path: "/report.md", limit: 100) }
        let second = Task { try await service.readFile(profile: connection, path: "/report.md", limit: 100) }
        try await waitForStarts(base, reads: 1)
        for _ in 0..<24 { await Task.yield() }
        first.cancel()
        for request in [first, second] {
            do { _ = try await request.value; XCTFail("Every shared waiter must observe cancellation") }
            catch is CancellationError {}
        }
        var counts = await base.counts()
        XCTAssertEqual(counts.reads, 1)
        XCTAssertEqual(counts.cancellations, 1)
        await base.release()
        _ = try await service.readFile(profile: connection, path: "/report.md", limit: 100)
        counts = await base.counts()
        XCTAssertEqual(counts.reads, 2)
    }

    func testFailedRequestDoesNotPoisonRetry() async throws {
        let base = ControlledFileService()
        let service = CoalescingFileService(base: base)
        let connection = profile()
        await base.release(failure: true)
        do { _ = try await service.readFile(profile: connection, path: "/removed.md", limit: 100); XCTFail("Injected error must propagate") }
        catch ControlledFileService.FixtureError.unavailable {}
        await base.release(failure: false)
        _ = try await service.readFile(profile: connection, path: "/removed.md", limit: 100)
        let counts = await base.counts()
        XCTAssertEqual(counts.reads, 2)
    }

    func testRefreshStartsNewWorkBeforeCancelledRequestFinishesCleanup() async throws {
        // Model a real socket that needs time to close: the old task stays suspended after
        // cancellation. A new refresh must not join that cancelled task during cleanup.
        let base = ControlledFileService(holdCancelledRequestsUntilRelease: true)
        let service = CoalescingFileService(base: base)
        let connection = profile()
        let oldRead = Task { try await service.readFile(profile: connection, path: "/report.md", limit: 100) }
        let oldList = Task { try await service.listDirectory(profile: connection, path: "/reports") }
        try await waitForStarts(base, reads: 1, lists: 1)
        oldRead.cancel(); oldList.cancel()
        let newRead = Task { try await service.readFile(profile: connection, path: "/report.md", limit: 100) }
        let newList = Task { try await service.listDirectory(profile: connection, path: "/reports") }
        do { try await waitForStarts(base, reads: 2, lists: 2) }
        catch { await base.release(); throw error }
        await base.release()
        do { _ = try await oldRead.value; XCTFail("Old read returned bytes") } catch is CancellationError {}
        do { _ = try await oldList.value; XCTFail("Old list returned entries") } catch is CancellationError {}
        let bytes = try await newRead.value
        let directory = try await newList.value
        XCTAssertEqual(bytes, Data("fixture".utf8))
        XCTAssertEqual(directory.path, "/reports")
        let counts = await base.counts()
        XCTAssertEqual(counts.reads, 2)
        XCTAssertEqual(counts.lists, 2)
        XCTAssertEqual(counts.cancellations, 2)
    }

    func testAlreadyCancelledCallerDoesNotStartUnderlyingWork() async throws {
        let base = ControlledFileService()
        await base.release()
        let service = CoalescingFileService(base: base)
        let connection = profile()
        let read = Task { try await service.readFile(profile: connection, path: "/report.md", limit: 100) }
        let list = Task { try await service.listDirectory(profile: connection, path: "/reports") }
        read.cancel(); list.cancel()
        do { _ = try await read.value; XCTFail("Cancelled read returned bytes") } catch is CancellationError {}
        do { _ = try await list.value; XCTFail("Cancelled list returned entries") } catch is CancellationError {}
        let counts = await base.counts()
        XCTAssertEqual(counts.reads, 0)
        XCTAssertEqual(counts.lists, 0)
    }

    func testDisconnectCancelsAllPendingOperationsAndNewRequestReconnects() async throws {
        let base = ControlledFileService()
        let service = CoalescingFileService(base: base)
        let connection = profile()
        let read = Task { try await service.readFile(profile: connection, path: "/report.md", limit: 100) }
        let list = Task { try await service.listDirectory(profile: connection, path: "/reports") }
        try await waitForStarts(base, reads: 1, lists: 1)
        await service.disconnect()
        do { _ = try await read.value; XCTFail("Disconnected read returned bytes") } catch is CancellationError {}
        do { _ = try await list.value; XCTFail("Disconnected list returned entries") } catch is CancellationError {}
        await base.release()
        _ = try await service.readFile(profile: connection, path: "/report.md", limit: 100)
        let counts = await base.counts()
        XCTAssertEqual(counts.disconnects, 1)
        XCTAssertEqual(counts.cancellations, 2)
        XCTAssertEqual(counts.reads, 2)
    }

    func testDisconnectRejectsSuccessfulLateReadAndListAndAllowsFreshRequest() async throws {
        let base = ControlledFileService(ignoresCancellation: true)
        let service = CoalescingFileService(base: base)
        let connection = profile()
        let read = Task { try await service.readFile(profile: connection, path: "/report.md", limit: 100) }
        let list = Task { try await service.listDirectory(profile: connection, path: "/reports") }
        try await waitForStarts(base, reads: 1, lists: 1)
        await service.disconnect()
        do { _ = try await read.value; XCTFail("Cancelled shared work returned late bytes") } catch is CancellationError {}
        do { _ = try await list.value; XCTFail("Cancelled shared work returned late entries") } catch is CancellationError {}
        await base.release()
        let fresh = try await service.readFile(profile: connection, path: "/report.md", limit: 100)
        XCTAssertEqual(fresh, Data("fixture".utf8))
        let counts = await base.counts()
        XCTAssertEqual(counts.reads, 2); XCTAssertEqual(counts.lists, 1); XCTAssertEqual(counts.disconnects, 1)
    }

    private func waitForStarts(_ service: ControlledFileService, reads: Int, lists: Int = 0) async throws {
        for _ in 0..<1_000 {
            let counts = await service.counts()
            if counts.reads >= reads && counts.lists >= lists { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Controlled requests did not start")
        throw ControlledFileService.FixtureError.unavailable
    }
}

/// A controlled transport gate lets tests overlap requests without a real network or timing guesses.
private actor ControlledFileService: RemoteFileService {
    enum FixtureError: Error { case unavailable }
    struct Counts: Sendable { var reads = 0; var lists = 0; var cancellations = 0; var disconnects = 0 }
    private var state = Counts()
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var open = false
    private var failure = false
    private let holdCancelledRequestsUntilRelease: Bool
    private let ignoresCancellation: Bool
    init(holdCancelledRequestsUntilRelease: Bool = false, ignoresCancellation: Bool = false) {
        self.holdCancelledRequestsUntilRelease = holdCancelledRequestsUntilRelease
        self.ignoresCancellation = ignoresCancellation
    }
    func counts() -> Counts { state }
    func release(failure: Bool = false) {
        self.failure = failure; open = true
        let waiters = pending.values; pending.removeAll()
        waiters.forEach { $0.resume() }
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        state.lists += 1
        try await pause()
        return DirectorySnapshot(path: path, entries: [])
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        state.reads += 1
        try await pause()
        return Data("fixture".utf8)
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        try await pause()
        return RemoteEntry(name: "report.md", path: path, kind: .file)
    }
    func disconnect() {
        state.disconnects += 1
        let waiters = pending.values; pending.removeAll()
        waiters.forEach { if ignoresCancellation { $0.resume() } else { $0.resume(throwing: CancellationError()) } }
    }
    private func pause() async throws {
        let id = UUID()
        do {
            try Task.checkCancellation()
            if !open {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { pending[id] = $0 }
                } onCancel: { Task { await self.cancel(id) } }
            }
            if !ignoresCancellation { try Task.checkCancellation() }
            if failure { throw FixtureError.unavailable }
        } catch {
            if error is CancellationError { state.cancellations += 1 }
            throw error
        }
    }
    private func cancel(_ id: UUID) {
        guard !holdCancelledRequestsUntilRelease, !ignoresCancellation else { return }
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
