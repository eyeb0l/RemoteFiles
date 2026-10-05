#if os(iOS)
import XCTest
import Foundation
import RemoteFilesCore
@testable import RemoteFilesUI

private actor BackgroundExportService: RemoteFileService {
    private var blocked: CheckedContinuation<Void, Error>?
    private(set) var destination: URL?
    private(set) var disconnects = 0
    private var bytes = Data("old server bytes".utf8)
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        .init(path: path, entries: [])
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .file)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { bytes }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String,
                      destination: URL, limit: Int) async throws -> RemoteEntry {
        self.destination = destination
        try bytes.write(to: destination)
        if disconnects == 0 {
            // Intentionally ignore task cancellation; only transport teardown retires it.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in blocked = continuation }
        }
        return .init(name: RemotePath.name(of: path), path: path, kind: .file, size: UInt64(bytes.count))
    }
    func disconnect() {
        disconnects += 1
        bytes = Data("changed server bytes\r\n東京  ".utf8)
        blocked?.resume(throwing: CancellationError()); blocked = nil
    }
    func waiting() -> Bool { blocked != nil }
}

private actor NestedDisconnectService: RemoteFileService {
    private var readWaiter: CheckedContinuation<Data, Never>?
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private(set) var disconnects = 0
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: []) }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { .init(name: "report.md", path: path, kind: .file) }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        // Simulate an uncooperative completed request racing with explicit transport teardown.
        await withCheckedContinuation { readWaiter = $0 }
    }
    func disconnect() async {
        disconnects += 1
        readWaiter?.resume(returning: Data("late bytes".utf8)); readWaiter = nil
        await withCheckedContinuation { closeWaiter = $0 }
    }
    func reading() -> Bool { readWaiter != nil }
    func closing() -> Bool { closeWaiter != nil }
    func finishClose() { closeWaiter?.resume(); closeWaiter = nil }
}

private actor DisconnectKeyInstaller: PublicKeyInstalling {
    private(set) var cancellations = 0
    func install(_ request: PublicKeyInstallationRequest, password: String) async throws -> PublicKeyInstallationResult { .installed }
    func cancelAll() { cancellations += 1 }
}

@MainActor final class AppModelLifecycleTests: XCTestCase {
    private func wait(_ predicate: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "LifecycleFixtureDeadline", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testNestedDisconnectReturnsHomeBeforeDrainAndCancelsLateReadAndKeyWorkOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = NestedDisconnectService(), keys = DisconnectKeyInstaller()
        let service = CoalescingFileService(base: base)
        let model = try AppModel(directory: directory, fileService: service, publicKeyInstaller: keys)
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "fixture", identityID: UUID())
        let entry = RemoteEntry(name: "report.md", path: "/nested/report.md", kind: .file)
        model.metadata.connections = [profile]
        let recent = SavedLocation(connectionID: profile.id, path: entry.path, name: entry.name); model.metadata.recents = [recent]
        model.routes = [.folder(profile.id, "/"), .folder(profile.id, "/nested"), .file(profile.id, entry)]
        model.sheet = .keys; model.errorMessage = "old failure"; model.cache(Data("stale".utf8), id: profile.id, path: entry.path)
        let read = Task { try await service.readFile(profile: profile, path: entry.path, limit: 1024) }
        try await wait { await base.reading() }
        let revision = model.sessionRevision
        let disconnect = Task { await model.disconnectAndGoHome() }
        try await wait { await base.closing() }
        XCTAssertTrue(model.routes.isEmpty, "Home appears while teardown is still suspended")
        XCTAssertNil(model.sheet); XCTAssertNil(model.errorMessage); XCTAssertTrue(model.isDisconnecting)
        XCTAssertEqual(model.sessionRevision, revision + 1); XCTAssertNil(model.cachedDocument(profile.id, path: entry.path))
        await model.disconnectAndGoHome()
        var joinedStarted = false
        let joined = Task { joinedStarted = true; await model.disconnect() }
        try await wait { joinedStarted }
        await base.finishClose(); await disconnect.value; await joined.value
        do { _ = try await read.value; XCTFail("A completed late read must still be rejected after cancellation") } catch is CancellationError { }
        XCTAssertFalse(model.isDisconnecting); XCTAssertTrue(model.routes.isEmpty)
        XCTAssertEqual(model.metadata.recents, [recent]); XCTAssertEqual(model.metadata.connections, [profile])
        let disconnects = await base.disconnects, cancelledKeys = await keys.cancellations
        XCTAssertEqual(disconnects, 1); XCTAssertEqual(cancelledKeys, 1)
    }
    func testBackgroundPreservesNestedRoutesWhileExplicitDisconnectClearsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        let id = UUID(); model.routes = [.folder(id, "/"), .folder(id, "/nested")]
        await model.background(); XCTAssertEqual(model.routes.count, 2)
        await model.disconnectAndGoHome(); XCTAssertTrue(model.routes.isEmpty)
    }
    func testRecentSwipeModelPersistsOnlyEntryRemovalWithoutDisconnectOrCacheDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), model = try AppModel(directory: directory, fileService: service)
        let id = UUID(), recent = SavedLocation(connectionID: UUID(), path: "/report.md", name: "report.md")
        model.metadata.recents = [recent]; model.metadata.favourites = [recent]; await model.persist()
        model.cache(Data("cached report".utf8), id: id, path: recent.path)
        await model.removeRecent(recent); await model.removeRecent(recent)
        XCTAssertTrue(model.metadata.recents.isEmpty); XCTAssertEqual(model.metadata.favourites, [recent])
        XCTAssertNotNil(model.cachedDocument(id, path: recent.path))
        let disconnects = await service.disconnects; XCTAssertEqual(disconnects, 0)
        let relaunched = try AppModel(directory: directory, fileService: service); await relaunched.load()
        XCTAssertTrue(relaunched.metadata.recents.isEmpty); XCTAssertEqual(relaunched.metadata.favourites, [recent])
    }
    func testProductionBackgroundCancelsAndDrainsExportClearsCacheAndNewExporterReadsChangedBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService()
        let model = try AppModel(directory: directory, fileService: service)
        let profile = ConnectionProfile(name: "Lifecycle", host: "fixture.invalid", username: "fixture",
                                        identityID: UUID(), startingDirectory: "/fixture")
        let entry = RemoteEntry(name: "original.txt", path: "/fixture/original.txt", kind: .file)
        model.cache(Data("stale preview".utf8), id: profile.id, path: entry.path)
        let oldExporter = model.originalExporter
        let pending = Task { try await oldExporter.prepare(profile: profile, entry: entry, allowedRoot: "/fixture") }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await service.waiting()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await service.waiting()
        guard waiting else { pending.cancel(); await service.disconnect(); XCTFail("Export never reached transport"); return }
        let destination = await service.destination
        let partial = try XCTUnwrap(destination)
        model.isForeground = false
        await model.background()
        do { _ = try await pending.value; XCTFail("Background export must be cancelled") }
        catch is CancellationError { }
        XCTAssertNil(model.cachedDocument(profile.id, path: entry.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "Partial export must be removed")
        let disconnects = await service.disconnects
        XCTAssertEqual(disconnects, 1)
        model.isForeground = true; model.sessionRevision += 1
        let newExporter = model.originalExporter
        XCTAssertFalse(oldExporter === newExporter, "Reconnect must use an exporter after the old transfer drained")
        let fresh = try await newExporter.prepare(profile: profile, entry: entry, allowedRoot: "/fixture")
        XCTAssertEqual(try Data(contentsOf: fresh.url), Data("changed server bytes\r\n東京  ".utf8))
        await newExporter.release(fresh.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.url.path))
    }
}
#endif
