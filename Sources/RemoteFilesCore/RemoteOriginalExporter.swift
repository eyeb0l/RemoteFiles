import Foundation

/// An unmodified remote file owned by one export presentation. The URL is temporary:
/// consumers must release it after the system picker finishes or is dismissed.
public struct PreparedOriginalFile: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let filename: String
    public let expiresAt: Date
}

public enum OriginalFileExportError: LocalizedError, Sendable {
    case alreadyPreparing, invalidFilename, notRegularFile, outsideRoot, timedOut, tooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .alreadyPreparing: return "Finish or cancel the current export before preparing another file."
        case .invalidFilename: return "This filename cannot be saved safely on this device."
        case .notRegularFile: return "Only regular files can be exported."
        case .outsideRoot: return "This file resolves outside the connection’s starting folder."
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
    private var transfer: Transfer?
    private var prepared: PreparedOriginalFile?
    private var expiry: Task<Void, Never>?
    private var cleanedAbandonedFiles = false

    /// `directory` must be a dedicated directory owned by this exporter.
    public init(service: any RemoteFileService, directory: URL,
                fileLimit: Int = maximumFileBytes,
                retentionSeconds: TimeInterval = maximumRetentionSeconds,
                timeoutSeconds: TimeInterval = 180) {
        self.service = service
        self.directory = directory
        self.fileLimit = min(max(1, fileLimit), Self.maximumFileBytes)
        self.retentionSeconds = min(max(0.01, retentionSeconds), Self.maximumRetentionSeconds)
        self.timeoutSeconds = min(max(0.01, timeoutSeconds), 180)
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
                        allowedRoot: String) async throws -> PreparedOriginalFile {
        try Task.checkCancellation()
        guard transfer == nil, prepared == nil else { throw OriginalFileExportError.alreadyPreparing }
        guard entry.kind == .file || entry.kind == .symlink else { throw OriginalFileExportError.notRegularFile }
        guard Self.validFilename(entry.exportFilename ?? entry.name) else { throw OriginalFileExportError.invalidFilename }
        if let size = entry.size, size > UInt64(fileLimit) { throw OriginalFileExportError.tooLarge(fileLimit) }
        let id = UUID()
        let result: PreparedOriginalFile = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PreparedOriginalFile, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let temporaryDirectory = directory.appendingPathComponent("export-" + id.uuidString, isDirectory: true)
                let task = Task {
                    let result: Result<PreparedOriginalFile, Error>
                    do {
                        result = .success(try await self.fetch(id: id, profile: profile, entry: entry,
                                                              allowedRoot: allowedRoot, directory: temporaryDirectory))
                    } catch {
                        result = .failure(Self.exportError(error))
                    }
                    self.finish(id: id, result: result)
                }
                let deadline = Task { [weak self, timeoutSeconds] in
                    do { try await Task.sleep(for: .seconds(timeoutSeconds)) }
                    catch { return }
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
                       allowedRoot: String, directory temporaryDirectory: URL) async throws -> PreparedOriginalFile {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Previous-process leftovers are never a cache and must not survive the next use.
        if !cleanedAbandonedFiles {
            cleanedAbandonedFiles = true
            for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if child.lastPathComponent.hasPrefix("export-"),
                   UUID(uuidString: String(child.lastPathComponent.dropFirst(7))) != nil {
                    try? fm.removeItem(at: child)
                }
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
        let remote = try await service.downloadFile(profile: profile, path: entry.path, allowedRoot: allowedRoot,
                                                    destination: file, limit: fileLimit)
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
        return PreparedOriginalFile(id: id, url: file, filename: entry.exportFilename ?? entry.name,
                                    expiresAt: Date().addingTimeInterval(retentionSeconds))
    }

    private static func validFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
            && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func exportError(_ error: Error) -> Error {
        if case RemoteFileError.tooLarge(let limit) = error { return OriginalFileExportError.tooLarge(limit) }
        if case RemoteFileError.unsupportedFile = error { return OriginalFileExportError.notRegularFile }
        if case RemoteResourceError.outsideDocument = error { return OriginalFileExportError.outsideRoot }
        return error
    }
}
