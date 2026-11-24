import Foundation

/// Closes one server's connection and leaves the others open.
public protocol HostSessionClosing: Sendable {
    /// Closes the connection used for `connectionID`, if there is one, without locking any key.
    func closeSession(of connectionID: UUID) async
}

/// Keeps a connection for each server, so opening a second server leaves the first connected, and a file
/// can be read from one while it is written to another.
///
/// Each server has its own `SFTPRemoteFileService`, which still holds exactly one session: everything that
/// service guarantees about channels, deadlines and cancellation holds per server, and one server's stalled
/// request never waits on another's actor. Requests are routed by the connection's identifier, so an edited
/// connection replaces its own session and no other.
public final class MultiHostFileService: RemoteFileService, ProgressiveFolderListing, FolderWalking, BackgroundFolderListing,
    ServerFolderSearching, RemoteFileSessionClosing, HostSessionClosing, ResumableManagedDownloading, HostKeyAttesting,
    SnapshotBatchDownloading, BatchedUploading, BatchedStreaming, @unchecked Sendable {
    private let make: @Sendable () -> SFTPRemoteFileService
    private let lock = NSLock()
    private var hosts: [UUID: SFTPRemoteFileService] = [:]
    /// Which server each folder save's shared channel belongs to; a batch ends without naming its connection.
    private var batches: [ObjectIdentifier: SFTPRemoteFileService] = [:]

    public init(make: @escaping @Sendable () -> SFTPRemoteFileService) { self.make = make }

    public convenience init(identityStore: IdentityStore, trustStore: HostTrustStore, metadataStore: MetadataStore) {
        self.init { SFTPRemoteFileService(identityStore: identityStore, trustStore: trustStore, metadataStore: metadataStore) }
    }

    /// The servers that have been used and not closed since.
    public var connectionIDs: Set<UUID> { lock.withLock { Set(hosts.keys) } }

    func host(_ profile: ConnectionProfile) -> SFTPRemoteFileService {
        lock.withLock {
            if let existing = hosts[profile.id] { return existing }
            let created = make()
            hosts[profile.id] = created
            return created
        }
    }
    private func existing(_ id: UUID) -> SFTPRemoteFileService? { lock.withLock { hosts[id] } }
    private func removeAll() -> [SFTPRemoteFileService] {
        lock.withLock {
            let all = Array(hosts.values)
            hosts.removeAll(); batches.removeAll()
            return all
        }
    }

    // MARK: Sessions

    public func disconnect() async {
        let all = removeAll()
        // Each one locks the shared keys; with nothing connected that still has to happen once.
        if all.isEmpty { await make().disconnect() }
        for service in all { await service.disconnect() }
    }
    public func closeSessionPreservingUnlockedIdentities() async {
        for service in removeAll() { await service.closeSessionPreservingUnlockedIdentities() }
    }
    public func closeSession(of connectionID: UUID) async {
        let service = lock.withLock { hosts.removeValue(forKey: connectionID) }
        await service?.closeSessionPreservingUnlockedIdentities()
    }

    // MARK: Browsing and reading

    public func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        try await host(profile).listDirectory(profile: profile, path: path)
    }
    public func listDirectory(profile: ConnectionProfile, path: String,
                              partial: @escaping @Sendable (DirectorySnapshot) -> Void) async throws -> DirectorySnapshot {
        try await host(profile).listDirectory(profile: profile, path: path, partial: partial)
    }
    func listDirectoryForWalk(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        try await host(profile).listDirectoryForWalk(profile: profile, path: path)
    }
    func resolvingLinks(in entries: [RemoteEntry], profile: ConnectionProfile) async throws -> [RemoteEntry] {
        try await host(profile).resolvingLinks(in: entries, profile: profile)
    }
    /// Never opens a connection: a server that hasn't been used has nothing to check a folder over.
    public func listDirectoryInBackground(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot? {
        guard let service = existing(profile.id) else { return nil }
        return try await service.listDirectoryInBackground(profile: profile, path: path)
    }
    func searchFolders(query: String, root: String, profile: ConnectionProfile, includeHidden: Bool,
                       limits: RemoteFolderSearch.Limits, content: RemoteFolderSearch.ContentLimits?,
                       partial: @escaping @Sendable (RemoteFolderSearch.Update) -> Void) async throws -> RemoteFolderSearch.Update? {
        try await host(profile).searchFolders(query: query, root: root, profile: profile, includeHidden: includeHidden,
                                              limits: limits, content: content, partial: partial)
    }
    public func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        try await host(profile).readFile(profile: profile, path: path, limit: limit)
    }
    public func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        try await host(profile).resolveEntry(profile: profile, path: path)
    }
    public func readDocumentFile(profile: ConnectionProfile, path: String, allowedRoot: String, limit: Int) async throws -> Data {
        try await host(profile).readDocumentFile(profile: profile, path: path, allowedRoot: allowedRoot, limit: limit)
    }
    public func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data {
        try await host(profile).readSearchFile(profile: profile, path: path, canonicalRoot: canonicalRoot, limit: limit)
    }
    public func readFileIfChanged(profile: ConnectionProfile, path: String, allowedRoot: String?, limit: Int,
                                  since: RemoteFileVersion?) async throws -> RemoteFileRead {
        try await host(profile).readFileIfChanged(profile: profile, path: path, allowedRoot: allowedRoot, limit: limit, since: since)
    }
    public func resolveDocumentLink(profile: ConnectionProfile, documentPath: String, reference: String) async throws -> RemoteEntry {
        try await host(profile).resolveDocumentLink(profile: profile, documentPath: documentPath, reference: reference)
    }

    // MARK: Downloads

    public func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        try await host(profile).downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit)
    }
    public func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int,
                             progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await host(profile).downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination,
                                             limit: limit, progress: progress)
    }
    public func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                                     limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await host(profile).downloadSnapshotFile(profile: profile, path: path, canonicalRoot: canonicalRoot,
                                                     destination: destination, limit: limit, progress: progress)
    }
    public func downloadManagedFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int,
                                    progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await host(profile).downloadManagedFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination,
                                                    limit: limit, progress: progress)
    }
    public func downloadManagedSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                                            limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await host(profile).downloadManagedSnapshotFile(profile: profile, path: path, canonicalRoot: canonicalRoot,
                                                            destination: destination, limit: limit, progress: progress)
    }
    public func downloadManagedFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int,
                                    resumeVersion: RemoteFileVersion?, started: @escaping ManagedDownloadStartHandler,
                                    progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await host(profile).downloadManagedFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination,
                                                    limit: limit, resumeVersion: resumeVersion, started: started, progress: progress)
    }
    public func downloadManagedSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL, limit: Int,
                                            resumeVersion: RemoteFileVersion?, started: @escaping ManagedDownloadStartHandler,
                                            progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await host(profile).downloadManagedSnapshotFile(profile: profile, path: path, canonicalRoot: canonicalRoot, destination: destination,
                                                            limit: limit, resumeVersion: resumeVersion, started: started, progress: progress)
    }
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL, limit: Int,
                              batch: SnapshotTransferBatch, overlapped: Bool, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        let service = host(profile)
        lock.withLock { batches[ObjectIdentifier(batch)] = service }
        return try await service.downloadSnapshotFile(profile: profile, path: path, canonicalRoot: canonicalRoot, destination: destination,
                                                      limit: limit, batch: batch, overlapped: overlapped, progress: progress)
    }
    func endSnapshotBatch(_ batch: SnapshotTransferBatch) async {
        let service = lock.withLock { batches.removeValue(forKey: ObjectIdentifier(batch)) }
        await service?.endSnapshotBatch(batch)
    }
    public func trustedHostKeys(for profile: ConnectionProfile) async -> ServerHostKeys? {
        await host(profile).trustedHostKeys(for: profile)
    }
    public func attestedDownloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int,
                                     progress: @escaping DownloadProgressHandler) async throws -> AttestedDownload {
        try await host(profile).attestedDownloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination,
                                                     limit: limit, progress: progress)
    }
    public func attestedDownloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL, limit: Int,
                                             progress: @escaping DownloadProgressHandler) async throws -> AttestedDownload {
        try await host(profile).attestedDownloadSnapshotFile(profile: profile, path: path, canonicalRoot: canonicalRoot, destination: destination,
                                                             limit: limit, progress: progress)
    }

    // MARK: Uploads and copies

    public func uploadFile(profile: ConnectionProfile, request: UploadRequest, source: any TransferSource,
                           started: @escaping UploadStartHandler, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await host(profile).uploadFile(profile: profile, request: request, source: source, started: started, progress: progress)
    }
    func uploadFile(profile: ConnectionProfile, request: UploadRequest, source: any TransferSource, batch: SnapshotTransferBatch,
                    started: @escaping UploadStartHandler, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        let service = host(profile)
        lock.withLock { batches[ObjectIdentifier(batch)] = service }
        return try await service.uploadFile(profile: profile, request: request, source: source, batch: batch, started: started, progress: progress)
    }
    public func removePartialUpload(profile: ConnectionProfile, directory: String, partialName: String, restoring name: String?) async throws {
        try await host(profile).removePartialUpload(profile: profile, directory: directory, partialName: partialName, restoring: name)
    }
    public func transferVersion(profile: ConnectionProfile, path: String, canonicalRoot: String) async throws -> TransferSourceVersion {
        try await host(profile).transferVersion(profile: profile, path: path, canonicalRoot: canonicalRoot)
    }
    public func readFileRange(profile: ConnectionProfile, path: String, canonicalRoot: String, offset: UInt64, count: Int) async throws -> Data {
        try await host(profile).readFileRange(profile: profile, path: path, canonicalRoot: canonicalRoot, offset: offset, count: count)
    }
    public func streamFile(profile: ConnectionProfile, path: String, canonicalRoot: String, from offset: UInt64,
                           expecting version: TransferSourceVersion,
                           consume: @escaping @Sendable (Data) async throws -> Void) async throws {
        try await host(profile).streamFile(profile: profile, path: path, canonicalRoot: canonicalRoot, from: offset,
                                           expecting: version, consume: consume)
    }
    func streamFile(profile: ConnectionProfile, path: String, canonicalRoot: String, from offset: UInt64,
                    expecting version: TransferSourceVersion, batch: SnapshotTransferBatch?,
                    consume: @escaping @Sendable (Data) async throws -> Void) async throws {
        let service = host(profile)
        if let batch { lock.withLock { batches[ObjectIdentifier(batch)] = service } }
        try await service.streamFile(profile: profile, path: path, canonicalRoot: canonicalRoot, from: offset,
                                     expecting: version, batch: batch, consume: consume)
    }
}
