import Foundation

/// Shares an in-flight request for the same resource. Cancellation retires the shared request;
/// all its waiters observe cancellation, and the next explicit request starts fresh work.
public actor CoalescingFileService: RemoteFileService {
    private struct Key: Hashable { let profile: ConnectionProfile; let path: String; let limit: Int }
    private let base: any RemoteFileService
    private var lists: [Key: (UUID, Task<DirectorySnapshot, Error>)] = [:]
    private var reads: [Key: (UUID, Task<Data, Error>)] = [:]
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
    private func waiting<T: Sendable>(_ task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
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
    public func resolveDocumentLink(profile: ConnectionProfile, documentPath: String, reference: String) async throws -> RemoteEntry {
        try Task.checkCancellation()
        let entry = try await base.resolveDocumentLink(profile: profile, documentPath: documentPath, reference: reference)
        try Task.checkCancellation()
        return entry
    }
    public func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        try await base.downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit)
    }
    public func disconnect() async {
        lists.values.forEach { $0.1.cancel() }; reads.values.forEach { $0.1.cancel() }
        lists.removeAll(); reads.removeAll()
        await base.disconnect()
    }
}
