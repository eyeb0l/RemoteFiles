import XCTest
@testable import RemoteFilesCore

@MainActor
final class DownloadManagerTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/safe")
    private func entry(_ name: String = "archive.zip", size: UInt64? = nil) -> RemoteEntry {
        .init(name: name, path: "/safe/" + name, kind: .file, size: size)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("downloads-tests-" + UUID().uuidString) }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for downloads")
    }
    func testIndexedDownloadsUseSnapshotContractInsteadOfOrdinaryFallback() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = IndexedDownloadFixture()
        let manager = try DownloadManager(service: service, directory: directory)
        let selected = RemoteEntry(name: "report.bin", path: "/safe/index/report.bin", kind: .file, canonicalRoot: "/safe/index")
        let id = try manager.enqueue(profile: profile, entry: selected)
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: manager.completedURL(id)), Data("snapshot".utf8))
        let ordinary = await service.ordinaryRequests, roots = await service.snapshotRoots
        XCTAssertEqual(ordinary, 0, "Indexed entries must never use an ordinary redirect-following download")
        XCTAssertEqual(roots, ["/safe/index"])
    }

    func testIndexedDownloadsRejectUnsupportedSnapshotAdapterWithoutOrdinaryFallback() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = IndexedDownloadFixture(supportsSnapshots: false)
        let manager = try DownloadManager(service: service, directory: directory)
        let id = try manager.enqueue(profile: profile, entry: .init(name: "report.bin", path: "/safe/index/report.bin", kind: .file, canonicalRoot: "/safe/index"))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertThrowsError(try manager.completedURL(id))
        let ordinary = await service.ordinaryRequests
        XCTAssertEqual(ordinary, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).path))
    }

    func testIndexedDownloadRootSurvivesQueuedRelaunchFailureAndRetry() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let selected = RemoteEntry(name: "report.bin", path: "/safe/index/report.bin", kind: .file, canonicalRoot: "/safe/index")
        let manager = try DownloadManager(directory: directory)
        manager.setForeground(false)
        let id = try manager.enqueue(profile: profile, entry: selected, service: IndexedDownloadFixture())
        XCTAssertEqual(manager.items.first?.canonicalRoot, selected.canonicalRoot)
        let restored = try DownloadManager(directory: directory)
        XCTAssertEqual(restored.items.first?.state, .interrupted)
        XCTAssertEqual(restored.items.first?.canonicalRoot, selected.canonicalRoot)
        let unsupported = IndexedDownloadFixture(supportsSnapshots: false)
        try restored.retry(id, profile: profile, service: unsupported)
        try await wait { restored.activeID == nil }
        XCTAssertEqual(restored.items.first?.state, .failed)
        XCTAssertEqual(restored.items.first?.canonicalRoot, selected.canonicalRoot)
        let supported = IndexedDownloadFixture()
        try restored.retry(id, profile: profile, service: supported)
        try await wait { restored.activeID == nil }
        XCTAssertEqual(try Data(contentsOf: restored.completedURL(id)), Data("snapshot".utf8))
        let roots = await supported.snapshotRoots, ordinary = await supported.ordinaryRequests
        XCTAssertEqual(roots, ["/safe/index"]); XCTAssertEqual(ordinary, 0)
        let reopened = try DownloadManager(directory: directory)
        XCTAssertEqual(reopened.items.first?.canonicalRoot, selected.canonicalRoot)
        XCTAssertEqual(reopened.items.first?.state, .completed)
    }

    func testOlderDownloadManifestWithoutCanonicalRootRetainsOrdinaryBehavior() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1]))
        let manager = try DownloadManager(service: service, directory: directory)
        manager.setForeground(false)
        let id = try manager.enqueue(profile: profile, entry: entry())
        let manifest = directory.appendingPathComponent("downloads.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]])
        records[0].removeValue(forKey: "canonicalRoot")
        try JSONSerialization.data(withJSONObject: records).write(to: manifest)
        let restored = try DownloadManager(service: service, directory: directory)
        XCTAssertNil(restored.items.first?.canonicalRoot)
        try restored.retry(id, profile: profile)
        try await wait { restored.activeID == nil }
        XCTAssertEqual(try Data(contentsOf: restored.completedURL(id)), Data([1]))
    }

    func testManagedAdapterWithoutCanonicalOptInFailsClosed() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let base = IndexedDownloadFixture()
        let manager = try DownloadManager(service: OrdinaryManagedDownloadFixture(base: base), directory: directory)
        let id = try manager.enqueue(profile: profile, entry: .init(name: "report.bin", path: "/safe/index/report.bin", kind: .file, canonicalRoot: "/safe/index"))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertThrowsError(try manager.completedURL(id))
        let ordinary = await base.ordinaryRequests, roots = await base.snapshotRoots
        XCTAssertEqual(ordinary, 0)
        XCTAssertTrue(roots.isEmpty, "An unsupported managed contract must not silently select a different transport contract")
    }

    /// A user-chosen saved-index result outside the starting folder downloads, bounded by its
    /// index's own canonical root and never through an ordinary redirect-following download.
    func testIndexedDownloadsOutsideTheStartingFolderUseTheirIndexBoundary() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = IndexedDownloadFixture()
        let manager = try DownloadManager(service: service, directory: directory)
        let id = try manager.enqueue(profile: profile, entry: .init(name: "report.bin", path: "/outside/report.bin", kind: .file, canonicalRoot: "/outside"))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: manager.completedURL(id)), Data("snapshot".utf8))
        let ordinary = await service.ordinaryRequests, roots = await service.snapshotRoots
        XCTAssertEqual(ordinary, 0); XCTAssertEqual(roots, ["/outside"])
    }

    /// An ordinary download outside the starting folder is bounded by the file's own folder.
    func testDownloadsOutsideTheStartingFolderUseTheFilesOwnFolder() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([7]))
        let manager = try DownloadManager(service: service, directory: directory)
        let id = try manager.enqueue(profile: profile, entry: .init(name: "notes.txt", path: "/elsewhere/project/notes.txt", kind: .file))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(try Data(contentsOf: manager.completedURL(id)), Data([7]))
        let requests = await service.requests
        XCTAssertEqual(requests.map(\.root), ["/elsewhere/project"])
    }

    func testProtectionLockRacePreservesBytesReservesQuotaAndFinalizesWithoutNetwork() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([0, 255, 13])
        let service = DownloadFixture(bytes: bytes)
        let manager = try DownloadManager(service: service, directory: directory, totalLimit: 3)
        var available = true
        manager.protectedDataAvailable = { available }
        manager.protectCompletedFile = { _ in
            available = false
            throw CocoaError(.fileWriteNoPermission)
        }
        let id = try manager.enqueue(profile: profile, entry: entry("one.bin", size: 3))
        try await wait { manager.activeID == nil }
        let original = directory.appendingPathComponent(id.uuidString).appendingPathComponent("one.bin")
        XCTAssertEqual(manager.items.first?.state, .pendingFinalization)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertThrowsError(try manager.completedURL(id), "Unprotected output must not be exportable")
        try manager.retry(id, profile: profile)
        let second = try manager.enqueue(profile: profile, entry: entry("two.bin", size: 1))
        XCTAssertEqual(manager.items.first(where: { $0.id == second })?.state, .failed, "Pending bytes must reserve quota")
        await manager.interrupt(reason: "Disconnected")
        XCTAssertEqual(manager.items.first?.state, .pendingFinalization, "Disconnect must preserve fully received bytes")
        available = true
        manager.protectCompletedFile = { _ in }
        manager.finalizePendingDownloads()
        XCTAssertEqual(manager.items.first?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: manager.completedURL(id)), bytes)
        let requests = await service.requests.count
        XCTAssertEqual(requests, 1, "Finalization must not download again")
    }

    func testPersistedPendingFinalizationSurvivesReopenAndFinishesOnForeground() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1, 2]))
        let manager = try DownloadManager(service: service, directory: directory)
        manager.protectedDataAvailable = { false }
        let id = try manager.enqueue(profile: profile, entry: entry())
        try await wait { manager.activeID == nil }
        let reopened = try DownloadManager(service: service, directory: directory)
        XCTAssertEqual(reopened.items.first?.state, .pendingFinalization)
        XCTAssertThrowsError(try reopened.completedURL(id))
        var protectionCalls = 0
        reopened.protectCompletedFile = { _ in protectionCalls += 1 }
        reopened.setForeground(true)
        XCTAssertEqual(protectionCalls, 1)
        XCTAssertEqual(try Data(contentsOf: reopened.completedURL(id)), Data([1, 2]))
        let persisted = try DownloadManager(service: service, directory: directory)
        XCTAssertEqual(persisted.items.first?.state, .completed)
        let requests = await service.requests.count
        XCTAssertEqual(requests, 1)
    }

    func testProtectionFailureWithAvailableDataFailsClosedAndCleansBytes() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1]))
        let manager = try DownloadManager(service: service, directory: directory)
        manager.protectedDataAvailable = { true }
        manager.protectCompletedFile = { _ in throw CocoaError(.fileWriteNoPermission) }
        let id = try manager.enqueue(profile: profile, entry: entry())
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertThrowsError(try manager.completedURL(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).path))
    }

    func testChangedPendingFileCannotFinalize() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try DownloadManager(service: DownloadFixture(bytes: Data([1])), directory: directory)
        manager.protectedDataAvailable = { false }
        let id = try manager.enqueue(profile: profile, entry: entry())
        try await wait { manager.activeID == nil }
        let original = directory.appendingPathComponent(id.uuidString).appendingPathComponent("archive.zip")
        try Data([2, 3]).write(to: original)
        manager.protectedDataAvailable = { true }
        manager.finalizePendingDownloads()
        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertThrowsError(try manager.completedURL(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testJobsUseInitiatingTransportAndFailureHandler() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = DownloadFixture(bytes: Data([1]), fails: true)
        let second = DownloadFixture(bytes: Data([2]))
        let manager = try DownloadManager(directory: directory)
        var failures: [String] = []
        let id = try manager.enqueue(profile: profile, entry: entry(), service: first,
                                     onFailure: { _, _ in failures.append("first") })
        try await wait { manager.activeID == nil }
        XCTAssertEqual(failures, ["first"])
        try manager.retry(id, profile: profile, service: second,
                          onFailure: { _, _ in failures.append("second") })
        try await wait { manager.activeID == nil }
        XCTAssertEqual(try Data(contentsOf: manager.completedURL(id)), Data([2]))
        let firstRequests = await first.requests.count, secondRequests = await second.requests.count
        XCTAssertEqual(firstRequests, 1); XCTAssertEqual(secondRequests, 1)
        XCTAssertEqual(failures, ["first"])
    }
    func testOneBackgroundSceneDoesNotPauseAnotherForegroundScene() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1]), holdFirst: true)
        let manager = try DownloadManager(service: service, directory: directory)
        let first = UUID(), second = UUID()
        manager.setForeground(true, sceneID: first); manager.setForeground(true, sceneID: second)
        _ = try manager.enqueue(profile: profile, entry: entry("one.bin"))
        _ = try manager.enqueue(profile: profile, entry: entry("two.bin"))
        try await wait { await service.requests.count == 1 }
        manager.setForeground(false, sceneID: first)
        XCTAssertTrue(manager.isForeground)
        await service.resume()
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.state), [.completed, .completed])
        manager.removeScene(second)
        XCTAssertFalse(manager.isForeground)
        manager.removeScene(first)
        XCTAssertFalse(manager.isForeground)
    }
    func testRemovalFailureRetainsRecordAndStorageBudget() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1, 2, 3]))
        let manager = try DownloadManager(service: service, directory: directory, totalLimit: 3)
        let first = try manager.enqueue(profile: profile, entry: entry("one.bin", size: 3))
        try await wait { manager.activeID == nil }
        manager.removeItem = { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try manager.remove(first))
        XCTAssertEqual(manager.items.first?.state, .completed)
        let second = try manager.enqueue(profile: profile, entry: entry("two.bin", size: 3))
        XCTAssertEqual(manager.items.first(where: { $0.id == second })?.state, .failed)
        manager.removeItem = { try FileManager.default.removeItem(at: $0) }
        try manager.remove(first)
        XCTAssertFalse(manager.items.contains { $0.id == first })
    }
    func testForegroundJobClosesSessionWithoutClearingIdentityCache() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1]))
        let manager = try DownloadManager(service: service, directory: directory)
        _ = try manager.enqueue(profile: profile, entry: entry())
        try await wait { manager.activeID == nil }
        let closes = await service.sessionCloses, disconnects = await service.disconnects
        XCTAssertEqual(closes, 1); XCTAssertEqual(disconnects, 0)
    }
    func testSFTPForegroundClosePreservesUnlockedIdentityButDisconnectClearsIt() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = DownloadSecrets()
        let identities = IdentityStore(secretStore: secrets)
        let identity = try await identities.generate(name: "Download cache fixture")
        _ = try await identities.unlock(identity)
        let initialLoads = secrets.loadCount
        let service = SFTPRemoteFileService(identityStore: identities,
            trustStore: try HostTrustStore(fileURL: directory.appendingPathComponent("trust.json")),
            metadataStore: try MetadataStore(fileURL: directory.appendingPathComponent("library.json")))
        await service.closeSessionPreservingUnlockedIdentities()
        _ = try await identities.unlock(identity)
        XCTAssertEqual(secrets.loadCount, initialLoads)
        await service.disconnect()
        _ = try await identities.unlock(identity)
        XCTAssertGreaterThan(secrets.loadCount, initialLoads)
    }
    func testIdleInterruptionDoesNotDisconnectTransport() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data())
        let manager = try DownloadManager(service: service, directory: directory)
        await manager.interrupt(reason: "Disconnected")
        let count = await service.disconnects
        XCTAssertEqual(count, 0)
    }
    func testOriginalBytesPersistAndCanBeRemoved() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([0, 255, 13, 10, 128])
        let service = DownloadFixture(bytes: bytes)
        let manager = try DownloadManager(service: service, directory: directory)
        let id = try manager.enqueue(profile: profile, entry: entry())
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .completed)
        let url = try manager.completedURL(id)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let restored = try DownloadManager(service: service, directory: directory)
        XCTAssertEqual(try Data(contentsOf: restored.completedURL(id)), bytes)
        try restored.remove(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let requests = await service.requests
        XCTAssertEqual(requests.first?.root, "/safe", "A file's own folder bounds its download")
        XCTAssertEqual(requests.first?.limit, DownloadManager.maximumFileBytes)
    }
    func testCancellationDrainsBeforeNextJobAndDiscardsLateBytes() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1, 2]), holdFirst: true)
        let manager = try DownloadManager(service: service, directory: directory)
        let first = try manager.enqueue(profile: profile, entry: entry("first.bin"))
        _ = try manager.enqueue(profile: profile, entry: entry("second.bin"))
        try await wait { await service.requests.count == 1 }
        manager.cancel(first)
        try await Task.sleep(for: .milliseconds(30))
        let count = await service.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(manager.activeID, first)
        await service.resume()
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.state), [.cancelled, .completed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first.uuidString).path))
        let maximum = await service.maximumConcurrent
        XCTAssertEqual(maximum, 1)
    }
    func testNewJobsKeepTheirContextsWhileInterruptedWorkerDrains() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1]), holdFirst: true)
        let manager = try DownloadManager(service: service, directory: directory)
        _ = try manager.enqueue(profile: profile, entry: entry("old.bin"))
        try await wait { await service.requests.count == 1 }
        let interruption = Task { await manager.interrupt(reason: "Disconnected") }
        try await wait { manager.items.first?.state == .interrupted }
        _ = try manager.enqueue(profile: profile, entry: entry("new-one.bin"))
        _ = try manager.enqueue(profile: profile, entry: entry("new-two.bin"))
        await service.resume()
        await interruption.value
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.state), [.interrupted, .completed, .completed])
        let requests = await service.requests.count
        XCTAssertEqual(requests, 3)
    }

    func testBackgroundFinishesActiveButDoesNotStartQueuedWork() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1]), holdFirst: true)
        let manager = try DownloadManager(service: service, directory: directory)
        _ = try manager.enqueue(profile: profile, entry: entry("one.bin"))
        _ = try manager.enqueue(profile: profile, entry: entry("two.bin"))
        try await wait { await service.requests.count == 1 }
        manager.setForeground(false)
        await service.resume()
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.state), [.completed, .queued])
        manager.setForeground(true)
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.state), [.completed, .completed])
    }
    func testLimitsUnsafeNamesAndUnknownSizeGrowthFailClosed() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data(repeating: 1, count: 4), ignoreLimit: true)
        let manager = try DownloadManager(service: service, directory: directory, fileLimit: 3)
        XCTAssertThrowsError(try manager.enqueue(profile: profile, entry: entry("../secret")))
        XCTAssertThrowsError(try manager.enqueue(profile: profile, entry: entry(size: 4)))
        let id = try manager.enqueue(profile: profile, entry: entry())
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertThrowsError(try manager.completedURL(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).path))
    }
    func testTotalStorageBudgetAndRetryProfileBinding() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1, 2, 3]))
        let manager = try DownloadManager(service: service, directory: directory, fileLimit: 4, totalLimit: 4)
        let first = try manager.enqueue(profile: profile, entry: entry("one.bin", size: 3))
        let second = try manager.enqueue(profile: profile, entry: entry("two.bin", size: 3))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.state), [.completed, .failed])
        var changed = profile; changed.host = "different.invalid"
        XCTAssertThrowsError(try manager.retry(second, profile: changed))
        try manager.remove(first)
        try manager.retry(second, profile: profile)
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .completed)
    }
    func testRelaunchMarksQueuedWorkInterruptedWithoutNetwork() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1]))
        let manager = try DownloadManager(service: service, directory: directory)
        manager.setForeground(false)
        _ = try manager.enqueue(profile: profile, entry: entry())
        let restored = try DownloadManager(service: service, directory: directory)
        XCTAssertEqual(restored.items.first?.state, .interrupted)
        let count = await service.requests.count
        XCTAssertEqual(count, 0)
    }
}

private actor DownloadFixture: RemoteFileService, RemoteFileSessionClosing {
    struct Request { let root: String; let limit: Int }
    let bytes: Data
    let holdFirst: Bool
    let ignoreLimit: Bool
    let fails: Bool
    var continuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [Request] = []
    private(set) var disconnects = 0
    private(set) var sessionCloses = 0
    private(set) var maximumConcurrent = 0
    private var concurrent = 0
    init(bytes: Data, holdFirst: Bool = false, ignoreLimit: Bool = false, fails: Bool = false) {
        self.bytes = bytes; self.holdFirst = holdFirst; self.ignoreLimit = ignoreLimit; self.fails = fails
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        requests.append(.init(root: allowedRoot, limit: limit)); concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        if holdFirst, requests.count == 1 { await withCheckedContinuation { continuation = $0 } }
        if fails { throw IdentityError.missingPassphrase }
        if !ignoreLimit, bytes.count > limit { throw RemoteFileError.tooLarge(limit) }
        try bytes.write(to: destination)
        return .init(name: "original.bin", path: path, kind: .file)
    }
    func resume() { continuation?.resume(); continuation = nil }
    func disconnect() { disconnects += 1 }
    func closeSessionPreservingUnlockedIdentities() { sessionCloses += 1 }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
}

private final class DownloadSecrets: IdentitySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var loads = 0
    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return loads }
    func save(_ data: Data, reference: String) throws {
        lock.lock(); defer { lock.unlock() }; storage[reference] = data
    }
    func load(reference: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }; loads += 1
        guard let data = storage[reference] else { throw IdentityError.missingSecret }
        return data
    }
    func delete(reference: String) throws {
        lock.lock(); defer { lock.unlock() }; storage.removeValue(forKey: reference)
    }
}

private actor IndexedDownloadFixture: RemoteFileService {
    let supportsSnapshots: Bool
    private(set) var ordinaryRequests = 0
    private(set) var snapshotRoots: [String] = []
    init(supportsSnapshots: Bool = true) { self.supportsSnapshots = supportsSnapshots }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        ordinaryRequests += 1
        try Data("ordinary".utf8).write(to: destination)
        return .init(name: "report.bin", path: path, kind: .file)
    }
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        snapshotRoots.append(canonicalRoot)
        guard supportsSnapshots else { throw RemoteFileError.unsupportedFile }
        try Data("snapshot".utf8).write(to: destination)
        return .init(name: "report.bin", path: path, kind: .file)
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: "safe", path: "/safe", kind: .directory)
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func disconnect() {}
}

/// Implements ordinary managed downloads and ordinary snapshots, but intentionally
/// does not opt into the managed snapshot requirement's fail-closed default.
private struct OrdinaryManagedDownloadFixture: RemoteFileService, ManagedRemoteFileDownloading {
    let base: IndexedDownloadFixture
    func downloadManagedFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL,
                             limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await base.downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit)
    }
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await base.downloadSnapshotFile(profile: profile, path: path, canonicalRoot: canonicalRoot, destination: destination, limit: limit, progress: progress)
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { try await base.resolveEntry(profile: profile, path: path) }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func disconnect() async { await base.disconnect() }
}
