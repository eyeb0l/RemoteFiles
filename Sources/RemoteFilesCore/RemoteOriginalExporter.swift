import Foundation

/// An unmodified remote file owned by one export presentation. The URL is temporary:
/// consumers must release it after the system picker finishes or is dismissed.
public struct PreparedOriginalFile: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let filename: String
    /// Canonical source name for preview format; export keeps the selected alias.
    public let sourceFilename: String
    public let expiresAt: Date
}

public enum OriginalFileExportError: LocalizedError, Sendable {
    case alreadyPreparing, invalidFilename, notRegularFile, outsideRoot, timedOut, tooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .alreadyPreparing: return "Finish or cancel the current export before preparing another file."
        case .invalidFilename: return "This filename cannot be saved safely on this device. It may contain characters that hide its real name."
        case .notRegularFile: return "Only regular files can be exported."
        case .outsideRoot: return "This file or its folder has moved or now leads somewhere else. Refresh the folder and choose it again."
        case .timedOut: return "Preparing this export timed out. Try again."
        case .tooLarge(let limit):
            return "Too Large to Export. The limit is \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        }
    }
}

/// Streams original bytes into a private, short-lived directory. No preview decoder or
/// text normalization participates. `downloadFile` owns canonical root and symlink checks.
/// One transfer or prepared output may exist at a time; cancelling an uncooperative
/// transport does not permit a second transfer until the first has actually stopped.
public actor RemoteOriginalExporter {
    public static let maximumFileBytes = 128 * 1024 * 1024
    public static let maximumRetentionSeconds: TimeInterval = 10 * 60
    private struct Transfer {
        let id: UUID
        let directory: URL
        let task: Task<Void, Never>
        let deadline: Task<Void, Never>
        var continuation: CheckedContinuation<PreparedOriginalFile, Error>?
    }

    private let service: any RemoteFileService
    private let directory: URL
    private let fileLimit: Int
    private let retentionSeconds: TimeInterval
    private let timeoutSeconds: TimeInterval
    private let idleTimeout: Bool
    private var transfer: Transfer?
    private var prepared: PreparedOriginalFile?
    private var expiry: Task<Void, Never>?
    private var cleanedAbandonedFiles = false

    /// `directory` must be a dedicated directory owned by this exporter. With `idleTimeout`, a transfer is
    /// abandoned after `timeoutSeconds` without receiving bytes, rather than after that long in all, so a slow
    /// file still finishes; a stalled one still ends even if the transport ignores its own deadline. Time the
    /// transport reports queued for a channel (`TransferQueueing`) is not idle.
    public init(service: any RemoteFileService, directory: URL,
                fileLimit: Int = maximumFileBytes,
                retentionSeconds: TimeInterval = maximumRetentionSeconds,
                timeoutSeconds: TimeInterval = 180, idleTimeout: Bool = false) {
        self.service = service
        self.directory = directory
        self.fileLimit = min(max(1, fileLimit), Self.maximumFileBytes)
        self.retentionSeconds = min(max(0.01, retentionSeconds), Self.maximumRetentionSeconds)
        self.timeoutSeconds = min(max(0.01, timeoutSeconds), 180)
        self.idleTimeout = idleTimeout
    }

    deinit {
        expiry?.cancel()
        transfer?.deadline.cancel(); transfer?.task.cancel()
        transfer?.continuation?.resume(throwing: CancellationError())
        if let active = transfer { try? FileManager.default.removeItem(at: active.directory) }
        if let value = prepared { try? FileManager.default.removeItem(at: value.url.deletingLastPathComponent()) }
    }

    /// The selected name is retained even if an in-root symlink resolves to a different
    /// name. `allowedRoot` may be ".": the transport canonicalizes it on the server.
    public func prepare(profile: ConnectionProfile, entry: RemoteEntry,
                        allowedRoot: String, progress: @escaping DownloadProgressHandler = { _ in }) async throws -> PreparedOriginalFile {
        try Task.checkCancellation()
        guard transfer == nil, prepared == nil else { throw OriginalFileExportError.alreadyPreparing }
        guard entry.kind == .file || entry.kind == .symlink else { throw OriginalFileExportError.notRegularFile }
        guard Self.validFilename(entry.exportFilename ?? entry.name) else { throw OriginalFileExportError.invalidFilename }
        if let size = entry.size, size > UInt64(fileLimit) { throw OriginalFileExportError.tooLarge(fileLimit) }
        let id = UUID()
        let activity = ExportActivity()
        let reported = progress
        let progress: DownloadProgressHandler = { update in
            activity.received(update.receivedBytes)
            await reported(update)
        }
        let result: PreparedOriginalFile = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PreparedOriginalFile, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let temporaryDirectory = directory.appendingPathComponent(Self.processPrefix + id.uuidString, isDirectory: true)
                let task = Task {
                    let result: Result<PreparedOriginalFile, Error>
                    do {
                        result = .success(try await TransferQueueing.$observer.withValue({ activity.waiting($0) }) {
                            try await self.fetch(id: id, profile: profile, entry: entry,
                                                 allowedRoot: allowedRoot, directory: temporaryDirectory, progress: progress)
                        })
                    } catch {
                        result = .failure(Self.exportError(error))
                    }
                    self.finish(id: id, result: result)
                }
                let deadline = Task { [weak self, timeoutSeconds, idleTimeout] in
                    let interval = Duration.seconds(timeoutSeconds)
                    var until = ContinuousClock.now + interval
                    while true {
                        do { try await Task.sleep(until: until, clock: .continuous) }
                        catch { return }
                        guard idleTimeout else { break }
                        // Idle: wait on from the last bytes received, or the end of a wait for a channel, until a whole
                        // interval has passed without either. Time spent waiting for a channel never counts.
                        let now = ContinuousClock.now
                        guard let since = activity.idleSince else { until = now + interval; continue }
                        guard since + interval > now else { break }
                        until = since + interval
                    }
                    await self?.cancel(id: id, error: OriginalFileExportError.timedOut)
                }
                transfer = Transfer(id: id, directory: temporaryDirectory, task: task,
                                    deadline: deadline, continuation: continuation)
            }
        } onCancel: { Task { await self.cancel(id: id, error: CancellationError()) } }
        // Cancellation can arrive after the worker resumes its continuation.
        do { try Task.checkCancellation(); return result }
        catch { release(result.id); throw error }
    }

    public func release(_ id: UUID) {
        guard prepared?.id == id, let value = prepared else { return }
        expiry?.cancel(); expiry = nil; prepared = nil
        try? FileManager.default.removeItem(at: value.url.deletingLastPathComponent())
    }

    /// Used on leaving a reader, disconnect, and background. A late network completion
    /// cannot publish a file after cancellation, even if that transport ignores it.
    public func cancelAll() {
        if let id = transfer?.id { cancel(id: id, error: CancellationError()) }
        if let id = prepared?.id { release(id) }
    }

    /// Before replacing this exporter/service, disconnect the underlying service and
    /// await drainage so an old transfer cannot overlap a new exporter in this directory.
    public func cancelAndDrain() async {
        cancelAll()
        if let task = transfer?.task { await task.value }
    }

    private func cancel(id: UUID, error: Error) {
        if transfer?.id == id {
            let continuation = transfer?.continuation
            transfer?.continuation = nil
            transfer?.deadline.cancel()
            transfer?.task.cancel()
            if let temporaryDirectory = transfer?.directory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
            continuation?.resume(throwing: error)
        }
        release(id)
    }

    private func finish(id: UUID, result: Result<PreparedOriginalFile, Error>) {
        guard let active = transfer, active.id == id else { return }
        active.deadline.cancel(); transfer = nil
        guard let continuation = active.continuation, !active.task.isCancelled else {
            try? FileManager.default.removeItem(at: active.directory)
            active.continuation?.resume(throwing: CancellationError())
            return
        }
        switch result {
        case .success(let value):
            prepared = value
            expiry = Task { [weak self, retentionSeconds] in
                do { try await Task.sleep(for: .seconds(retentionSeconds)) }
                catch { return }
                await self?.release(id)
            }
            continuation.resume(returning: value)
        case .failure(let error):
            try? FileManager.default.removeItem(at: active.directory)
            continuation.resume(throwing: error)
        }
    }

    private func fetch(id: UUID, profile: ConnectionProfile, entry: RemoteEntry,
                       allowedRoot: String, directory temporaryDirectory: URL,
                       progress: @escaping DownloadProgressHandler) async throws -> PreparedOriginalFile {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Previous-process leftovers are never a cache and must not survive the next use. This process's
        // own are left alone: they belong to another window's exporter, or to this one's earlier self.
        if !cleanedAbandonedFiles {
            cleanedAbandonedFiles = true
            for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where Self.isAbandoned(child.lastPathComponent) {
                try? fm.removeItem(at: child)
            }
        }
        try fm.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var privateDirectory = temporaryDirectory; try privateDirectory.setResourceValues(excluded)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporaryDirectory.path)
        #endif
        let file = temporaryDirectory.appendingPathComponent(entry.exportFilename ?? entry.name, isDirectory: false)
        let remote: RemoteEntry
        if let root = entry.canonicalRoot {
            // An index may be built outside the connection's starting folder. Its
            // canonical boundary supplements, rather than replaces, export policy.
            let exportRoot = try await service.resolveEntry(profile: profile, path: allowedRoot)
            try Task.checkCancellation()
            guard exportRoot.kind == .directory,
                  RemoteResourcePath.contains(entry.path, in: exportRoot.path) else {
                throw OriginalFileExportError.outsideRoot
            }
            // This also verifies that entry.path is still the exact canonical path.
            remote = try await service.downloadSnapshotFile(profile: profile, path: entry.path, canonicalRoot: root,
                destination: file, limit: fileLimit, progress: progress)
        } else {
            remote = try await service.downloadFile(profile: profile, path: entry.path, allowedRoot: allowedRoot,
                destination: file, limit: fileLimit, progress: progress)
        }
        try Task.checkCancellation()
        guard remote.kind == .file else { throw OriginalFileExportError.notRegularFile }
        if let size = remote.size, size > UInt64(fileLimit) { throw OriginalFileExportError.tooLarge(fileLimit) }
        // Verify the final on-disk result too: metadata can be absent, stale, or smaller
        // than bytes received. The transport also checks the byte limit on every chunk.
        let attributes = try fm.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw OriginalFileExportError.notRegularFile }
        guard let count = attributes[.size] as? NSNumber, count.uint64Value <= UInt64(fileLimit) else {
            throw OriginalFileExportError.tooLarge(fileLimit)
        }
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        #endif
        return PreparedOriginalFile(id: id, url: file, filename: entry.exportFilename ?? entry.name, sourceFilename: remote.name,
                                    expiresAt: Date().addingTimeInterval(retentionSeconds))
    }

    /// Every exporter in this process shares the directory, one per window and a new one after each
    /// return from the background. The prefix tells their folders from a previous process's debris,
    /// so one window's first export doesn't delete the file another is writing or handing to Files.
    static let processPrefix = "export-" + UUID().uuidString + "-"
    static func isAbandoned(_ name: String) -> Bool {
        guard name.hasPrefix("export-"), !name.hasPrefix(processPrefix) else { return false }
        let parts = name.dropFirst(7)
        // "export-<id>" from older versions, or "export-<process>-<id>".
        if UUID(uuidString: String(parts)) != nil { return true }
        return parts.count == 73 && UUID(uuidString: String(parts.prefix(36))) != nil
            && parts.dropFirst(36).first == "-" && UUID(uuidString: String(parts.suffix(36))) != nil
    }

    private static func validFilename(_ value: String) -> Bool {
        !value.isEmpty && !RemotePath.isDotName(value) && !RemotePath.hasSeparator(value)
            && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || RemotePath.isDirectionControl($0) }
    }

    private static func exportError(_ error: Error) -> Error {
        if case RemoteFileError.tooLarge(let limit) = error { return OriginalFileExportError.tooLarge(limit) }
        if case RemoteFileError.unsupportedFile = error { return OriginalFileExportError.notRegularFile }
        if case RemoteResourceError.outsideDocument = error { return OriginalFileExportError.outsideRoot }
        return error
    }
}

/// When a transfer was last active: it started, received more bytes than before, or stopped waiting for a channel.
/// Progress can repeat a count; only growth counts.
private final class ExportActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private var at = ContinuousClock.now
    private var queued = false
    /// Where the idle interval runs from, or nil while the transfer waits for a channel.
    var idleSince: ContinuousClock.Instant? { lock.withLock { queued ? nil : at } }
    func received(_ total: UInt64) {
        lock.withLock { if total > bytes { bytes = total; at = .now } }
    }
    func waiting(_ value: Bool) {
        lock.withLock { queued = value; if !value { at = .now } }
    }
}
