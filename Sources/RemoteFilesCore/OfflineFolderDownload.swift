import Foundation

/// Benchmarks only: how long the last offline folder save waited for its listings, how many it made and the most
/// it had under way at once. Saves run one at a time in the benchmark.
final class OfflineListingMetrics: @unchecked Sendable {
    struct Record: Sendable { var waited: Duration = .zero, listings = 0, mostAtOnce = 0 }
    static let shared = OfflineListingMetrics()
    private let lock = NSLock()
    private var record = Record(), running = 0
    var last: Record { lock.lock(); defer { lock.unlock() }; return record }
    func reset() { lock.lock(); record = Record(); running = 0; lock.unlock() }
    func waited(_ duration: Duration) { lock.lock(); record.waited += duration; lock.unlock() }
    func began() { lock.lock(); record.listings += 1; running += 1; record.mostAtOnce = max(record.mostAtOnce, running); lock.unlock() }
    func ended() { lock.lock(); running -= 1; lock.unlock() }
    /// Lists, counting the listing and how long the walk waited for it.
    static func listing(_ list: () async throws -> DirectorySnapshot) async throws -> DirectorySnapshot {
        let started = ContinuousClock.now
        shared.began()
        defer { shared.ended(); shared.waited(started.duration(to: .now)) }
        return try await list()
    }
}

struct PreparedOfflineFolder: Sendable {
    var files: [OfflinePin] = []
    var directories: [String] = []
    var skippedLinks = 0
    var skippedOtherEntries = 0
    var skippedNames = 0
}

/// Owns all work and unpublished bytes until the final atomic manifest commit. Even an adapter
/// that ignores cancellation keeps just this one slot; its late bytes cannot reach a later save.
actor OfflineFolderDownload {
    /// Files saved at once, on a transport that can share one channel between them (`SnapshotBatchDownloading`).
    /// Benchmarks and tests change it; see docs/PERFORMANCE.md for why it is 16.
    nonisolated(unsafe) static var concurrentFiles = 16
    /// Benchmarks only: false gives each file a channel of its own.
    nonisolated(unsafe) static var sharesChannel = true
    /// Folders listed ahead of the walk, beyond the one it is taking up. Benchmarks and tests change it; see
    /// docs/PERFORMANCE.md for why it is this.
    nonisolated(unsafe) static var listingsAhead = 4
    /// How long a file may go without receiving bytes before the save fails. Tests change it.
    nonisolated(unsafe) static var fileIdleSeconds: TimeInterval = 60
    /// The largest listed size that may overlap other files: one starting read window. Larger files, and files
    /// of unknown size, go alone.
    static let overlappedFileBytes = SFTPRemoteFileService.transferReadWindow * 64 * 1024
    /// What overlapping files may be given altogether: what one growing transfer may have in flight. Reads never
    /// go more than a byte past their limit, so together they never hold more than that.
    static let overlapPool = SFTPRemoteFileService.transferReadWindowLimit * 64 * 1024
    /// What an overlapping file is given: its listed size in whole reads, and one more read for a file that grew.
    static func overlapLimit(size: UInt64, fileLimit: Int) -> Int {
        let read = 64 * 1024
        return min(fileLimit, (Int(clamping: size) + read - 1) / read * read + read)
    }

    let directory: URL
    let profile: ConnectionProfile
    let path: String
    let includeHidden: Bool
    let service: any RemoteFileService
    let oldFiles: [OfflinePin]
    let fileLimit: Int
    let byteLimit: Int
    let countLimit: Int
    let limits: OfflineFolderLimits
    let progress: OfflineFolderProgressHandler
    private var work: Task<PreparedOfflineFolder, Error>?
    private var preparation: Task<PreparedOfflineFolder, Error>?
    private var cancelled = false
    /// Every exporter whose transfer may still be running: one that failed stays here, so that
    /// `cancelAndDrain` waits for a transfer that ignored cancellation.
    private var exporters: [ObjectIdentifier: RemoteOriginalExporter] = [:]
    /// Progress: what is committed, and what files not yet committed have received, by walk position.
    private var report = OfflineFolderProgress()
    private var savedBytes = 0
    private var received: [Int: UInt64] = [:]
    private var names: [Int: String] = [:]
    /// Progress reaches the handler at most ten times a second, as a transfer's does. The first finished file and
    /// the finished folder always report at once, and otherwise the latest follows within the interval.
    static let reportInterval: Duration = .milliseconds(100)
    private var lastReport: ContinuousClock.Instant?
    private var pendingReport: Task<Void, Never>?

    init(directory: URL, profile: ConnectionProfile, path: String, includeHidden: Bool, service: any RemoteFileService,
         oldFiles: [OfflinePin], fileLimit: Int, byteLimit: Int, countLimit: Int, limits: OfflineFolderLimits,
         progress: @escaping OfflineFolderProgressHandler) {
        self.directory = directory; self.profile = profile; self.path = path; self.includeHidden = includeHidden
        self.service = service; self.oldFiles = oldFiles; self.fileLimit = fileLimit; self.byteLimit = byteLimit
        self.countLimit = countLimit; self.limits = limits; self.progress = progress
    }
    func prepare() async throws -> PreparedOfflineFolder {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let task = Task { try await walk() }; work = task
        let expired = OfflineDeadlineFlag()
        let pending = Task {
            try await SFTPRemoteFileService.detachedDeadline(seconds: limits.seconds, onTimeout: {
                expired.set(); task.cancel(); Task { await self.cancel() }
            }) { try await task.value }
        }
        preparation = pending
        do {
            return try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: { pending.cancel(); task.cancel(); Task { await self.cancel() } }
        } catch {
            if expired.isSet { throw OfflineFileError.folderLimit("10 minute time") }
            throw error
        }
    }
    func cancel() async {
        cancelled = true
        preparation?.cancel(); work?.cancel()
        for exporter in exporters.values { await exporter.cancelAll() }
    }
    func cancelAndDrain() async {
        await cancel()
        _ = await work?.result
        for exporter in exporters.values { await exporter.cancelAndDrain() }
        cleanup()
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    private func walk() async throws -> PreparedOfflineFolder {
        try Task.checkCancellation()
        try OfflineFileStore.protectDirectory(directory)
        let batched = service as? any SnapshotBatchDownloading
        let batch = batched.map { _ in SnapshotTransferBatch(sharesChannel: Self.sharesChannel) }
        defer { pendingReport?.cancel(); pendingReport = nil }
        do {
            let result = try await transfer(batch: batch, window: batch == nil ? 1 : max(1, Self.concurrentFiles))
            if let batched, let batch { await batched.endSnapshotBatch(batch) }
            if pendingReport != nil { pendingReport?.cancel(); await reportLatest() }
            return result
        } catch {
            // Every file has finished: the group waits for them.
            if let batched, let batch { await batched.endSnapshotBatch(batch) }
            throw error
        }
    }

    /// `exact` is a file that grew past what it was given beside others, to be saved again alone.
    private struct FileJob: Sendable { let index: Int; let entry: RemoteEntry; var exact = false }
    private enum FileOutcome: Sendable { case saved(OfflinePin), tooLarge, failed(Error) }

    /// Lists the folder breadth first and saves its files in that order, up to `window` at once. However they
    /// overlap, the outcome is that of saving one file after another: results are committed strictly in order,
    /// each against the byte limit it would have had then, and the first failure in that order is the one
    /// reported, once everything started before it has finished.
    ///
    /// A file whose listed size fits one starting read window may run beside others, given its size and a read
    /// more from a pool no larger than one growing transfer's reads, with a window that doesn't grow. Any other
    /// file runs alone, as before, with exactly the limit it would have had and the growing window. One that grew
    /// past what it was given is saved again alone when its turn comes, and everything after it is redone, so
    /// staging never holds more than the byte limit.
    private func transfer(batch: SnapshotTransferBatch?, window: Int) async throws -> PreparedOfflineFolder {
        // The chosen folder is the boundary, wherever it is. Each listing must report exactly
        // the path requested, so a folder replaced by a symbolic link is rejected, and every
        // member must stay inside the chosen folder.
        var result = PreparedOfflineFolder()
        var queue: [(String, Int)] = [(path, 0)], index = 0, scanned = 0
        var seen = Set<Data>([Data(path.utf8)])
        var waiting: [FileJob] = [], found = 0
        var stopped: Error?   // Why the walk ended early, after every file it found.
        // Space is reserved from a file's start until it's committed, since until then its bytes are staged.
        var running: [Int: (job: FileJob, limit: Int)] = [:], reserved = 0, alone = false, pooled = 0
        var finished: [Int: (job: FileJob, limit: Int, outcome: FileOutcome)] = [:]
        // Listings started early, by queue position. Each is taken up only where the walk would have listed that
        // folder, and only if it succeeded. One that failed is listed again, alone, once every file before it has
        // finished: a failure among those comes first in walk order and is reported without listing anything more,
        // so the walk's outcome and the error it reports are those of listing one folder at a time. Nothing is
        // listed ahead that isn't already queued, so the depth and directory limits hold for listings as for the walk.
        var ahead: [Int: Task<DirectorySnapshot, Error>] = [:], failedAhead = Set<Int>()
        // They hold nothing of the save, so they're cancelled rather than waited for. They go over a session that
        // is already open and never open one: after the connection drops, the files in flight fail and that is
        // reported at once, rather than after an early listing connected again. They also keep off the channel
        // folders open on. A transport that can't list that way lists one folder at a time, as before.
        defer { ahead.values.forEach { $0.cancel() } }
        let service = service, profile = profile, background = service as? any BackgroundFolderListing
        func listAhead() {
            guard stopped == nil, let background else { return }
            for position in index..<min(queue.count, index + max(0, Self.listingsAhead)) where ahead[position] == nil {
                let path = queue[position].0
                ahead[position] = Task {
                    OfflineListingMetrics.shared.began()
                    defer { OfflineListingMetrics.shared.ended() }
                    guard let listing = try await background.listDirectoryInBackground(profile: profile, path: path) else {
                        throw RemoteFileError.connectionEnded
                    }
                    return listing
                }
            }
        }

        /// Lists the next folder and queues its files, or records why the walk stops. Returns false, having done
        /// nothing, if the folder must wait to be listed again until the files running now have finished.
        func listNext() async throws -> Bool {
            let position = index, (current, depth) = queue[index]
            do {
                var early: DirectorySnapshot?
                if let task = ahead.removeValue(forKey: position) {
                    let waited = ContinuousClock.now
                    do { early = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() }) }
                    catch { failedAhead.insert(position) }
                    OfflineListingMetrics.shared.waited(waited.duration(to: .now))
                    try Task.checkCancellation()
                }
                if early == nil, failedAhead.contains(position), !running.isEmpty { return false }
                index += 1
                let listing: DirectorySnapshot
                if let early { listing = early } else {
                    listing = try await OfflineListingMetrics.listing { try await service.listDirectory(profile: profile, path: current) }
                }
                try Task.checkCancellation()
                guard listing.path.utf8.elementsEqual(current.utf8) else { throw RemoteDocumentLinkError.outsideConnection }
                guard listing.entries.count <= limits.entries - scanned else { throw OfflineFileError.folderLimit("10,000 entry") }
                scanned += listing.entries.count
                result.directories.append(current); report.folders += 1
                await publish()
                for entry in listing.entries.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
                    try Task.checkCancellation()
                    // A listing that names something other than one member of this folder is refused whole.
                    guard RemotePath.isSingleName(entry.name),
                          entry.path.utf8.elementsEqual(RemotePath.appending(entry.name, to: current).utf8),
                          RemoteResourcePath.contains(entry.path, in: path), seen.insert(Data(entry.path.utf8)).inserted else {
                        throw RemoteFileError.invalidPath
                    }
                    if !includeHidden && RemotePath.isHidden(entry.name) { continue }
                    switch entry.kind {
                    case .symlink:
                        result.skippedLinks += 1; report.skippedLinks += 1
                    case .other: result.skippedOtherEntries += 1
                    case .directory:
                        // Remote paths holding a control character are never saved. A folder named with one is
                        // left out with everything in it and counted, as a file is, rather than failing the folder.
                        guard !RemotePath.hasControlCharacter(entry.name) else { result.skippedNames += 1; continue }
                        guard OfflineFolderPin.validPath(entry.path) else { throw RemoteFileError.invalidPath }
                        guard depth < limits.depth else { throw OfflineFileError.folderLimit("16 level depth") }
                        guard queue.count < limits.directories else { throw OfflineFileError.folderLimit("256 directory") }
                        queue.append((entry.path, depth + 1))
                    case .file:
                        // A saved file takes its own name on this device. One that can't, such as a name holding a
                        // backslash, is left out and counted rather than failing the folder.
                        guard OfflineFileStore.validFilename(entry.name) else { result.skippedNames += 1; continue }
                        guard OfflineFolderPin.validPath(entry.path) else { throw RemoteFileError.invalidPath }
                        guard found < countLimit else { throw OfflineFileError.tooManyFiles }
                        waiting.append(FileJob(index: found, entry: entry)); found += 1
                    }
                }
                listAhead()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                stopped = error
            }
            return true
        }

        return try await withThrowingTaskGroup(of: (Int, FileOutcome).self) { group in
            defer { group.cancelAll() }
            func start(_ job: FileJob, limit: Int, overlapped: Bool) {
                waiting.removeFirst()
                running[job.index] = (job, limit); reserved += limit; alone = !overlapped
                if overlapped { pooled += limit }
                group.addTask { (job.index, await self.save(job, limit: limit, overlapped: overlapped, batch: batch)) }
            }
            while true {
                try Task.checkCancellation()
                while running.count < window {
                    if waiting.isEmpty {
                        guard stopped == nil, index < queue.count, try await listNext() else { break }
                        continue
                    }
                    let job = waiting[0]
                    let share = job.entry.size.flatMap { size in
                        window > 1 && !job.exact && size <= UInt64(Self.overlappedFileBytes) ? Self.overlapLimit(size: size, fileLimit: fileLimit) : nil
                    }
                    if let share, !alone, pooled + share <= Self.overlapPool, byteLimit - savedBytes - reserved >= share {
                        start(job, limit: share, overlapped: true)
                    } else if running.isEmpty {
                        // Everything before it is committed, so this is the limit it has one file at a time.
                        let available = byteLimit - savedBytes
                        guard available > 0 else { throw OfflineFileError.storageFull }
                        start(job, limit: min(fileLimit, available), overlapped: false)
                    } else {
                        break
                    }
                }
                // Nothing running means nothing is left uncommitted.
                if running.isEmpty {
                    if let stopped { throw stopped }
                    break
                }
                guard let (done, outcome) = try await group.next(), let (job, limit) = running.removeValue(forKey: done) else { break }
                if alone { alone = false } else { pooled -= limit }
                finished[done] = (job, limit, outcome)
                while let (job, given, outcome) = finished.removeValue(forKey: result.files.count) {
                    let available = byteLimit - savedBytes
                    guard available > 0 else { throw OfflineFileError.storageFull }
                    let limit = min(fileLimit, available)
                    switch outcome {
                    case .failed(let error):
                        throw error
                    case .tooLarge where given >= limit:
                        if limit < fileLimit { throw OfflineFileError.storageFull }
                        throw OfflineFileError.tooLarge(fileLimit)
                    case .tooLarge:
                        // It grew past what it was given beside the others. Save it again alone, and redo what
                        // came after it, whose space it may need.
                        while let (other, outcome) = try await group.next() {
                            guard let (later, laterLimit) = running.removeValue(forKey: other) else { continue }
                            finished[other] = (later, laterLimit, outcome)
                        }
                        for (later, _, outcome) in finished.values {
                            if case .saved(let pin) = outcome { discard(pin) }
                            waiting.append(later)
                        }
                        finished.removeAll()
                        waiting.append(FileJob(index: job.index, entry: job.entry, exact: true))
                        waiting.sort { $0.index < $1.index }
                        received.removeAll(); reserved = 0; pooled = 0; alone = false
                    case .saved(let pin):
                        guard pin.byteCount <= limit else {
                            if limit < fileLimit { throw OfflineFileError.storageFull }
                            throw OfflineFileError.tooLarge(fileLimit)
                        }
                        result.files.append(pin); savedBytes += pin.byteCount; reserved -= given
                        received.removeValue(forKey: job.index)
                        report.files += 1
                        await publish(now: report.files == 1)
                        continue
                    }
                    break
                }
            }
            try Task.checkCancellation()
            return result
        }
    }

    private func discard(_ pin: OfflinePin) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(pin.blobID.uuidString))
    }

    private func publish(now force: Bool = false) async {
        let now = ContinuousClock.now
        if !force, let last = lastReport, last.duration(to: now) < Self.reportInterval {
            guard pendingReport == nil else { return }
            pendingReport = Task {
                try? await Task.sleep(until: last + Self.reportInterval, clock: .continuous)
                guard !Task.isCancelled else { return }
                await self.reportLatest()
            }
            return
        }
        lastReport = now
        await progress(current())
    }
    private func reportLatest() async {
        pendingReport = nil; lastReport = .now
        await progress(current())
    }
    private func current() -> OfflineFolderProgress {
        var value = report
        value.bytes = UInt64(savedBytes) + received.values.reduce(0, +)
        value.currentFile = names.min { $0.key < $1.key }?.value
        return value
    }
    private func began(_ job: FileJob, exporter: RemoteOriginalExporter) async {
        exporters[ObjectIdentifier(exporter)] = exporter
        names[job.index] = job.entry.name; received[job.index] = 0
        await publish()
    }
    private func receive(_ job: FileJob, bytes: UInt64) async {
        guard names[job.index] != nil else { return }
        received[job.index] = bytes
        await publish()
    }
    private func ended(_ job: FileJob, exporter: RemoteOriginalExporter?) {
        if let exporter { exporters.removeValue(forKey: ObjectIdentifier(exporter)) }
        names.removeValue(forKey: job.index)
    }

    /// One file, start to finish, off the actor.
    private nonisolated func save(_ job: FileJob, limit: Int, overlapped: Bool, batch: SnapshotTransferBatch?) async -> FileOutcome {
        let entry = job.entry
        do {
            try Task.checkCancellation()
            let adapter = SnapshotDownloadService(base: service, root: path, batch: batch, overlapped: overlapped)
            // A directory of its own: an exporter clears abandoned output from its directory when it starts.
            // A file fails after a minute without bytes, as a managed download does, not after three minutes in all.
            let exporter = RemoteOriginalExporter(service: adapter, directory: directory.appendingPathComponent(".download-" + UUID().uuidString),
                                                  fileLimit: limit, timeoutSeconds: Self.fileIdleSeconds, idleTimeout: true)
            await began(job, exporter: exporter)
            let prepared: PreparedOriginalFile
            do {
                prepared = try await exporter.prepare(profile: profile, entry: entry, allowedRoot: path) { update in
                    await self.receive(job, bytes: update.receivedBytes)
                }
            } catch OriginalFileExportError.tooLarge {
                await ended(job, exporter: nil)
                return .tooLarge
            }
            try Task.checkCancellation()
            let blobID = UUID(), package = directory.appendingPathComponent(blobID.uuidString)
            try OfflineFileStore.protectDirectory(package)
            let file = package.appendingPathComponent("original")
            try FileManager.default.moveItem(at: prepared.url, to: file)
            try OfflineFileStore.protectFile(file)
            let (count, digest) = try OfflineFileStore.fingerprint(file, limit: limit)
            let old = oldFiles.first { $0.path.utf8.elementsEqual(entry.path.utf8) }
            let pin = OfflinePin(id: old?.id ?? UUID(), connectionID: profile.id, connectionName: profile.name,
                routeKey: OfflinePin.routeKey(profile), path: entry.path, filename: entry.name,
                previewFilename: entry.name, byteCount: count, savedAt: Date(), blobID: blobID, digest: digest)
            await exporter.release(prepared.id)
            await ended(job, exporter: exporter)
            return .saved(pin)
        } catch {
            await ended(job, exporter: nil)
            return .failed(error)
        }
    }
}

private struct SnapshotDownloadService: RemoteFileService {
    let base: any RemoteFileService
    let root: String
    let batch: SnapshotTransferBatch?
    let overlapped: Bool
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        try await downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit, progress: { _ in })
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int,
                      progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        let entry: RemoteEntry
        if let batch, let batched = base as? any SnapshotBatchDownloading {
            entry = try await batched.downloadSnapshotFile(profile: profile, path: path, canonicalRoot: root, destination: destination,
                                                           limit: limit, batch: batch, overlapped: overlapped, progress: progress)
        } else {
            entry = try await base.downloadSnapshotFile(profile: profile, path: path, canonicalRoot: root,
                destination: destination, limit: limit, progress: progress)
        }
        guard entry.kind == .file, entry.path.utf8.elementsEqual(path.utf8) else { throw RemoteDocumentLinkError.outsideConnection }
        return entry
    }
    func disconnect() async { }
}

private final class OfflineDeadlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
