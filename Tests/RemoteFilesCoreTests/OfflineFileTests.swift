import Foundation
import XCTest
@testable import RemoteFilesCore

private actor OfflineTransport: RemoteFileService {
    var bytes: Data
    let canonicalName: String?
    var blocked: CheckedContinuation<Void, Never>?
    var hold = false
    var fail = false
    private(set) var requests: [(String, Int)] = []
    init(_ bytes: Data = Data("original\r\n東京  ".utf8), canonicalName: String? = nil) { self.bytes = bytes; self.canonicalName = canonicalName }
    func configure(bytes: Data? = nil, hold: Bool = false, fail: Bool = false) {
        if let bytes { self.bytes = bytes }; self.hold = hold; self.fail = fail
    }
    func release() { blocked?.resume(); blocked = nil }
    func waiting() -> Bool { blocked != nil }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() { release() }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        requests.append((allowedRoot, limit))
        let value = bytes, shouldFail = fail
        if hold { await withCheckedContinuation { blocked = $0 } }
        if shouldFail { throw RemoteFileError.notFound }
        // Deliberately ignore cancellation and the byte cap, as a broken adapter might.
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: destination)
        return .init(name: canonicalName ?? RemotePath.name(of: path), path: path, kind: .file, size: UInt64(value.count))
    }
}

final class OfflineFileTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/root")
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("offline-tests-" + UUID().uuidString) }
    private func entry(_ name: String = "Notes — 東京.txt", size: UInt64? = nil) -> RemoteEntry {
        .init(name: name, path: "/root/" + name, kind: .file, size: size)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Offline state did not settle")
    }
    private func save(_ store: OfflineFileStore, _ service: OfflineTransport, _ name: String = "Notes — 東京.txt") async throws -> OfflinePin {
        try await store.pin(profile: profile, entry: entry(name), allowedRoot: profile.startingDirectory, service: service)
    }

    func testOriginalBytesAndAliasPersistWithPrivateFilesAndBoundedPreview() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(" \tCafé 東京\r\nsecond line  \r\n".utf8), service = OfflineTransport(Data(" \tCafé 東京\r\nsecond line  \r\n".utf8))
        let store = try OfflineFileStore(directory: dir)
        let pin = try await save(store, service)
        XCTAssertEqual(pin.filename, "Notes — 東京.txt")
        XCTAssertTrue(pin.matches(profile, path: entry().path))
        let requests = await service.requests
        XCTAssertEqual(requests.first?.0, "/root")
        XCTAssertEqual(requests.first?.1, OfflineFileStore.maximumFileBytes)
        let lease = try await store.lease(pin.id)
        XCTAssertEqual(try Data(contentsOf: lease.url), bytes)
        XCTAssertEqual(lease.url.lastPathComponent, pin.filename)
        let preview = try await store.textPreview(lease)
        XCTAssertEqual(preview, .text(String(decoding: bytes, as: UTF8.self), markdown: false))
        for url in [dir, dir.appendingPathComponent("index-v1.json"), lease.url] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, url == dir ? 0o700 : 0o600)
        }
        XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // A fresh owner reloads metadata and bytes after the first lease has left scope.
    }

    func testSelectedAliasKeepsOriginalNameButUsesCanonicalPreviewFormat() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir)
        let service = OfflineTransport(Data("# Canonical report\n".utf8), canonicalName: "report.md")
        let alias = RemoteEntry(name: "Latest report", path: "/root/Latest report", kind: .symlink)
        let pin = try await store.pin(profile: profile, entry: alias, allowedRoot: "/root", service: service)
        let lease = try await store.lease(pin.id)
        XCTAssertEqual(lease.url.lastPathComponent, "Latest report")
        XCTAssertEqual(pin.documentFilename, "report.md")
        let preview = try await store.textPreview(lease)
        XCTAssertEqual(preview, .text("# Canonical report\n", markdown: true))
        // Older copies remain readable when this optional format field is absent.
        let index = dir.appendingPathComponent("index-v1.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var pins = try XCTUnwrap(object["pins"] as? [[String: Any]])
        pins[0].removeValue(forKey: "previewFilename"); object["pins"] = pins
        try JSONSerialization.data(withJSONObject: object).write(to: index)
        let decoded = try XCTUnwrap(JSONDecoder().decode([String: [OfflinePin]].self, from: JSONSerialization.data(withJSONObject: ["pins": pins]))["pins"]?.first)
        XCTAssertEqual(decoded.documentFilename, "Latest report")
    }

    func testRelaunchUsesSavedCopyWithoutTransportAndKeepsBinaryOriginal() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data([0, 255, 128, 1]), service = OfflineTransport(Data([0, 255, 128, 1]))
        let store = try OfflineFileStore(directory: dir)
        let pin = try await save(store, service, "Archive.zip")
        let reopened = try OfflineFileStore(directory: dir)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.first?.id, pin.id)
        let lease = try await reopened.lease(pin.id)
        XCTAssertEqual(try Data(contentsOf: lease.url), bytes)
        let preview = try await reopened.textPreview(lease)
        XCTAssertEqual(preview, .unsupportedFileType)
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1, "Opening the saved file must not call the transport")
    }

    func testRefreshIsAtomicAndExistingLeaseRetainsOldBytes() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir), service = OfflineTransport(Data("old".utf8))
        let first = try await save(store, service), old = try await store.lease(first.id)
        await service.configure(bytes: Data("new".utf8))
        let second = try await save(store, service), fresh = try await store.lease(second.id)
        XCTAssertEqual(first.id, second.id); XCTAssertNotEqual(first.blobID, second.blobID)
        XCTAssertEqual(old.pin, first, "An open reader keeps the saved date of its exact bytes")
        XCTAssertEqual(fresh.pin, second, "A new reader labels the refreshed bytes with their own metadata")
        XCTAssertEqual(try Data(contentsOf: old.url), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: fresh.url), Data("new".utf8))
        await service.configure(fail: true)
        do { _ = try await save(store, service); XCTFail("Must report failed refresh") } catch { }
        await store.cancelAndDrain()
        let kept = try await store.lease(first.id)
        XCTAssertEqual(try Data(contentsOf: kept.url), Data("new".utf8))
        let saved = await store.snapshot()
        XCTAssertEqual(saved.count, 1)
    }

    func testCancellationReturnsPromptlyButKeepsSlotUntilLateWorkerDrains() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir), service = OfflineTransport()
        await service.configure(hold: true)
        let work = Task { try await self.save(store, service) }
        try await waitUntil { await service.waiting() }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled transfer must fail") } catch is CancellationError { }
        do { _ = try await save(store, service, "other.txt"); XCTFail("Late writer must keep its slot") }
        catch OfflineFileError.busy { }
        let saved = await store.snapshot()
        XCTAssertTrue(saved.isEmpty)
        await service.release(); await store.cancelAndDrain()
        await service.configure(bytes: Data("fresh".utf8))
        let pin = try await save(store, service)
        let lease = try await store.lease(pin.id)
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("fresh".utf8))
        let completed = await store.snapshot()
        XCTAssertEqual(completed.count, 1)
    }

    func testRemovingPinDuringRefreshDoesNotResurrectItAndPreservesOpenLease() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir), service = OfflineTransport(Data("old".utf8))
        let pin = try await save(store, service), lease = try await store.lease(pin.id)
        await service.configure(bytes: Data("new".utf8), hold: true)
        let work = Task { try await self.save(store, service) }
        try await waitUntil { await service.waiting() }
        try await store.remove(pin.id)
        await service.release()
        do { _ = try await work.value; XCTFail("Removed pin must not reappear") } catch is CancellationError { }
        await store.cancelAndDrain()
        let removed = await store.snapshot()
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("old".utf8))
    }

    func testPerFileStorageAndCountLimitsIncludeActualBytes() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir, fileLimit: 8, storageLimit: 10, countLimit: 2)
        let service = OfflineTransport(Data(repeating: 1, count: 6))
        _ = try await save(store, service, "one.bin")
        do { _ = try await save(store, service, "two.bin"); XCTFail("Actual bytes exceed remaining quota") }
        catch OfflineFileError.storageFull { }
        await store.cancelAndDrain()
        await service.configure(bytes: Data(repeating: 2, count: 4))
        _ = try await save(store, service, "two.bin")
        do { _ = try await save(store, service, "three.bin"); XCTFail("Count must be bounded") }
        catch OfflineFileError.tooManyFiles { }
        await service.configure(bytes: Data(repeating: 3, count: 9))
        do { _ = try await save(store, service, "one.bin"); XCTFail("Refresh must enforce byte cap") }
        catch OfflineFileError.storageFull { }
        await store.cancelAndDrain()
        let saved = await store.snapshot()
        XCTAssertEqual(saved.reduce(0) { $0 + $1.byteCount }, 10)
    }

    func testOversizedMetadataAndDirectoriesStartNoTransfer() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir, fileLimit: 8), service = OfflineTransport()
        do { _ = try await store.pin(profile: profile, entry: entry(size: 9), allowedRoot: "/root", service: service); XCTFail() }
        catch OfflineFileError.tooLarge(8) { }
        do { _ = try await store.pin(profile: profile, entry: .init(name: "folder", path: "/root/folder", kind: .directory), allowedRoot: "/root", service: service); XCTFail() }
        catch OriginalFileExportError.notRegularFile { }
        await store.cancelAndDrain()
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testTamperedBytesAndSymlinkedBlobAreRejected() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir), service = OfflineTransport(Data("old".utf8))
        let pin = try await save(store, service)
        let original = dir.appendingPathComponent(pin.blobID.uuidString).appendingPathComponent("original")
        try Data("bad".utf8).write(to: original)
        do { _ = try await store.lease(pin.id); XCTFail("Digest must reject same-sized corruption") } catch OfflineFileError.damaged { }
        try FileManager.default.removeItem(at: original)
        let other = dir.appendingPathComponent("unrelated.txt"); try Data("old".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: other)
        do { _ = try await store.lease(pin.id); XCTFail("Never follow an on-disk symlink") } catch OfflineFileError.damaged { }
    }

    func testManifestFailurePreservesPreviousCopyAndUnrelatedFiles() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir), service = OfflineTransport(Data("old".utf8))
        let pin = try await save(store, service)
        let index = dir.appendingPathComponent("index-v1.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        await service.configure(bytes: Data("new".utf8))
        do { _ = try await save(store, service); XCTFail("Manifest commit should fail") } catch { }
        await store.cancelAndDrain()
        let lease = try await store.lease(pin.id)
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("old".utf8))
        let saved = await store.snapshot()
        XCTAssertEqual(saved.first, pin)
        XCTAssertThrowsError(try OfflineFileStore(directory: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))
    }

    func testInvalidManifestCannotRedirectLocalFilesAndPreservesExistingBytes() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir), service = OfflineTransport(Data("kept".utf8))
        let pin = try await save(store, service)
        let index = dir.appendingPathComponent("index-v1.json")
        let original = dir.appendingPathComponent(pin.blobID.uuidString).appendingPathComponent("original")
        let valid = try Data(contentsOf: index)
        for (field, value) in [("filename", "../escaped.txt" as Any), ("byteCount", -1 as Any), ("digest", "bad" as Any)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            var entries = try XCTUnwrap(object["pins"] as? [[String: Any]])
            entries[0][field] = value; object["pins"] = entries
            try JSONSerialization.data(withJSONObject: object).write(to: index)
            XCTAssertThrowsError(try OfflineFileStore(directory: dir))
            XCTAssertEqual(try Data(contentsOf: original), Data("kept".utf8))
        }
        try valid.write(to: index)
        let unrelated = dir.appendingPathComponent("keep-me.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        let orphan = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        _ = try OfflineFileStore(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
    }

    func testIndexCannotGrowBeyondItsReadableLimitDuringRefresh() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir), service = OfflineTransport(Data("old".utf8))
        let first = try await save(store, service)
        var large = profile; large.name = String(repeating: "n", count: 2 * 1_024 * 1_024)
        await service.configure(bytes: Data("new".utf8))
        do {
            _ = try await store.pin(profile: large, entry: entry(), allowedRoot: "/root", service: service)
            XCTFail("Never publish a manifest that the next launch cannot read")
        } catch OfflineFileError.metadataTooLarge { }
        await store.cancelAndDrain()
        let restored = try OfflineFileStore(directory: dir), lease = try await restored.lease(first.id)
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("old".utf8))
    }

    func testLeaseCountIsBoundedAndReleasedLeaseIsRemoved() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir), service = OfflineTransport()
        let pin = try await save(store, service)
        var leases: [OfflineFileLease] = []
        for _ in 0..<4 { leases.append(try await store.lease(pin.id)) }
        do { _ = try await store.lease(pin.id); XCTFail("Readers must be bounded") } catch OfflineFileError.tooManyReaders { }
        let released = leases.removeLast().url
        XCTAssertFalse(FileManager.default.fileExists(atPath: released.path))
        leases.append(try await store.lease(pin.id))
        try await store.remove(pin.id)
        XCTAssertTrue(leases.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testTextPreviewDoesNotReadAnUnboundedOriginal() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try OfflineFileStore(directory: dir)
        let service = OfflineTransport(Data(repeating: 65, count: DocumentPolicy.previewByteLimit + 100))
        let pin = try await save(store, service), lease = try await store.lease(pin.id)
        let preview = try await store.textPreview(lease)
        XCTAssertEqual(preview, .tooLarge)
    }

    func testRouteAssociationIncludesAccountKeyRootAndJumpHostButNotLabel() {
        let key = OfflinePin.routeKey(profile)
        var renamed = profile; renamed.name = "Renamed"; renamed.usesTailscale = true
        XCTAssertEqual(OfflinePin.routeKey(renamed), key)
        var changes: [ConnectionProfile] = []
        var host = profile; host.host = "elsewhere.invalid"; changes.append(host)
        var user = profile; user.username = "another"; changes.append(user)
        var port = profile; port.port = 2222; changes.append(port)
        var identity = profile; identity.identityID = UUID(); changes.append(identity)
        var root = profile; root.startingDirectory = "/other"; changes.append(root)
        var hop = profile; hop.jumpHost = .init(host: "jump.invalid", username: "bastion", identityID: UUID()); changes.append(hop)
        for change in changes { XCTAssertNotEqual(OfflinePin.routeKey(change), key) }
    }
}
