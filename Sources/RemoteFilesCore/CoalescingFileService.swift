import Foundation

/// Shares an in-flight request for the same resource. Cancellation retires the shared request;
/// all its waiters observe cancellation, and the next explicit request starts fresh work.
public actor CoalescingFileService: RemoteFileService {
    private struct Key: Hashable { let profile: ConnectionProfile; let path: String; let limit: Int }
    private struct VersionedKey: Hashable { let read: Key; let allowedRoot: String?; let since: RemoteFileVersion? }
    /// The wrapped service, for background work that must neither join nor cancel others' requests.
    public nonisolated let base: any RemoteFileService
    private var lists: [Key: (UUID, Task<DirectorySnapshot, Error>)] = [:]
    private var reads: [Key: (UUID, Task<Data, Error>)] = [:]
    private var versionedReads: [VersionedKey: (UUID, Task<RemoteFileRead, Error>)] = [:]
    public init(base: any RemoteFileService) { self.base = base }
    public func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        try Task.checkCancellation()
        let key = Key(profile: profile, path: path, limit: 0)
        if let (_, task) = lists[key], !task.isCancelled { return try await waiting(task) }
        let id = UUID()
        let task = Task { try await base.listDirectory(profile: profile, path: path) }
        lists[key] = (id, task)
        defer { if lists[key]?.0 == id { lists[key] = nil } }
        return try await waiting(task)
    }
    public func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        let key = Key(profile: profile, path: path, limit: limit)
        if let (_, task) = reads[key], !task.isCancelled { return try await waiting(task) }
        let id = UUID()
        let task = Task { try await base.readFile(profile: profile, path: path, limit: limit) }
        reads[key] = (id, task)
        defer { if reads[key]?.0 == id { reads[key] = nil } }
        return try await waiting(task)
    }
    public func readFileIfChanged(profile: ConnectionProfile, path: String, allowedRoot: String?, limit: Int, since: RemoteFileVersion?) async throws -> RemoteFileRead {
        try Task.checkCancellation()
        let key = VersionedKey(read: Key(profile: profile, path: path, limit: limit), allowedRoot: allowedRoot, since: since)
        if let (_, task) = versionedReads[key], !task.isCancelled { return try await waiting(task) }
        let id = UUID()
        let task = Task { try await base.readFileIfChanged(profile: profile, path: path, allowedRoot: allowedRoot, limit: limit, since: since) }
        versionedReads[key] = (id, task)
        defer { if versionedReads[key]?.0 == id { versionedReads[key] = nil } }
        return try await waiting(task)
    }
    private func waiting<T: Sendable>(_ task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            // A transport can finish successfully while its cancellation is draining.
            // Disconnect retires the shared task even when its callers remain alive.
            guard !task.isCancelled else { throw CancellationError() }
            return result
        } onCancel: { task.cancel() }
    }
    public func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        try Task.checkCancellation()
        return try await base.resolveEntry(profile: profile, path: path)
    }
    public func readDocumentFile(profile: ConnectionProfile, path: String, allowedRoot: String, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        let bytes = try await base.readDocumentFile(profile: profile, path: path, allowedRoot: allowedRoot, limit: limit)
        try Task.checkCancellation()
        return bytes
    }
    public func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        // Search cancellation must never cancel a foreground preview of the same file.
        let bytes = try await base.readSearchFile(profile: profile, path: path, canonicalRoot: canonicalRoot, limit: limit)
        try Task.checkCancellation()
        return bytes
    }
    public func resolveDocumentLink(profile: ConnectionProfile, documentPath: String, reference: String) async throws -> RemoteEntry {
        try Task.checkCancellation()
        let entry = try await base.resolveDocumentLink(profile: profile, documentPath: documentPath, reference: reference)
        try Task.checkCancellation()
        return entry
    }
    public func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        try await base.downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit)
    }
    public func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL,
                             limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await base.downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit, progress: progress)
    }
    public func disconnect() async {
        lists.values.forEach { $0.1.cancel() }; reads.values.forEach { $0.1.cancel() }
        versionedReads.values.forEach { $0.1.cancel() }
        lists.removeAll(); reads.removeAll(); versionedReads.removeAll()
        await base.disconnect()
    }
}
