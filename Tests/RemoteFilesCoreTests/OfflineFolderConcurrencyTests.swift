import Foundation
import XCTest
@testable import RemoteFilesCore

/// A transport that shares one channel between a folder's files, as `SFTPRemoteFileService` does. Like the real
/// one it refuses more bytes than the limit; it records how many files overlapped, what each was given, and how
/// much a save had staged on disk whenever a file started.
private actor BatchFolderFixture: RemoteFileService, SnapshotBatchDownloading, BackgroundFolderListing {
    struct Start: Sendable { let path: String; let limit: Int; let overlapped: Bool; let alongside: Int; let staged: Int }
    var tree: [String: [RemoteEntry]] = [:]
    var contents: [String: Data] = [:]
    var delays: [String: Duration] = [:]
    var failures: [String: Error] = [:]
    var hold = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var gatedPaths: Set<String> = []
    private var gatedTransfers: [String: CheckedContinuation<Void, Never>] = [:]
    private var startObservers: [(paths: Set<String>, expectation: XCTestExpectation)] = []
    private var completionObservers: [(paths: Set<String>, expectation: XCTestExpectation)] = []
    private(set) var starts: [Start] = []
    private(set) var completions: [String] = []
    private(set) var plainDownloads = 0
    private(set) var batchesEnded = 0
    private var active = 0, pooled = 0
    private(set) var mostActive = 0, mostPooled = 0
    // Listings: how long each takes, how many times each fails before it answers, and which one each waits to see
    // started before it answers (or gives up after a minute, longer than a listing's own deadline).
    private var listingDelays: [String: Duration] = [:], listingFailures: [String: (error: Error, times: Int)] = [:]
    private var listingHolds: [String: String] = [:]
    private(set) var listings: [String] = []
    /// Whether a session is open for listings that must not open one. Lists made that way, by path.
    var sessionOpen = true
    private(set) var backgroundListings: [String] = []
    private(set) var mostListings = 0
    private(set) var heldListingReleased: [String: Bool] = [:]
    private var listingActive = 0

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
    func configureListings(delays: [String: Duration] = [:], failures: [String: (error: Error, times: Int)] = [:], holds: [String: String] = [:]) {
        listingDelays = delays; listingFailures = failures; listingHolds = holds
    }
    func setContents(_ path: String, _ data: Data) { contents[path] = data }
    func setEntries(_ path: String, _ entries: [RemoteEntry]) { tree[path] = entries }
    func waitingCount() -> Int { waiters.count }
    /// Hold selected transfers until the test releases them, independent of executor speed. Unlike a delay,
    /// this guarantees that every expected transfer has started before any of them can finish.
    func gate(_ paths: [String]) { gatedPaths.formUnion(paths) }
    func expectStarts(_ paths: [String], fulfilling expectation: XCTestExpectation) {
        startObservers.append((Set(paths), expectation)); fulfilObservers()
    }
    func expectCompletions(_ paths: [String], fulfilling expectation: XCTestExpectation) {
        completionObservers.append((Set(paths), expectation)); fulfilObservers()
    }
    private func fulfilObservers() {
        let started = Set(starts.map(\.path)), completed = Set(completions)
        startObservers.removeAll { observer in
            guard observer.paths.isSubset(of: started) else { return false }
            observer.expectation.fulfill(); return true
        }
        completionObservers.removeAll { observer in
            guard observer.paths.isSubset(of: completed) else { return false }
            observer.expectation.fulfill(); return true
        }
    }
    func release(_ path: String) {
        gatedPaths.remove(path)
        gatedTransfers.removeValue(forKey: path)?.resume()
    }
    func release() {
        hold = false; gatedPaths.removeAll()
        let pending = waiters + Array(gatedTransfers.values)
        waiters = []; gatedTransfers = [:]
        pending.forEach { $0.resume() }
    }

    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        listings.append(path)
        listingActive += 1; mostListings = max(mostListings, listingActive)
        defer { listingActive -= 1 }
        if let other = listingHolds[path] {
            let end = ContinuousClock.now + .seconds(60)
            while !listings.contains(other), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(2)) }
            heldListingReleased[path] = listings.contains(other)
        }
        if let delay = listingDelays[path] { try? await Task.sleep(for: delay) }
        if let failure = listingFailures[path], failure.times > 0 {
            listingFailures[path] = (failure.error, failure.times - 1)
            throw failure.error
        }
        guard let entries = tree[path] else { throw RemoteFileError.notFound }
        return .init(path: path, entries: entries)
    }
    func listDirectoryInBackground(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot? {
        guard sessionOpen else { return nil }
        backgroundListings.append(path)
        return try await listDirectory(profile: profile, path: path)
    }
    func setSessionOpen(_ open: Bool) { sessionOpen = open }
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
        fulfilObservers()
        defer {
            active -= 1; if overlapped { pooled -= limit }
            completions.append(path); fulfilObservers()
        }
        if hold { await withCheckedContinuation { waiters.append($0) } } // Ignores cancellation, as a stuck transport would.
        if gatedPaths.contains(path) { await withCheckedContinuation { gatedTransfers[path] = $0 } }
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

    private enum BarrierError: Error { case missingStarts([String]), missingCompletion(String) }

    private func startSaving(_ store: OfflineFileStore, service: BatchFolderFixture) -> Task<OfflineFolderPin, Error> {
        let saving = Task { try await store.pinFolder(profile: self.profile, path: self.root, service: service) }
        // A failed barrier must also release the transport that deliberately ignores cancellation.
        addTeardownBlock { saving.cancel(); await service.release(); _ = await saving.result }
        return saving
    }

    private func waitForStarts(_ paths: [String], service: BatchFolderFixture) async throws {
        let started = expectation(description: "Transfers started: \(paths)")
        await service.expectStarts(paths, fulfilling: started)
        await fulfillment(of: [started], timeout: 10)
        let starts = await service.starts
        guard Set(paths).isSubset(of: Set(starts.map(\.path))) else { throw BarrierError.missingStarts(paths) }
    }

    private func complete(_ path: String, service: BatchFolderFixture) async throws {
        let completed = expectation(description: "Transfer completed: \(path)")
        await service.expectCompletions([path], fulfilling: completed)
        await service.release(path)
        await fulfillment(of: [completed], timeout: 10)
        let completions = await service.completions
        guard completions.contains(path) else { throw BarrierError.missingCompletion(path) }
    }

    func testOverlappingFilesCommitInWalkOrderWithinTheWindow() async throws {
        let (store, service) = try setup()
        await service.make(root: root, folders: 3, files: 10)
        let walk = walkOrder(folders: 3, files: 10), window = 16
        await service.gate(walk)
        let saving = startSaving(store, service: service)
        try await waitForStarts(Array(walk.prefix(window)), service: service)
        let initiallyCompleted = await service.completions
        XCTAssertTrue(initiallyCompleted.isEmpty, "The whole window overlaps before any transfer finishes")
        // Acknowledge each completion before releasing the next, so later files really do finish first.
        // Keep subsequent files gated too, so a replacement cannot exceed the active-transfer bound unseen.
        let completionOrder = Array(walk.prefix(window).reversed()) + Array(walk.dropFirst(window).reversed())
        for (offset, path) in walk.prefix(window).reversed().enumerated() {
            try await complete(path, service: service)
            if window + offset < walk.count {
                // A replacement starts only after the scheduler receives the completed file's outcome.
                // Earlier files are still gated, so the walk-order assertion exercises buffered results.
                try await waitForStarts([walk[window + offset]], service: service)
            }
        }
        try await waitForStarts(walk, service: service)
        for path in walk.dropFirst(window).reversed() { try await complete(path, service: service) }
        let folder = try await saving.value
        let completed = await service.completions
        XCTAssertEqual(completed, completionOrder)
        let pins = await store.snapshot()
        let order = folder.fileIDs.compactMap { id in pins.first { $0.id == id }?.path }
        XCTAssertEqual(order, walk, "Committed in the walk's order despite reversed transfer completions")
        let expected = await service.contents
        let saved = try await savedBytes(store, folder)
        XCTAssertEqual(saved, expected)
        let most = await service.mostActive, ended = await service.batchesEnded, plain = await service.plainDownloads
        XCTAssertEqual(most, window, "Small files fill the 16-file window and never exceed it")
        XCTAssertEqual(ended, 1, "One batch, ended once")
        XCTAssertEqual(plain, 0)
        let starts = await service.starts
        XCTAssertTrue(starts.allSatisfy { $0.overlapped && $0.limit == 128 * 1_024 }, "Each is given its size in reads and one more")
    }

    func testOverlappingFilesShareAPoolNoLargerThanOneGrowingTransfer() async throws {
        let (store, service) = try setup()
        await service.make(root: root, folders: 2, files: 6, size: 900_000)
        let walk = walkOrder(folders: 2, files: 6)
        await service.gate(walk)
        let saving = startSaving(store, service: service)
        var completionOrder: [String] = []
        for offset in stride(from: 0, to: walk.count, by: 4) {
            let group = Array(walk[offset..<min(offset + 4, walk.count)])
            try await waitForStarts(group, service: service)
            for path in group.reversed() { try await complete(path, service: service) }
            completionOrder.append(contentsOf: group.reversed())
        }
        let folder = try await saving.value
        XCTAssertEqual(folder.fileIDs.count, 12)
        let most = await service.mostActive, pooled = await service.mostPooled
        XCTAssertEqual(most, 4, "Four shares of 960 KiB fit in 4 MiB, a fifth doesn't")
        XCTAssertEqual(pooled, 4 * 960 * 1_024, "The four shares were reserved together")
        XCTAssertLessThanOrEqual(pooled, OfflineFolderDownload.overlapPool)
        let completed = await service.completions
        XCTAssertEqual(completed, completionOrder)
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
            // These cases also assert overlap. Hold the first two until both have started instead of relying
            // on an incidental suspension in the progress callback to keep the first alive.
            let overlapping = item.files > 2 && item.expected != "tooLarge"
            let firstTwo = Array(walkOrder(folders: 1, files: item.files).prefix(2))
            if overlapping { await service.gate(firstTwo) }
            let saving = startSaving(store, service: service)
            if overlapping {
                try await waitForStarts(firstTwo, service: service)
                await service.release()
            }
            do {
                let folder = try await saving.value
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
            if overlapping { XCTAssertGreaterThan(most, 1, "These overlap: \(item)") }
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
        XCTAssertLessThan(values.count, 80, "Not one report per file, as before")
        // A forced report resets the interval, and a trailing one already due can follow it, so at most two an
        // interval, besides the first listing and the two forced ones. Before, it was three a file.
        let intervals = Int((elapsed / OfflineFolderDownload.reportInterval).rounded(.up))
        XCTAssertLessThanOrEqual(values.count, 3 + 2 * intervals, "At most ten others a second, give or take one")
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

    // MARK: Listing ahead

    private func savedPaths(_ store: OfflineFileStore, _ folder: OfflineFolderPin) async -> [String] {
        let pins = await store.snapshot()
        return folder.fileIDs.compactMap { id in pins.first { $0.id == id }?.path }
    }
    /// Runs `body` with the walk listing `ahead` folders ahead, as shipped afterwards.
    private func listing<T>(ahead: Int, _ body: () async throws -> T) async rethrows -> T {
        let shipped = OfflineFolderDownload.listingsAhead
        OfflineFolderDownload.listingsAhead = ahead
        defer { OfflineFolderDownload.listingsAhead = shipped }
        return try await body()
    }

    func testFoldersAreListedAheadWhileFilesRunAndTakenUpInWalkOrder() async throws {
        var outcomes: [(paths: [String], bytes: [String: Data])] = []
        for ahead in [0, 4] {
            let (store, service) = try setup()
            await service.make(root: root, folders: 6, files: 3)
            // Later folders answer first. Listing ahead, folder 0 answers only once folder 1 is being listed too.
            let delays = Dictionary(uniqueKeysWithValues: (0..<6).map { (root + "/folder \($0)", Duration.milliseconds(30 - 5 * $0)) })
            await service.configureListings(delays: delays, holds: ahead > 0 ? [root + "/folder 0": root + "/folder 1"] : [:])
            let folder = try await listing(ahead: ahead) { try await store.pinFolder(profile: profile, path: root, service: service) }
            outcomes.append((await savedPaths(store, folder), try await savedBytes(store, folder)))
            XCTAssertEqual(folder.directories.count, 7)
            let listings = await service.listings, most = await service.mostListings
            XCTAssertEqual(listings.count, 7, "Each folder once")
            if ahead > 0 {
                let released = await service.heldListingReleased[root + "/folder 0"]
                XCTAssertEqual(released, true, "The next folder was being listed before this one was taken up")
                XCTAssertGreaterThan(most, 1)
                XCTAssertLessThanOrEqual(most, ahead, "No more than that many at once")
            } else {
                XCTAssertEqual(most, 1, "One at a time, as before")
            }
        }
        XCTAssertEqual(outcomes[1].paths, outcomes[0].paths, "Committed in the same order")
        XCTAssertEqual(outcomes[1].paths, walkOrder(folders: 6, files: 3))
        XCTAssertEqual(outcomes[1].bytes, outcomes[0].bytes)
    }

    /// A listing that failed ahead of its turn isn't reported: the folder is listed again when the walk reaches
    /// it, alone, and that answer is the one that counts, as when listing one folder at a time.
    func testAListingThatFailedAheadIsListedAgainAtItsTurn() async throws {
        let failing = root + "/folder 2"
        // Once only: the second listing, at its turn, succeeds.
        do {
            let (store, service) = try setup()
            await service.make(root: root, folders: 4, files: 2)
            await service.configureListings(failures: [failing: (RemoteFileError.connectionEnded, 1)])
            let folder = try await listing(ahead: 4) { try await store.pinFolder(profile: profile, path: root, service: service) }
            XCTAssertEqual(folder.fileIDs.count, 8)
            let listings = await service.listings
            XCTAssertEqual(listings.filter { $0 == failing }.count, 2, "Listed ahead, then again at its turn")
        }
        // Always, with an earlier file failing slowly: as one at a time, the file's failure comes first in walk
        // order and is the one reported; and with only the listing failing, it is reported after the files before it.
        for fileFails in [true, false] {
            var errors: [String] = []
            for ahead in [0, 4] {
                let (store, service) = try setup()
                await service.make(root: root, folders: 4, files: 2)
                let file = root + "/folder 1/file-1.txt"
                await service.configure(delays: [file: .milliseconds(100)], failures: fileFails ? [file: RemoteFileError.permissionDenied] : [:])
                await service.configureListings(failures: [failing: (RemoteFileError.notFound, .max)])
                do {
                    _ = try await listing(ahead: ahead) { try await store.pinFolder(profile: profile, path: root, service: service) }
                    XCTFail("The save must fail")
                } catch {
                    errors.append(String(describing: error))
                }
                let starts = await service.starts, listings = await service.listings
                XCTAssertFalse(starts.contains { $0.path.hasPrefix(failing + "/") || $0.path.hasPrefix(root + "/folder 3/") },
                               "Nothing after the folder that couldn't be listed starts")
                if ahead > 0 {
                    // A connection that dropped fails the files in flight: that is reported without listing again.
                    XCTAssertEqual(listings.filter { $0 == failing }.count, fileFails ? 1 : 2,
                                   fileFails ? "Not listed again: an earlier file's failure comes first" : "Listed again once the files before it were done")
                }
                await store.cancelAndDrain()
                let saved = await store.librarySnapshot()
                XCTAssertTrue(saved.files.isEmpty); XCTAssertTrue(saved.folders.isEmpty)
            }
            XCTAssertEqual(errors[1], errors[0], "The error a save one folder at a time reports")
            XCTAssertEqual(errors[0], String(describing: fileFails ? RemoteFileError.permissionDenied : RemoteFileError.notFound))
        }
    }

    /// Only folders the walk has queued are listed ahead, so its limits bound the listings too, and it fails
    /// where and how it did.
    func testListingAheadKeepsTheWalksLimits() async throws {
        let cases: [(String, OfflineFolderLimits, maxListed: Int)] = [
            ("directories", .init(directories: 3), 3),
            ("depth", .init(depth: 1), 9),
            ("entries", .init(entries: 9), 9),
        ]
        for (name, limits, maxListed) in cases {
            var errors: [String] = []
            for ahead in [0, 4] {
                let (store, service) = try setup()
                await service.make(root: root, folders: 4, files: 2)
                // A level below each folder, for the depth limit.
                for folder in 0..<4 {
                    let path = root + "/folder \(folder)"
                    var entries = await service.tree[path] ?? []
                    entries.append(.init(name: "inner", path: path + "/inner", kind: .directory))
                    await service.setEntries(path, entries)
                    await service.setEntries(path + "/inner", [])
                }
                do {
                    _ = try await listing(ahead: ahead) { try await store.pinFolder(profile: profile, path: root, service: service, limits: limits) }
                    XCTFail("\(name) must fail")
                } catch {
                    errors.append(String(describing: error))
                }
                let listings = await service.listings
                XCTAssertLessThanOrEqual(Set(listings).count, maxListed, "\(name): listed only what the walk queued")
                await store.cancelAndDrain()
            }
            XCTAssertEqual(errors[1], errors[0], name)
        }
    }

    /// Listings made ahead never open a session: without one, each folder is listed at its turn, as before.
    func testListingsAheadNeverOpenASession() async throws {
        let (store, service) = try setup()
        await service.make(root: root, folders: 4, files: 3)
        await service.setSessionOpen(false)
        let folder = try await listing(ahead: 4) { try await store.pinFolder(profile: profile, path: root, service: service) }
        let saved = await savedPaths(store, folder)
        XCTAssertEqual(saved, walkOrder(folders: 4, files: 3))
        let listings = await service.listings, background = await service.backgroundListings
        XCTAssertTrue(background.isEmpty)
        XCTAssertEqual(listings.count, 5, "Each folder once, at its turn")
    }

    func testACancelledSaveListsNothingMoreOnceItReturns() async throws {
        let (store, service) = try setup()
        await service.make(root: root, folders: 8, files: 2)
        await service.configure(hold: true)
        await service.configureListings(delays: Dictionary(uniqueKeysWithValues: (0..<8).map { (root + "/folder \($0)", Duration.milliseconds(50)) }))
        let id = UUID()
        let saving = Task { try await self.listing(ahead: 4) { try await store.pinFolder(profile: self.profile, path: self.root, service: service, operationID: id) } }
        try await waitFor { await service.waitingCount() > 0 }
        saving.cancel()
        do { _ = try await saving.value; XCTFail("Cancelled") } catch is CancellationError { }
        let listed = await service.listings.count
        await service.release()
        await store.waitForCancelledTransfer(id)
        try await Task.sleep(for: .milliseconds(200))
        let after = await service.listings.count
        XCTAssertEqual(after, listed, "No listing starts after the save has returned")
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
