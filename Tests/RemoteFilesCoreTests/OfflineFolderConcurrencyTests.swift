import Foundation
import XCTest
@testable import RemoteFilesCore

/// A transport that shares one channel between a folder's files, as `SFTPRemoteFileService` does. Like the real
/// one it refuses more bytes than the limit; it records how many files overlapped, what each was given, and how
/// much a save had staged on disk whenever a file started.
private actor BatchFolderFixture: RemoteFileService, SnapshotBatchDownloading {
    struct Start: Sendable { let path: String; let limit: Int; let overlapped: Bool; let alongside: Int; let staged: Int }
    var tree: [String: [RemoteEntry]] = [:]
    var contents: [String: Data] = [:]
    var delays: [String: Duration] = [:]
    var failures: [String: Error] = [:]
    var hold = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var starts: [Start] = []
    private(set) var plainDownloads = 0
    private(set) var batchesEnded = 0
    private var active = 0, pooled = 0
    private(set) var mostActive = 0, mostPooled = 0

    /// Folders of files, each `size` bytes unless `sizes` says otherwise, listed with `hints` where given.
    func make(root: String, folders: Int, files: Int, size: Int = 64, sizes: [String: Int] = [:], hints: [String: UInt64?] = [:]) {
        var top: [RemoteEntry] = []
        for folder in 0..<folders {
            let directory = root + "/folder \(folder)"
            top.append(.init(name: "folder \(folder)", path: directory, kind: .directory))
            var entries: [RemoteEntry] = []
            for file in 0..<files {
                let path = directory + "/file-\(file).txt"
                let bytes = Data(repeating: UInt8(truncatingIfNeeded: folder * 31 + file), count: sizes[path] ?? size)
                contents[path] = bytes
                let hint = hints[path] ?? UInt64(bytes.count)
                entries.append(.init(name: "file-\(file).txt", path: path, kind: .file, size: hint))
            }
            tree[directory] = entries
        }
        tree[root] = top
    }
    func configure(delays: [String: Duration] = [:], failures: [String: Error] = [:], hold: Bool = false) {
        self.delays = delays; self.failures = failures; self.hold = hold
    }
    func setContents(_ path: String, _ data: Data) { contents[path] = data }
    func setEntries(_ path: String, _ entries: [RemoteEntry]) { tree[path] = entries }
    func waitingCount() -> Int { waiters.count }
    func release() { hold = false; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }

    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        guard let entries = tree[path] else { throw RemoteFileError.notFound }
        return .init(path: path, entries: entries)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        throw RemoteFileError.unsupportedFile
    }
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        plainDownloads += 1
        return try await transfer(path: path, destination: destination, limit: limit, overlapped: false, progress: progress)
    }
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL, limit: Int,
                              batch: SnapshotTransferBatch, overlapped: Bool, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await transfer(path: path, destination: destination, limit: limit, overlapped: overlapped, progress: progress)
    }
    func endSnapshotBatch(_ batch: SnapshotTransferBatch) { batchesEnded += 1 }
    func disconnect() { release() }

    private func transfer(path: String, destination: URL, limit: Int, overlapped: Bool,
                          progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        // The save's staging folder sits three levels above the exporter's file.
        let staging = destination.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        starts.append(.init(path: path, limit: limit, overlapped: overlapped, alongside: active, staged: Self.bytes(below: staging)))
        active += 1; mostActive = max(mostActive, active)
        if overlapped { pooled += limit; mostPooled = max(mostPooled, pooled) }
        defer { active -= 1; if overlapped { pooled -= limit } }
        if hold { await withCheckedContinuation { waiters.append($0) } } // Ignores cancellation, as a stuck transport would.
        if let delay = delays[path] { try? await Task.sleep(for: delay) }
        if let failure = failures[path] { throw failure }
        guard let bytes = contents[path] else { throw RemoteFileError.notFound }
        guard bytes.count <= limit else { throw RemoteFileError.tooLarge(limit) }
        try bytes.write(to: destination)
        await progress(.init(receivedBytes: UInt64(bytes.count), isComplete: true))
        return .init(name: RemotePath.name(of: path), path: path, kind: .file, size: UInt64(bytes.count))
    }
    private static func bytes(below url: URL) -> Int {
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let item as URL in items {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}

/// The same fixture without the batch protocol, as an older adapter would be.
private struct PlainFolderService: RemoteFileService {
    let base: BatchFolderFixture
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { try await base.listDirectory(profile: profile, path: path) }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        throw RemoteFileError.unsupportedFile
    }
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await base.downloadSnapshotFile(profile: profile, path: path, canonicalRoot: canonicalRoot, destination: destination,
                                            limit: limit, progress: progress)
    }
    func disconnect() async { await base.disconnect() }
}

final class OfflineFolderConcurrencyTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/root")
    private let root = "/root/Docs"

    private func setup(fileLimit: Int = 128 * 1_024 * 1_024, storageLimit: Int = 512 * 1_024 * 1_024,
                       countLimit: Int = 100) throws -> (OfflineFileStore, BatchFolderFixture) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("offline-concurrency-" + UUID().uuidString)
        let service = BatchFolderFixture()
        let store = try OfflineFileStore(directory: dir, fileLimit: fileLimit, storageLimit: storageLimit, countLimit: countLimit)
        addTeardownBlock { await service.release(); await store.cancelAndDrain(); try? FileManager.default.removeItem(at: dir) }
        return (store, service)
    }
    /// The walk's order: folders breadth first, members by their bytes.
    private func walkOrder(folders: Int, files: Int) -> [String] {
        (0..<folders).flatMap { folder in
            (0..<files).map { "\(root)/folder \(folder)/file-\($0).txt" }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }
    }
    private func savedBytes(_ store: OfflineFileStore, _ folder: OfflineFolderPin) async throws -> [String: Data] {
        var result: [String: Data] = [:]
        for id in folder.fileIDs {
            let lease = try await store.lease(id)
            result[lease.pin.path] = try Data(contentsOf: lease.url)
        }
        return result
    }

    func testOverlappingFilesCommitInWalkOrderWithinTheWindow() async throws {
        let (store, service) = try setup()
        await service.make(root: root, folders: 3, files: 10)
        // Later files finish first, so an unordered commit would show.
        var delays: [String: Duration] = [:]
        for (position, path) in walkOrder(folders: 3, files: 10).enumerated() { delays[path] = .milliseconds((30 - position) % 7 * 3) }
        await service.configure(delays: delays)
        let folder = try await store.pinFolder(profile: profile, path: root, service: service)
        let pins = await store.snapshot()
        let order = folder.fileIDs.compactMap { id in pins.first { $0.id == id }?.path }
        XCTAssertEqual(order, walkOrder(folders: 3, files: 10), "Committed in the walk's order")
        let expected = await service.contents
        let saved = try await savedBytes(store, folder)
        XCTAssertEqual(saved, expected)
        let most = await service.mostActive, ended = await service.batchesEnded, plain = await service.plainDownloads
        XCTAssertEqual(most, OfflineFolderDownload.concurrentFiles, "Small files fill the window and never exceed it")
        XCTAssertEqual(ended, 1, "One batch, ended once")
        XCTAssertEqual(plain, 0)
        let starts = await service.starts
        XCTAssertTrue(starts.allSatisfy { $0.overlapped && $0.limit == 128 * 1_024 }, "Each is given its size in reads and one more")
    }

    func testOverlappingFilesShareAPoolNoLargerThanOneGrowingTransfer() async throws {
        let (store, service) = try setup()
        await service.make(root: root, folders: 2, files: 6, size: 900_000)
        await service.configure(delays: Dictionary(uniqueKeysWithValues: walkOrder(folders: 2, files: 6).map { ($0, .milliseconds(20)) }))
        let folder = try await store.pinFolder(profile: profile, path: root, service: service)
        XCTAssertEqual(folder.fileIDs.count, 12)
        let most = await service.mostActive, pooled = await service.mostPooled
        XCTAssertEqual(most, 4, "Four shares of 960 KiB fit in 4 MiB, a fifth doesn't")
        XCTAssertLessThanOrEqual(pooled, OfflineFolderDownload.overlapPool)
    }

    func testFilesTooLargeToOverlapOrOfUnknownSizeRunAloneWithTheirWholeLimit() async throws {
        let (store, service) = try setup()
        let large = root + "/folder 0/file-2.txt", unknown = root + "/folder 0/file-5.txt", edge = root + "/folder 0/file-7.txt"
        await service.make(root: root, folders: 1, files: 9,
                           sizes: [large: OfflineFolderDownload.overlappedFileBytes + 1, edge: OfflineFolderDownload.overlappedFileBytes],
                           hints: [unknown: nil as UInt64?])
        _ = try await store.pinFolder(profile: profile, path: root, service: service)
        let starts = await service.starts
        XCTAssertEqual(starts.count, 9)
        for start in starts {
            if start.path == large || start.path == unknown {
                XCTAssertFalse(start.overlapped, start.path); XCTAssertEqual(start.alongside, 0, "Nothing runs beside \(start.path)")
                XCTAssertEqual(start.limit, 128 * 1_024 * 1_024, "The limit a sequential save gives")
            } else {
                let size = start.path == edge ? OfflineFolderDownload.overlappedFileBytes : 64
                XCTAssertTrue(start.overlapped, start.path)
                XCTAssertEqual(start.limit, OfflineFolderDownload.overlapLimit(size: UInt64(size), fileLimit: 128 * 1_024 * 1_024))
            }
        }
        // Nothing started while a large file ran: the file after each began alone too.
        for (index, start) in starts.enumerated() where start.path == large || start.path == unknown {
            XCTAssertEqual(starts[index + 1].alongside, 0)
        }
    }

    func testAnAdapterWithoutBatchesSavesOneFileAtATimeAsBefore() async throws {
        let (store, fixture) = try setup()
        await fixture.make(root: root, folders: 2, files: 6)
        let folder = try await store.pinFolder(profile: profile, path: root, service: PlainFolderService(base: fixture))
        XCTAssertEqual(folder.fileIDs.count, 12)
        let most = await fixture.mostActive, plain = await fixture.plainDownloads, starts = await fixture.starts
        XCTAssertEqual(most, 1); XCTAssertEqual(plain, 12)
        XCTAssertTrue(starts.allSatisfy { !$0.overlapped && $0.limit == 128 * 1_024 * 1_024 })
    }

    func testTheFirstFailureInWalkOrderWinsOnceEarlierFilesFinish() async throws {
        let order = walkOrder(folders: 2, files: 5)
        // A slow failure early, a fast one later, and an invalid entry in a folder listed while they run.
        for mode in 0..<3 {
            let (store, service) = try setup()
            await service.make(root: root, folders: 2, files: 5)
            var failures: [String: Error] = [order[6]: RemoteFileError.notFound]
            if mode != 2 { failures[order[1]] = RemoteFileError.permissionDenied }
            await service.configure(delays: [order[1]: .milliseconds(150)], failures: failures)
            if mode == 1 {
                await service.setEntries(root + "/folder 1", [.init(name: "../escape", path: "/root/escape", kind: .file)])
            }
            do {
                _ = try await store.pinFolder(profile: profile, path: root, service: service)
                XCTFail("Mode \(mode) must fail")
            } catch RemoteFileError.permissionDenied {
                XCTAssertNotEqual(mode, 2, "Reported only when it is the first failure")
            } catch RemoteFileError.notFound {
                XCTAssertEqual(mode, 2, "File 6 fails first only once file 1 succeeds")
            }
            await store.cancelAndDrain()
            let saved = await store.librarySnapshot()
            XCTAssertTrue(saved.files.isEmpty); XCTAssertTrue(saved.folders.isEmpty)
        }
    }

    func testByteAndCountLimitsGiveTheOutcomeOfOneFileAtATime() async throws {
        // fileLimit sets the overlap share here, so small limits still overlap.
        struct Case { let size: Int; let files: Int; let storage: Int; let count: Int; let expected: String }
        let cases = [
            Case(size: 100, files: 12, storage: 1_000, count: 100, expected: "storageFull"), // Full exactly after ten.
            Case(size: 150, files: 8, storage: 1_000, count: 100, expected: "storageFull"),  // The seventh doesn't fit.
            Case(size: 100, files: 10, storage: 1_000, count: 100, expected: "saved"),       // Fits exactly.
            Case(size: 100, files: 8, storage: 10_000, count: 7, expected: "tooManyFiles"),
            Case(size: 250, files: 4, storage: 10_000, count: 100, expected: "tooLarge"),   // Over the per-file limit.
        ]
        for item in cases {
            let (store, service) = try setup(fileLimit: 200, storageLimit: item.storage, countLimit: item.count)
            await service.make(root: root, folders: 1, files: item.files, size: item.size)
            do {
                let folder = try await store.pinFolder(profile: profile, path: root, service: service)
                XCTAssertEqual(item.expected, "saved"); XCTAssertEqual(folder.fileIDs.count, item.files)
            } catch OfflineFileError.storageFull {
                XCTAssertEqual(item.expected, "storageFull", "\(item)")
            } catch OfflineFileError.tooManyFiles {
                XCTAssertEqual(item.expected, "tooManyFiles", "\(item)")
            } catch OfflineFileError.tooLarge(let limit) {
                XCTAssertEqual(item.expected, "tooLarge", "\(item)"); XCTAssertEqual(limit, 200)
            }
            let starts = await service.starts, most = await service.mostActive
            XCTAssertTrue(starts.allSatisfy { $0.staged <= item.storage }, "Staging never holds more than the limit: \(item)")
            if item.files > 2, item.expected != "tooLarge" { XCTAssertGreaterThan(most, 1, "These overlap: \(item)") }
            await store.cancelAndDrain()
            if item.expected != "saved" {
                let saved = await store.librarySnapshot()
                XCTAssertTrue(saved.files.isEmpty)
            }
        }
    }

    func testAFileThatGrewPastItsShareIsSavedAgainAloneAndWhatFollowsIsRedone() async throws {
        let (store, service) = try setup()
        await service.make(root: root, folders: 1, files: 8)
        let order = walkOrder(folders: 1, files: 8), grown = order[2]
        let grownBytes = Data(repeating: 7, count: 3 * 1_024 * 1_024)
        await service.setContents(grown, grownBytes) // Still listed at 64 bytes.
        await service.configure(delays: [grown: .milliseconds(80)])
        let folder = try await store.pinFolder(profile: profile, path: root, service: service)
        let expected = await service.contents
        let saved = try await savedBytes(store, folder)
        XCTAssertEqual(saved, expected)
        let pins = await store.snapshot()
        XCTAssertEqual(folder.fileIDs.compactMap { id in pins.first { $0.id == id }?.path }, order)
        let attempts = await service.starts.filter { $0.path == grown }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first?.limit, 128 * 1_024, "Its listed size in reads, and one more")
        XCTAssertEqual(attempts.last?.limit, 128 * 1_024 * 1_024); XCTAssertEqual(attempts.last?.overlapped, false)
        XCTAssertEqual(attempts.last?.alongside, 0)
        let starts = await service.starts
        XCTAssertTrue(starts.allSatisfy { $0.staged <= 512 * 1_024 * 1_024 })
    }

    func testCancellationKeepsTheSlotUntilEveryOverlappingTransferStops() async throws {
        let (store, service) = try setup()
        let count = OfflineFolderDownload.concurrentFiles + 4
        await service.make(root: root, folders: 1, files: count)
        await service.configure(hold: true)
        let id = UUID()
        let saving = Task { try await store.pinFolder(profile: self.profile, path: self.root, service: service, operationID: id) }
        try await waitFor { await service.waitingCount() == OfflineFolderDownload.concurrentFiles }
        saving.cancel()
        do { _ = try await saving.value; XCTFail("Cancellation must return promptly") } catch is CancellationError { }
        do { _ = try await store.pinFolder(profile: profile, path: root, service: service); XCTFail("Late transfers own the slot") }
        catch OfflineFileError.busy { }
        await service.release()
        await store.waitForCancelledTransfer(id)
        let saved = await store.librarySnapshot()
        XCTAssertTrue(saved.files.isEmpty); XCTAssertTrue(saved.folders.isEmpty)
        let starts = await service.starts
        XCTAssertEqual(starts.count, OfflineFolderDownload.concurrentFiles, "Nothing new starts once cancelled")
        let folder = try await store.pinFolder(profile: profile, path: root, service: service)
        XCTAssertEqual(folder.fileIDs.count, count)
    }

    func testProgressShowsTheFirstFileAndTheFinishedFolderAndAtMostTenOthersASecond() async throws {
        let (store, service) = try setup()
        await service.make(root: root, folders: 4, files: 20)
        let reports = ProgressReports(), started = ContinuousClock.now
        _ = try await store.pinFolder(profile: profile, path: root, service: service) { reports.add($0) }
        let values = reports.values, elapsed = started.duration(to: .now)
        XCTAssertTrue(values.contains { $0.files == 1 }, "The first finished file always shows")
        XCTAssertEqual(values.last?.files, 80, "So does the finished folder")
        XCTAssertEqual(values.last?.folders, 5)
        let allowed = 3 + Int(elapsed / OfflineFolderDownload.reportInterval) + 1
        XCTAssertLessThanOrEqual(values.count, allowed, "Not one report per file and chunk")
    }

    func testTheFolderDeadlineEndsOverlappingTransfersAndPublishesNothing() async throws {
        let (store, service) = try setup()
        await service.make(root: root, folders: 1, files: 10)
        await service.configure(hold: true)
        let saving = Task { try await store.pinFolder(profile: self.profile, path: self.root, service: service, limits: .init(seconds: 1)) }
        do { _ = try await saving.value; XCTFail("The whole save has a deadline") }
        catch OfflineFileError.folderLimit { }
        await service.release(); await store.cancelAndDrain()
        let saved = await store.librarySnapshot()
        XCTAssertTrue(saved.files.isEmpty); XCTAssertTrue(saved.folders.isEmpty)
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !(await condition()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        let matched = await condition()
        XCTAssertTrue(matched)
    }
}

private final class ProgressReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [OfflineFolderProgress] = []
    var values: [OfflineFolderProgress] { lock.lock(); defer { lock.unlock() }; return reports }
    func add(_ value: OfflineFolderProgress) { lock.lock(); reports.append(value); lock.unlock() }
}
