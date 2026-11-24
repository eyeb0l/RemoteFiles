import Foundation

/// What Demo's sample server has been sent: kept in memory for this run of the app, so an upload or copy
/// tried in Demo appears in its folder and opens, and nothing is written anywhere.
actor DemoUploads {
    static let shared = DemoUploads()
    /// Bytes kept for one uploaded file. A larger one is listed with its size and opens as too large.
    static let keptBytes = 8 * 1024 * 1024
    private var files: [RemotePathKey: (entry: RemoteEntry, bytes: Data?)] = [:]

    func store(_ entry: RemoteEntry, bytes: Data?) { files[RemotePathKey(entry.path)] = (entry, bytes) }
    func entry(at path: String) -> RemoteEntry? { files[RemotePathKey(path)]?.entry }
    /// Nil when nothing was uploaded there; `.some(nil)` when it was, and was too large to keep.
    func bytes(at path: String) -> Data?? { files[RemotePathKey(path)].map(\.bytes) }
    /// The sample folder with what was uploaded into it, an upload taking the place of a sample of its name.
    func merged(into snapshot: DirectorySnapshot) -> DirectorySnapshot {
        let added = files.values.map(\.entry).filter { RemotePath.parent(of: $0.path).utf8.elementsEqual(snapshot.path.utf8) }
        guard !added.isEmpty else { return snapshot }
        let replaced = Set(added.map { RemotePathKey($0.path) })
        return DirectorySnapshot(path: snapshot.path, entries: snapshot.entries.filter { !replaced.contains(RemotePathKey($0.path)) } + added)
    }
}

extension DemoRemoteFileService: RemoteFileUploading, RemoteFileStreaming {
    public func uploadFile(profile: ConnectionProfile, request: UploadRequest, source: any TransferSource,
                           started: @escaping UploadStartHandler, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        guard UploadRequest.isValidName(request.name) else { throw RemoteUploadError.invalidName }
        let version = try await source.describe()
        guard version.size <= request.limit else { throw RemoteUploadError.tooLarge(request.limit) }
        let folder = try await listDirectory(profile: profile, path: request.directory)
        guard folder.path == request.directory else { throw RemoteUploadError.destinationMoved }
        let taken = Dictionary(folder.entries.map { ($0.name, $0.effectiveKind) }, uniquingKeysWith: { first, _ in first })
        var name = request.name
        switch request.conflict {
        case .fail: if taken[name] != nil { throw RemoteUploadError.destinationExists(name) }
        case .keepBoth:
            guard let free = UploadRequest.numberedNames(for: name).first(where: { taken[$0] == nil }) else { throw RemoteUploadError.noFreeName(name) }
            name = free
        case .replace: if taken[name] == .directory { throw RemoteUploadError.destinationIsFolder(name) }
        }
        await started(version, 0)
        await progress(.init(totalBytes: version.size))
        let received = DemoReceivedBytes()
        let pause = min(delayNanoseconds, 60_000_000)
        try await source.send(from: 0, expecting: version) { chunk in
            try Task.checkCancellation()
            if pause > 0 { try await Task.sleep(nanoseconds: pause) }
            await progress(.init(receivedBytes: received.append(chunk), totalBytes: version.size))
        }
        try Task.checkCancellation()
        guard received.count == version.size else { throw RemoteUploadError.sourceChanged }
        let entry = RemoteEntry(name: name, path: RemotePath.appending(name, to: request.directory), kind: .file,
                                size: version.size, modifiedAt: version.modifiedAt ?? .now)
        await DemoUploads.shared.store(entry, bytes: received.kept)
        await progress(.init(receivedBytes: version.size, totalBytes: version.size, isComplete: true))
        return entry
    }

    /// Demo writes nothing until an upload is whole, so there is never a partial copy to remove.
    public func removePartialUpload(profile: ConnectionProfile, directory: String, partialName: String, restoring name: String?) async throws {}

    private func sampleBytes(profile: ConnectionProfile, path: String, canonicalRoot: String) async throws -> Data {
        guard RemoteResourcePath.contains(path, in: canonicalRoot),
              !(path.hasSuffix("/Latest report") || path.hasSuffix("/Current reports")) else { throw RemoteDocumentLinkError.outsideConnection }
        return try await readFile(profile: profile, path: path, limit: DemoUploads.keptBytes)
    }
    public func transferVersion(profile: ConnectionProfile, path: String, canonicalRoot: String) async throws -> TransferSourceVersion {
        let bytes = try await sampleBytes(profile: profile, path: path, canonicalRoot: canonicalRoot)
        return TransferSourceVersion(size: UInt64(bytes.count), modifiedAt: Date(timeIntervalSince1970: 1_790_035_200))
    }
    public func readFileRange(profile: ConnectionProfile, path: String, canonicalRoot: String, offset: UInt64, count: Int) async throws -> Data {
        let bytes = try await sampleBytes(profile: profile, path: path, canonicalRoot: canonicalRoot)
        guard offset + UInt64(count) <= UInt64(bytes.count) else { throw RemoteUploadError.sourceChanged }
        return bytes.subdata(in: Int(offset)..<Int(offset) + count)
    }
    public func streamFile(profile: ConnectionProfile, path: String, canonicalRoot: String, from offset: UInt64,
                           expecting version: TransferSourceVersion,
                           consume: @escaping @Sendable (Data) async throws -> Void) async throws {
        let bytes = try await sampleBytes(profile: profile, path: path, canonicalRoot: canonicalRoot)
        guard UInt64(bytes.count) == version.size, offset <= version.size else { throw RemoteUploadError.sourceChanged }
        let chunk = max(1, (bytes.count + 3) / 4)
        for start in stride(from: Int(offset), to: bytes.count, by: chunk) {
            try Task.checkCancellation()
            try await consume(bytes.subdata(in: start..<min(bytes.count, start + chunk)))
        }
    }
}

private final class DemoReceivedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data? = Data()
    private var total: UInt64 = 0
    var count: UInt64 { lock.withLock { total } }
    var kept: Data? { lock.withLock { bytes } }
    /// Returns the bytes received so far.
    func append(_ chunk: Data) -> UInt64 {
        lock.withLock {
            total += UInt64(chunk.count)
            if total > UInt64(DemoUploads.keptBytes) { bytes = nil } else { bytes?.append(chunk) }
            return total
        }
    }
}
