import Foundation

struct PreparedOfflineFolder: Sendable {
    var files: [OfflinePin] = []
    var directories: [String] = []
    var skippedLinks = 0
    var skippedOtherEntries = 0
}

/// Owns all work and unpublished bytes until the final atomic manifest commit. Even an adapter
/// that ignores cancellation keeps just this one slot; its late bytes cannot reach a later save.
actor OfflineFolderDownload {
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
    private var exporter: RemoteOriginalExporter?

    init(directory: URL, profile: ConnectionProfile, path: String, includeHidden: Bool, service: any RemoteFileService,
         oldFiles: [OfflinePin], fileLimit: Int, byteLimit: Int, countLimit: Int, limits: OfflineFolderLimits,
         progress: @escaping OfflineFolderProgressHandler) {
        self.directory = directory; self.profile = profile; self.path = path; self.includeHidden = includeHidden
        self.service = service; self.oldFiles = oldFiles; self.fileLimit = fileLimit; self.byteLimit = byteLimit
        self.countLimit = countLimit; self.limits = limits; self.progress = progress
    }
    func prepare() async throws -> PreparedOfflineFolder {
        let task = Task { try await walk() }; work = task
        let expired = OfflineDeadlineFlag()
        do {
            return try await withTaskCancellationHandler {
                try await SFTPRemoteFileService.detachedDeadline(seconds: limits.seconds, onTimeout: {
                    expired.set(); task.cancel(); Task { await self.cancel() }
                }) { try await task.value }
            } onCancel: { task.cancel(); Task { await self.cancel() } }
        } catch {
            if expired.isSet { throw OfflineFileError.folderLimit("10 minute time") }
            throw error
        }
    }
    func cancel() async { work?.cancel(); await exporter?.cancelAll() }
    func cancelAndDrain() async {
        await cancel()
        _ = await work?.result
        await exporter?.cancelAndDrain()
        cleanup()
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    private func walk() async throws -> PreparedOfflineFolder {
        try Task.checkCancellation()
        try OfflineFileStore.protectDirectory(directory)
        let boundary = try await service.resolveEntry(profile: profile, path: profile.startingDirectory)
        try Task.checkCancellation()
        guard boundary.kind == .directory, OfflineFolderPin.validPath(boundary.path), RemoteResourcePath.contains(path, in: boundary.path) else {
            throw RemoteDocumentLinkError.outsideConnection
        }
        var result = PreparedOfflineFolder(), state = OfflineFolderProgress()
        var queue: [(String, Int)] = [(path, 0)], index = 0, scanned = 0, bytes = 0
        var seen = Set<Data>([Data(path.utf8)])
        while index < queue.count {
            try Task.checkCancellation()
            let (current, depth) = queue[index]; index += 1
            let listing = try await service.listDirectory(profile: profile, path: current)
            try Task.checkCancellation()
            guard listing.path.utf8.elementsEqual(current.utf8) else { throw RemoteDocumentLinkError.outsideConnection }
            guard listing.entries.count <= limits.entries - scanned else { throw OfflineFileError.folderLimit("10,000 entry") }
            scanned += listing.entries.count
            result.directories.append(current); state.folders += 1
            await progress(state)
            for entry in listing.entries.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
                try Task.checkCancellation()
                guard OfflineFileStore.validFilename(entry.name), OfflineFolderPin.validPath(entry.path),
                      entry.path.utf8.elementsEqual(RemotePath.appending(entry.name, to: current).utf8),
                      RemoteResourcePath.contains(entry.path, in: path), seen.insert(Data(entry.path.utf8)).inserted else {
                    throw RemoteFileError.invalidPath
                }
                if !includeHidden && entry.name.hasPrefix(".") { continue }
                switch entry.kind {
                case .symlink:
                    result.skippedLinks += 1; state.skippedLinks += 1
                case .other: result.skippedOtherEntries += 1
                case .directory:
                    guard depth < limits.depth else { throw OfflineFileError.folderLimit("16 level depth") }
                    guard queue.count < limits.directories else { throw OfflineFileError.folderLimit("256 directory") }
                    queue.append((entry.path, depth + 1))
                case .file:
                    guard result.files.count < countLimit else { throw OfflineFileError.tooManyFiles }
                    let available = byteLimit - bytes
                    guard available > 0 else { throw OfflineFileError.storageFull }
                    let amount = min(fileLimit, available)
                    let adapter = SnapshotDownloadService(base: service, root: path)
                    let worker = RemoteOriginalExporter(service: adapter, directory: directory.appendingPathComponent(".download"), fileLimit: amount)
                    exporter = worker
                    var currentState = state; currentState.currentFile = entry.name
                    let reportedState = currentState
                    let baseline = UInt64(bytes)
                    await progress(currentState)
                    let prepared: PreparedOriginalFile
                    do {
                        prepared = try await worker.prepare(profile: profile, entry: entry, allowedRoot: path) { update in
                            var value = reportedState; value.bytes = baseline + update.receivedBytes
                            await self.progress(value)
                        }
                    } catch OriginalFileExportError.tooLarge {
                        if amount < fileLimit { throw OfflineFileError.storageFull }
                        throw OfflineFileError.tooLarge(fileLimit)
                    }
                    try Task.checkCancellation()
                    let blobID = UUID(), package = directory.appendingPathComponent(blobID.uuidString)
                    try OfflineFileStore.protectDirectory(package)
                    let file = package.appendingPathComponent("original")
                    try FileManager.default.moveItem(at: prepared.url, to: file)
                    try OfflineFileStore.protectFile(file)
                    let (count, digest) = try OfflineFileStore.fingerprint(file, limit: amount)
                    let old = oldFiles.first { $0.path.utf8.elementsEqual(entry.path.utf8) }
                    let pin = OfflinePin(id: old?.id ?? UUID(), connectionID: profile.id, connectionName: profile.name,
                        routeKey: OfflinePin.routeKey(profile), path: entry.path, filename: entry.name,
                        previewFilename: entry.name, byteCount: count, savedAt: Date(), blobID: blobID, digest: digest)
                    result.files.append(pin); bytes += count
                    await worker.release(prepared.id); exporter = nil
                    state.files += 1; state.bytes = UInt64(bytes); state.currentFile = nil
                    await progress(state)
                }
            }
        }
        try Task.checkCancellation()
        return result
    }
}

private struct SnapshotDownloadService: RemoteFileService {
    let base: any RemoteFileService
    let root: String
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        try await downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit, progress: { _ in })
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int,
                      progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        let entry = try await base.downloadSnapshotFile(profile: profile, path: path, canonicalRoot: root,
            destination: destination, limit: limit, progress: progress)
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
