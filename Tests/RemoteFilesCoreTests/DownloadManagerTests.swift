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
    /// Editing, removing or forgetting the host key of one connection stops only its downloads. Another
    /// connection's transfer keeps running, and its queued downloads start when the stopped one drains.
    func testInterruptingOneConnectionsDownloadsLeavesOthersRunning() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let other = ConnectionProfile(name: "Other", host: "other.invalid", username: "reader", identityID: UUID(), startingDirectory: "/safe")
        let service = HeldDownloadFixture(held: ["/safe/held.bin", "/safe/other-held.bin"])
        let manager = try DownloadManager(service: service, directory: directory)
        let running = try manager.enqueue(profile: other, entry: entry("other-held.bin"))
        let queued = try manager.enqueue(profile: profile, entry: entry("queued.bin"))
        let next = try manager.enqueue(profile: other, entry: entry("next.bin"))
        try await wait { await service.waiting == ["/safe/other-held.bin"] }

        // A queued download of the connection is stopped; the other connection's transfer isn't touched.
        await manager.interrupt(reason: "Changed", where: { $0.profile.id == self.profile.id })
        XCTAssertEqual(manager.items.map(\.state), [.downloading, .interrupted, .queued])
        XCTAssertEqual(manager.items[1].message, "Changed")
        XCTAssertEqual(manager.activeID, running)
        var cancellations = await service.cancellations, disconnects = await service.disconnects
        XCTAssertEqual(cancellations, 0); XCTAssertEqual(disconnects, 0)
        // Nothing the selection leaves out is stopped, nor is a finished download.
        await manager.interrupt(reason: "Nothing", where: { _ in false })
        XCTAssertEqual(manager.items.map(\.state), [.downloading, .interrupted, .queued])

        // The active transfer is cancelled and its connection closed only when it is one of them.
        try manager.retry(queued, profile: profile)
        await manager.interrupt(reason: "Removed", where: { $0.profile.id == other.id })
        XCTAssertEqual(manager.items.map(\.state)[0], .interrupted)
        XCTAssertEqual(manager.items[0].message, "Removed")
        XCTAssertEqual(manager.items[2].state, .interrupted, "A queued download of the same connection stops too")
        cancellations = await service.cancellations; disconnects = await service.disconnects
        XCTAssertEqual(cancellations, 1); XCTAssertGreaterThanOrEqual(disconnects, 1)
        // The queue isn't stopped: the remaining download of the other connection starts and finishes.
        try await wait { manager.items.first { $0.id == queued }?.state == .completed }
        XCTAssertEqual(manager.items.first { $0.id == next }?.state, .interrupted)
        XCTAssertEqual(manager.items.first { $0.id == running }?.state, .interrupted)
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

    /// A name an earlier version let into the queue, with a separator beside a joiner, must not make
    /// the whole queue unavailable now that names are judged by their bytes. New ones are refused.
    func testAQueueHoldingANameAnEarlierVersionAcceptedStillOpens() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try DownloadManager(service: DownloadFixture(bytes: Data([1])), directory: directory)
        manager.setForeground(false)
        let id = try manager.enqueue(profile: profile, entry: entry())
        let manifest = directory.appendingPathComponent("downloads.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]])
        records[0]["filename"] = "docs/\u{200D}join.txt"
        try JSONSerialization.data(withJSONObject: records).write(to: manifest)
        let restored = try DownloadManager(directory: directory)
        XCTAssertEqual(restored.items.map(\.id), [id])
        XCTAssertThrowsError(try restored.enqueue(profile: profile, entry: .init(name: "docs/\u{200D}join.txt", path: "/safe/x", kind: .file)))
        records[0]["filename"] = "../escaped.txt"
        try JSONSerialization.data(withJSONObject: records).write(to: manifest)
        XCTAssertThrowsError(try DownloadManager(directory: directory), "What was always refused still is")
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

    func testInterruptedDownloadKeepsItsBytesAcrossRelaunchAndRetryContinuesFromThem() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let content = Data((0..<10).map { UInt8($0 + 40) })
        let service = ResumableDownloadFixture(content: content)
        await service.failNext(after: 4)
        let manager = try DownloadManager(service: service, directory: directory)
        let id = try manager.enqueue(profile: profile, entry: entry(size: 10))
        try await wait { manager.activeID == nil }
        let version = await service.version
        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertEqual(manager.items.first?.keepsPartialBytes, true, "A dead network keeps the received bytes")
        XCTAssertEqual(manager.items.first?.receivedBytes, 4)
        XCTAssertEqual(manager.items.first?.partialVersion, version)

        let restored = try DownloadManager(service: service, directory: directory)
        XCTAssertEqual(restored.items.first?.keepsPartialBytes, true, "Kept bytes survive relaunch")
        XCTAssertEqual(restored.items.first?.receivedBytes, 4)
        try restored.retry(id, profile: profile)
        try await wait { restored.activeID == nil }
        XCTAssertEqual(restored.items.first?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: restored.completedURL(id)), content)
        XCTAssertNil(restored.items.first?.partialVersion)
        let starts = await service.starts, resumes = await service.resumeVersions
        XCTAssertEqual(starts, [0, 4], "Retry continues from the kept bytes")
        XCTAssertEqual(resumes, [nil, version])
    }
    func testRetryStartsAgainWhenTheRemoteFileChanged() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ResumableDownloadFixture(content: Data(repeating: 1, count: 10))
        await service.failNext(after: 4)
        let manager = try DownloadManager(service: service, directory: directory)
        let id = try manager.enqueue(profile: profile, entry: entry())
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.keepsPartialBytes, true)
        let changed = Data(repeating: 2, count: 12)
        await service.replace(content: changed, modifiedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try manager.retry(id, profile: profile)
        try await wait { manager.activeID == nil }
        XCTAssertEqual(try Data(contentsOf: manager.completedURL(id)), changed)
        let starts = await service.starts
        XCTAssertEqual(starts, [0, 0], "A changed file is downloaded from the beginning")
    }
    func testCancellationAndRefusalsDiscardKeptBytesButInterruptionKeepsThem() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ResumableDownloadFixture(content: Data(repeating: 3, count: 10))
        await service.failNext(after: 4, with: RemoteFileError.permissionDenied)
        let manager = try DownloadManager(service: service, directory: directory)
        let refused = try manager.enqueue(profile: profile, entry: entry("refused.bin"))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertEqual(manager.items.first?.keepsPartialBytes, false, "Retrying a refusal would only repeat it")
        XCTAssertNil(manager.items.first?.partialVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(refused.uuidString).path))

        await service.failNext(after: 4)
        let kept = try manager.enqueue(profile: profile, entry: entry("kept.bin"))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.last?.keepsPartialBytes, true)
        manager.setForeground(false)
        try manager.retry(kept, profile: profile)
        XCTAssertEqual(manager.items.last?.state, .queued)
        await manager.interrupt(reason: "Disconnected")
        XCTAssertEqual(manager.items.last?.state, .interrupted)
        XCTAssertEqual(manager.items.last?.keepsPartialBytes, true, "An interrupted retry keeps its bytes")
        XCTAssertEqual(manager.items.last?.receivedBytes, 4)

        try manager.retry(kept, profile: profile)
        manager.cancel(kept)
        XCTAssertEqual(manager.items.last?.state, .cancelled)
        XCTAssertNil(manager.items.last?.partialVersion)
        XCTAssertEqual(manager.items.last?.receivedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(kept.uuidString).path),
                       "Cancelling gives up the kept bytes")
    }
    func testKeptBytesCountTowardStorageAndGiveWayToANewDownload() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ResumableDownloadFixture(content: Data(repeating: 4, count: 10))
        await service.failNext(after: 6)
        let manager = try DownloadManager(service: service, directory: directory, fileLimit: 10, totalLimit: 12)
        let partial = try manager.enqueue(profile: profile, entry: entry("partial.bin", size: 10))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.receivedBytes, 6)
        let fresh = try manager.enqueue(profile: profile, entry: entry("fresh.bin", size: 10))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.last?.state, .completed, "Kept bytes must not block a new download")
        XCTAssertEqual(try Data(contentsOf: manager.completedURL(fresh)).count, 10)
        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertNil(manager.items.first?.partialVersion)
        XCTAssertEqual(manager.items.first?.receivedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(partial.uuidString).path))
        try manager.retry(partial, profile: profile)
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .failed, "Without room, Retry still reports the storage limit")
        XCTAssertEqual(manager.items.first?.message, DownloadManagerError.storageFull.localizedDescription)
    }
    func testExpandedQuotasAdmitMultiGigabyteFiles() async throws {
        XCTAssertEqual(DownloadManager.maximumFileBytes, 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(DownloadManager.maximumStoredBytes, 16 * 1024 * 1024 * 1024)
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data([1, 2, 3]))
        let manager = try DownloadManager(service: service, directory: directory)
        manager.availableDeviceBytes = { _ in Int64(64) * 1024 * 1024 * 1024 }
        let large = UInt64(3) * 1024 * 1024 * 1024
        XCTAssertThrowsError(try manager.enqueue(profile: profile, entry: entry("huge.bin", size: UInt64(DownloadManager.maximumFileBytes) + 1)))
        _ = try manager.enqueue(profile: profile, entry: entry("video.mov", size: large))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.state), [.completed])
        let limits = await service.requests.map(\.limit)
        XCTAssertEqual(limits, [DownloadManager.maximumFileBytes], "The transport may receive the whole per-file limit")
    }
    func testDownloadsLeaveReservedDeviceStorageFree() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data(repeating: 7, count: 10))
        let manager = try DownloadManager(service: service, directory: directory)
        var free = Int64(DownloadManager.reservedDeviceBytes + 5)
        manager.availableDeviceBytes = { _ in free }
        let id = try manager.enqueue(profile: profile, entry: entry("big.bin", size: 10))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertEqual(manager.items.first?.message, DownloadManagerError.deviceStorageFull.localizedDescription)
        let refused = await service.requests.count
        XCTAssertEqual(refused, 0, "A known-size file that cannot fit never opens a transfer")
        free = Int64(DownloadManager.reservedDeviceBytes + 10)
        try manager.retry(id, profile: profile)
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .completed)
        let limits = await service.requests.map(\.limit)
        XCTAssertEqual(limits, [10])
    }
    func testUnknownSizeGrowthPastFreeDeviceStorageReportsDeviceStorage() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadFixture(bytes: Data(repeating: 7, count: 8), ignoreLimit: true)
        let manager = try DownloadManager(service: service, directory: directory)
        manager.availableDeviceBytes = { _ in Int64(DownloadManager.reservedDeviceBytes + 4) }
        let id = try manager.enqueue(profile: profile, entry: entry())
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .failed)
        XCTAssertEqual(manager.items.first?.message, DownloadManagerError.deviceStorageFull.localizedDescription)
        let limits = await service.requests.map(\.limit)
        XCTAssertEqual(limits, [4])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).path))
    }
    func testKeptBytesNeedNoNewDeviceStorageWhenRetried() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = ResumableDownloadFixture(content: Data(repeating: 4, count: 10))
        await service.failNext(after: 6)
        let manager = try DownloadManager(service: service, directory: directory)
        var free = Int64(DownloadManager.reservedDeviceBytes + 10)
        manager.availableDeviceBytes = { _ in free }
        let id = try manager.enqueue(profile: profile, entry: entry("partial.bin", size: 10))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.receivedBytes, 6)
        free = Int64(DownloadManager.reservedDeviceBytes + 4)
        try manager.retry(id, profile: profile)
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .completed, "Six kept bytes plus four free bytes hold the whole file")
        let starts = await service.starts
        XCTAssertEqual(starts, [0, 6])
    }
}

/// Downloads named in `held` wait until their task is cancelled, as a transfer drains when its worker is.
private actor HeldDownloadFixture: RemoteFileService {
    let held: Set<String>
    private(set) var waiting: [String] = []
    private(set) var cancellations = 0
    private(set) var disconnects = 0
    init(held: Set<String>) { self.held = held }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        if held.contains(path) {
            waiting.append(path)
            defer { waiting.removeAll { $0 == path } }
            do { while true { try await Task.sleep(for: .seconds(60)) } }
            catch { cancellations += 1; throw CancellationError() }
        }
        try Data("bytes".utf8).write(to: destination)
        return .init(name: RemotePath.name(of: path), path: path, kind: .file)
    }
    func disconnect() { disconnects += 1 }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
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

/// Continues a destination only when it holds a prefix of the same version, as the SFTP transport does.
private actor ResumableDownloadFixture: RemoteFileService, ResumableManagedDownloading, RemoteFileSessionClosing {
    private var content: Data
    private var modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private var failure: (bytes: Int, error: Error)?
    private(set) var starts: [UInt64] = []
    private(set) var resumeVersions: [RemoteFileVersion?] = []
    var version: RemoteFileVersion { RemoteFileVersion(size: UInt64(content.count), modifiedAt: modifiedAt)! }
    init(content: Data) { self.content = content }
    func failNext(after bytes: Int, with error: Error = RemoteFileError.timedOut) { failure = (bytes, error) }
    func replace(content: Data, modifiedAt: Date) { self.content = content; self.modifiedAt = modifiedAt }
    func downloadManagedFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int,
                             resumeVersion: RemoteFileVersion?, started: @escaping ManagedDownloadStartHandler,
                             progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        resumeVersions.append(resumeVersion)
        guard content.count <= limit else { throw RemoteFileError.tooLarge(limit) }
        var start = 0
        if resumeVersion == version, let local = try? Data(contentsOf: destination),
           local.count <= content.count, content.prefix(local.count) == local { start = local.count }
        if start == 0 { try Data().write(to: destination) }
        starts.append(UInt64(start))
        await started(version, UInt64(start))
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let end = failure.map { min(content.count, start + $0.bytes) } ?? content.count
        try handle.write(contentsOf: content.subdata(in: start..<end))
        if let failure { self.failure = nil; throw failure.error }
        return .init(name: RemotePath.name(of: path), path: path, kind: .file, size: UInt64(content.count))
    }
    func downloadManagedSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL, limit: Int,
                                     resumeVersion: RemoteFileVersion?, started: @escaping ManagedDownloadStartHandler,
                                     progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await downloadManagedFile(profile: profile, path: path, allowedRoot: canonicalRoot, destination: destination, limit: limit,
                                      resumeVersion: resumeVersion, started: started, progress: progress)
    }
    func downloadManagedFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL,
                             limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await downloadManagedFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit,
                                      resumeVersion: nil, started: { _, _ in }, progress: progress)
    }
    func closeSessionPreservingUnlockedIdentities() {}
    func disconnect() {}
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
}
