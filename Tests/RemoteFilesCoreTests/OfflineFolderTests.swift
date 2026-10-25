import Foundation
import XCTest
@testable import RemoteFilesCore

private actor FolderFixture: RemoteFileService {
    var tree: [String: [RemoteEntry]] = [
        "/root": [.init(name: "Docs", path: "/root/Docs", kind: .directory)],
        "/root/Docs": [.init(name: "one.txt", path: "/root/Docs/one.txt", kind: .file),
                       .init(name: "Nested", path: "/root/Docs/Nested", kind: .directory),
                       .init(name: "Empty", path: "/root/Docs/Empty", kind: .directory),
                       .init(name: ".hidden", path: "/root/Docs/.hidden", kind: .file),
                       .init(name: "loop", path: "/root/Docs/loop", kind: .symlink,
                             link: .target(.init(name: "Docs", path: "/root/Docs", kind: .directory))),
                       .init(name: "socket", path: "/root/Docs/socket", kind: .other)],
        "/root/Docs/Nested": [.init(name: "東京.txt", path: "/root/Docs/Nested/東京.txt", kind: .file)],
        "/root/Docs/Empty": []
    ]
    var bytes = Data("old\r\n".utf8)
    var failure: String?
    var redirect: String?
    var holdFile = false
    var holdListing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var lists: [String] = []
    private(set) var downloads: [(String, String)] = []
    func configure(bytes: Data? = nil, failure: String? = nil, redirect: String? = nil, holdFile: Bool = false, holdListing: Bool = false) {
        if let bytes { self.bytes = bytes }
        self.failure = failure; self.redirect = redirect; self.holdFile = holdFile; self.holdListing = holdListing
    }
    func set(_ path: String, entries: [RemoteEntry]) { tree[path] = entries }
    func waiting() -> Bool { !waiters.isEmpty }
    func release() { let pending = waiters; waiters = []; pending.forEach { $0.resume() }; holdFile = false; holdListing = false }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        lists.append(path)
        if holdListing { await withCheckedContinuation { waiters.append($0) } }
        guard let entries = tree[path] else { throw RemoteFileError.notFound }
        return .init(path: redirect == path ? "/outside" : path, entries: entries)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        guard tree[path] != nil else { throw RemoteFileError.notFound }
        return .init(name: RemotePath.name(of: path), path: path, kind: .directory)
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        // Single-file copies remain independent of the folder that also contains this path.
        try bytes.write(to: destination)
        return .init(name: RemotePath.name(of: path), path: path, kind: .file)
    }
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        downloads.append((path, canonicalRoot))
        if holdFile { await withCheckedContinuation { waiters.append($0) } }
        if path == failure { throw RemoteFileError.permissionDenied }
        if path == redirect { throw RemoteDocumentLinkError.outsideConnection }
        try bytes.write(to: destination) // Deliberately ignore limit; the exporter must check disk bytes.
        await progress(.init(receivedBytes: UInt64(bytes.count), isComplete: true))
        return .init(name: RemotePath.name(of: path), path: path, kind: .file)
    }
    func disconnect() { release() }
}

final class OfflineFolderTests: XCTestCase {
    func testDocumentLinksStayInTheirSnapshotAndPreserveByteNames() async throws {
        let (dir, store, service) = try setup()
        let names = ["guide.md", "caf\u{e9}.txt", "cafe\u{301}.txt", "literal%20name.txt"]
        await service.set(path, entries: names.map { .init(name: $0, path: path + "/" + $0, kind: .file) } +
            [.init(name: "Nested", path: path + "/Nested", kind: .directory),
             .init(name: ".hidden.md", path: path + "/.hidden.md", kind: .file)])
        let folder = try await store.pinFolder(profile: profile, path: path, service: service)
        let pins = await store.snapshot()
        let source = try XCTUnwrap(pins.first { $0.filename == "guide.md" })
        let nested = try await store.resolveDocumentLink(from: source, reference: "Nested/%E6%9D%B1%E4%BA%AC.txt")
        let parent = try await store.resolveDocumentLink(from: nested, reference: "../guide.md")
        XCTAssertEqual(parent.id, source.id)
        for name in names.dropFirst() {
            let reference = try XCTUnwrap(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
            let target = try await store.resolveDocumentLink(from: source, reference: reference)
            XCTAssertTrue(target.path.utf8.elementsEqual((path + "/" + name).utf8))
        }
        for reference in [".hidden.md", "loop/guide.md", "missing.md"] {
            do { _ = try await store.resolveDocumentLink(from: source, reference: reference); XCTFail(reference) }
            catch OfflineDocumentLinkError.notSaved { }
        }
        // An overlapping snapshot and an individual copy cannot replace this snapshot's members.
        let overlap = try await store.pinFolder(profile: profile, path: path + "/Nested", service: service)
        let standalone = try await store.pin(profile: profile,
            entry: .init(name: "guide.md", path: source.path, kind: .file), allowedRoot: "/root", service: service)
        do { _ = try await store.resolveDocumentLink(from: standalone, reference: "Nested/東京.txt"); XCTFail("Standalone must not select a folder member") }
        catch OfflineDocumentLinkError.notSaved { }
        do { _ = try await store.resolveDocumentLink(from: source, reference: "../Docs-other/guide.md"); XCTFail("Folder boundary") }
        catch OfflineDocumentLinkError.outsideFolder { }
        let reopened = try OfflineFileStore(directory: dir)
        let restored = try await reopened.resolveDocumentLink(from: source, reference: "Nested/東京.txt")
        XCTAssertEqual(restored.id, nested.id)
        XCTAssertTrue(folder.fileIDs.contains(restored.id)); XCTAssertFalse(overlap.fileIDs.contains(restored.id))
        try await store.removeFolder(folder.id)
        do { _ = try await store.resolveDocumentLink(from: source, reference: "Nested/東京.txt"); XCTFail("Removed snapshot must not fall back") }
        catch OfflineDocumentLinkError.sourceChanged { }
    }

    func testDocumentLinksRejectOldFolderRevisionAndCancellation() async throws {
        let (_, store, service) = try setup()
        _ = try await store.pinFolder(profile: profile, path: path, service: service)
        let before = await store.snapshot(), source = try XCTUnwrap(before.first { $0.filename == "one.txt" })
        _ = try await store.pinFolder(profile: profile, path: path, service: service)
        do { _ = try await store.resolveDocumentLink(from: source, reference: "Nested/東京.txt"); XCTFail("Old revision") }
        catch OfflineDocumentLinkError.sourceChanged { }
        let currentPins = await store.snapshot(), current = try XCTUnwrap(currentPins.first { $0.id == source.id })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.resolveDocumentLink(from: current, reference: "Nested/東京.txt")
        }
        do { _ = try await task.value; XCTFail("Cancelled link must not publish") }
        catch is CancellationError { }
    }

    func testStoreCancellationAndRemovalReturnWhileListingIgnoresCancellation() async throws {
        for removing in [false, true] {
            let (_, store, service) = try setup()
            let folder = try await store.pinFolder(profile: profile, path: path, service: service)
            await service.configure(holdListing: true)
            let returned = expectation(description: "Store cancellation returns before the listing finishes")
            let saving = Task {
                defer { returned.fulfill() }
                return try await store.pinFolder(profile: self.profile, path: self.path, service: service)
            }
            try await waitFor { await service.waiting() }
            if removing { try await store.removeFolder(folder.id) }
            else { await store.cancelAll() }
            await fulfillment(of: [returned], timeout: 3)
            let saved = await store.librarySnapshot()
            XCTAssertEqual(saved.folders.map(\.id), removing ? [] : [folder.id])
            // Release even on a failed prompt-return assertion so teardown never hides it.
            await service.release()
            do { _ = try await saving.value; XCTFail("Cancelled refresh must not publish") }
            catch is CancellationError { }
            await store.cancelAndDrain()
        }
    }

    func testCancellingSnapshotDoesNotCancelCoalescedForegroundListing() async throws {
        let (_, store, service) = try setup()
        await service.configure(holdListing: true)
        let coalesced = CoalescingFileService(base: service)
        let foreground = Task { try await coalesced.listDirectory(profile: self.profile, path: self.path) }
        try await waitFor { await service.lists.count == 1 }
        let saving = Task { try await store.pinFolder(profile: self.profile, path: self.path, service: coalesced) }
        try await waitFor { await service.lists.count == 2 }
        saving.cancel()
        do { _ = try await saving.value; XCTFail("Snapshot cancellation must return") } catch is CancellationError { }
        await service.release()
        let listing = try await foreground.value
        XCTAssertEqual(listing.path, path)
        await store.cancelAndDrain()
    }
    func testLegacySingleFileIndexAndOverlappingFolderOwnershipStayIndependent() async throws {
        let (dir, store, service) = try setup()
        let single = try await store.pin(profile: profile, entry: .init(name: "one.txt", path: path + "/one.txt", kind: .file), allowedRoot: "/root", service: service)
        let index = dir.appendingPathComponent("index-v1.json")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        value.removeValue(forKey: "folders")
        try JSONSerialization.data(withJSONObject: value).write(to: index)
        let legacy = try OfflineFileStore(directory: dir), restored = await legacy.librarySnapshot()
        XCTAssertEqual(restored.files.map(\.id), [single.id]); XCTAssertTrue(restored.folders.isEmpty)
        // Only the original owner writes; reopening above checks the old schema without mutation.
        let parent = try await store.pinFolder(profile: profile, path: path, service: service)
        let nested = try await store.pinFolder(profile: profile, path: path + "/Nested", service: service)
        XCTAssertTrue(Set(parent.fileIDs).isDisjoint(with: nested.fileIDs))
        try await store.removeFolder(parent.id)
        let after = await store.librarySnapshot()
        XCTAssertEqual(after.folders, [nested]); XCTAssertEqual(after.files.count, 2)
        XCTAssertTrue(after.files.contains { $0.id == single.id })
        let lease = try await store.lease(try XCTUnwrap(nested.fileIDs.first))
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("old\r\n".utf8))
    }
    func testEmptySnapshotsAreBoundedAndUnicodeByteNamesStayDistinct() async throws {
        let (_, store, service) = try setup()
        let names = ["caf\u{e9}.txt", "cafe\u{301}.txt"]
        await service.set(path, entries: names.map { .init(name: $0, path: path + "/" + $0, kind: .file) })
        let folder = try await store.pinFolder(profile: profile, path: path, service: service)
        let files = await store.snapshot()
        XCTAssertEqual(files.count, 2); XCTAssertEqual(Set(files.map { Data($0.path.utf8) }).count, 2)
        try await store.removeFolder(folder.id)
        for index in 0..<OfflineFileStore.maximumFolders {
            let empty = "/root/empty-\(index)"
            await service.set(empty, entries: [])
            let pin = try await store.pinFolder(profile: profile, path: empty, service: service)
            XCTAssertTrue(pin.fileIDs.isEmpty); XCTAssertEqual(pin.directories, [empty])
        }
        await service.set("/root/extra", entries: [])
        do { _ = try await store.pinFolder(profile: profile, path: "/root/extra", service: service); XCTFail("Empty folders still consume a snapshot slot") }
        catch OfflineFileError.folderLimit { }
    }

    private let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/root")
    private let path = "/root/Docs"
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("offline-folder-" + UUID().uuidString) }
    private func setup(fileLimit: Int = 128 * 1_024 * 1_024, storageLimit: Int = 512 * 1_024 * 1_024,
                       countLimit: Int = 100) throws -> (URL, OfflineFileStore, FolderFixture) {
        let dir = directory(), service = FolderFixture()
        let store = try OfflineFileStore(directory: dir, fileLimit: fileLimit, storageLimit: storageLimit, countLimit: countLimit)
        addTeardownBlock { await service.release(); await store.cancelAndDrain(); try? FileManager.default.removeItem(at: dir) }
        return (dir, store, service)
    }
    private func waitFor(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        let matched = await condition()
        XCTAssertTrue(matched)
    }
    func testNestedSnapshotPersistsEmptyFoldersAndSkipsLinksWithoutTransportOnOpen() async throws {
        let (dir, store, service) = try setup()
        let folder = try await store.pinFolder(profile: profile, path: path, service: service)
        let library = await store.librarySnapshot(), requests = await service.downloads
        XCTAssertEqual(folder.directories.count, 3)
        XCTAssertTrue(folder.directories.contains(path + "/Empty"))
        XCTAssertEqual(folder.fileIDs.count, 2); XCTAssertEqual(folder.skippedLinks, 1); XCTAssertEqual(folder.skippedOtherEntries, 1)
        XCTAssertTrue(requests.allSatisfy { $0.1 == path })
        XCTAssertFalse(requests.contains { $0.0.hasSuffix(".hidden") || $0.0.contains("loop") })
        XCTAssertEqual(library.files.count, 2)
        await service.disconnect()
        let reopened = try OfflineFileStore(directory: dir), restored = await reopened.librarySnapshot()
        XCTAssertEqual(restored.folders, [folder]); XCTAssertEqual(restored.files.count, 2)
        for id in folder.fileIDs {
            let lease = try await reopened.lease(id)
            XCTAssertEqual(try Data(contentsOf: lease.url), Data("old\r\n".utf8))
        }
        let after = await service.downloads
        XCTAssertEqual(after.count, requests.count, "Opening saved files must not call transport")
    }
    func testAtomicRefreshUpdatesHiddenChoiceAndKeepsOldLeaseAndStableFileIDs() async throws {
        let (_, store, service) = try setup()
        let first = try await store.pinFolder(profile: profile, path: path, service: service)
        let before = await store.snapshot(), pin = try XCTUnwrap(before.first { $0.path.hasSuffix("one.txt") })
        let old = try await store.lease(pin.id)
        await service.configure(bytes: Data("new".utf8))
        await service.set(path + "/Nested", entries: [])
        let second = try await store.pinFolder(profile: profile, path: path, includeHidden: true, service: service)
        let after = await store.snapshot()
        XCTAssertEqual(first.id, second.id); XCTAssertEqual(second.fileIDs.count, 2); XCTAssertTrue(second.includeHidden)
        XCTAssertTrue(after.contains { $0.filename == ".hidden" })
        XCTAssertFalse(after.contains { $0.filename == "東京.txt" }, "Refresh must remove deleted members")
        XCTAssertTrue(second.directories.contains(path + "/Nested"), "An emptied directory remains browseable")
        let refreshed = try XCTUnwrap(after.first { $0.path == pin.path })
        XCTAssertEqual(refreshed.id, pin.id); XCTAssertNotEqual(refreshed.blobID, pin.blobID)
        XCTAssertEqual(try Data(contentsOf: old.url), Data("old\r\n".utf8))
        let fresh = try await store.lease(pin.id)
        XCTAssertEqual(try Data(contentsOf: fresh.url), Data("new".utf8))
    }
    func testFailedRefreshNeverPublishesPartialFilesAndKeepsPreviousIndex() async throws {
        let (dir, store, service) = try setup()
        let first = try await store.pinFolder(profile: profile, path: path, service: service)
        let index = dir.appendingPathComponent("index-v1.json"), original = try Data(contentsOf: index)
        await service.configure(bytes: Data("replacement".utf8), failure: path + "/Nested/東京.txt")
        do { _ = try await store.pinFolder(profile: profile, path: path, service: service); XCTFail("Unreadable member must fail the snapshot") }
        catch RemoteFileError.permissionDenied { }
        await store.cancelAndDrain()
        XCTAssertEqual(try Data(contentsOf: index), original)
        let library = await store.librarySnapshot()
        XCTAssertEqual(library.folders, [first]); XCTAssertEqual(library.files.count, 2)
        let blobs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(blobs.count, 2, "Unpublished blobs must be removed")
    }
    func testCountBytesDepthAndEntryLimitsKeepLibraryEmpty() async throws {
        for mode in 0..<6 {
            let (_, store, service) = try setup(fileLimit: mode == 0 ? 2 : 100, storageLimit: mode == 1 ? 7 : 100, countLimit: mode == 2 ? 1 : 100)
            let limits = OfflineFolderLimits(depth: mode == 3 ? 0 : 16, directories: mode == 5 ? 1 : 256,
                                             entries: mode == 4 ? 1 : 100)
            do { _ = try await store.pinFolder(profile: profile, path: path, service: service, limits: limits); XCTFail("Limit \(mode) must fail") }
            catch let error as OfflineFileError {
                switch (mode, error) {
                case (0, .tooLarge), (1, .storageFull), (2, .tooManyFiles), (3, .folderLimit), (4, .folderLimit), (5, .folderLimit): break
                default: XCTFail("Wrong limit error \(error)")
                }
            }
            await store.cancelAndDrain()
            let saved = await store.librarySnapshot()
            XCTAssertTrue(saved.files.isEmpty); XCTAssertTrue(saved.folders.isEmpty)
        }
    }
    func testCancellationAndBusyWaitStayOwnedUntilLateWriterStops() async throws {
        let (_, store, service) = try setup()
        await service.configure(holdFile: true)
        let id = UUID(), other = UUID()
        let saving = Task { try await store.pinFolder(profile: self.profile, path: self.path, service: service, operationID: id) }
        try await waitFor { await service.waiting() }
        saving.cancel()
        do { _ = try await saving.value; XCTFail("Cancellation must return promptly") } catch is CancellationError { }
        do { _ = try await store.pinFolder(profile: profile, path: path, service: service, operationID: other); XCTFail("Late worker owns slot") }
        catch OfflineFileError.busy { }
        await store.waitForCancelledTransfer(other)
        let saved = await store.librarySnapshot()
        XCTAssertTrue(saved.files.isEmpty); XCTAssertTrue(saved.folders.isEmpty)
        await service.release(); await store.waitForCancelledTransfer(id)
        _ = try await store.pinFolder(profile: profile, path: path, service: service)
    }
    func testListingDeadlineReturnsAndLateListingCannotStartMoreWork() async throws {
        let (_, store, service) = try setup()
        await service.configure(holdListing: true)
        let saving = Task { try await store.pinFolder(profile: self.profile, path: self.path, service: service, limits: .init(seconds: 1)) }
        try await waitFor { await service.waiting() }
        do { _ = try await saving.value; XCTFail("Whole snapshot needs a deadline") }
        catch OfflineFileError.folderLimit { }
        await service.release(); await store.cancelAndDrain()
        let lists = await service.lists, saved = await store.librarySnapshot()
        XCTAssertEqual(lists.count, 1); XCTAssertTrue(saved.files.isEmpty); XCTAssertTrue(saved.folders.isEmpty)
    }
    func testRemovingDuringRefreshDoesNotResurrectFolderOrRemoveIndividualCopy() async throws {
        let (_, store, service) = try setup()
        let folder = try await store.pinFolder(profile: profile, path: path, service: service)
        let individual = try await store.pin(profile: profile, entry: .init(name: "one.txt", path: path + "/one.txt", kind: .file), allowedRoot: "/root", service: service)
        XCTAssertFalse(folder.fileIDs.contains(individual.id))
        let old = try await store.lease(try XCTUnwrap(folder.fileIDs.first))
        await service.configure(holdFile: true)
        let saving = Task { try await store.pinFolder(profile: self.profile, path: self.path, service: service) }
        try await waitFor { await service.waiting() }
        try await store.removeFolder(folder.id)
        do { _ = try await saving.value; XCTFail("Removed folder must not return") } catch is CancellationError { }
        await service.release(); await store.cancelAndDrain()
        let saved = await store.librarySnapshot()
        XCTAssertTrue(saved.folders.isEmpty); XCTAssertEqual(saved.files.map(\.id), [individual.id])
        XCTAssertEqual(try Data(contentsOf: old.url), Data("old\r\n".utf8))
    }
    func testRedirectedListingsFilesAndInvalidChildrenFailClosed() async throws {
        for mode in 0..<3 {
            let (_, store, service) = try setup()
            if mode == 0 { await service.configure(redirect: path) }
            if mode == 1 { await service.configure(redirect: path + "/one.txt") }
            if mode == 2 { await service.set(path, entries: [.init(name: "../escape", path: "/root/escape", kind: .file)]) }
            do { _ = try await store.pinFolder(profile: profile, path: path, service: service); XCTFail("Redirect must not publish") }
            catch is RemoteDocumentLinkError { XCTAssertNotEqual(mode, 2) }
            catch RemoteFileError.invalidPath { XCTAssertEqual(mode, 2) }
            await store.cancelAndDrain()
            let saved = await store.librarySnapshot()
            XCTAssertTrue(saved.files.isEmpty); XCTAssertTrue(saved.folders.isEmpty)
        }
    }
    func testCorruptMembershipFailsClosedWithoutDeletingCopiesAndChildrenCannotBeRemovedAlone() async throws {
        let (dir, store, service) = try setup()
        let folder = try await store.pinFolder(profile: profile, path: path, service: service)
        let member = try XCTUnwrap(folder.fileIDs.first)
        do { try await store.remove(member); XCTFail("Member belongs to whole snapshot") } catch OfflineFileError.folderMember { }
        let index = dir.appendingPathComponent("index-v1.json")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var folders = try XCTUnwrap(value["folders"] as? [[String: Any]])
        folders[0]["fileIDs"] = [UUID().uuidString]; value["folders"] = folders
        let corrupt = try JSONSerialization.data(withJSONObject: value)
        try corrupt.write(to: index)
        XCTAssertThrowsError(try OfflineFileStore(directory: dir))
        XCTAssertEqual(try Data(contentsOf: index), corrupt)
        let lease = try await store.lease(member)
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("old\r\n".utf8))
    }
}
