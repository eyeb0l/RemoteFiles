import Foundation

/// What an upload does when its folder already holds the name.
public enum UploadConflictPolicy: String, Codable, Sendable {
    /// Leaves what is there alone and fails with `RemoteUploadError.destinationExists`.
    case fail
    /// Adds a number to the name until it is free.
    case keepBoth
    /// Replaces a regular file, in one step where the server can.
    case replace
}

/// The size and modification time of an upload's source when its bytes were read. A transfer continues
/// a partial copy only while its source still has the version that copy was written from.
public struct TransferSourceVersion: Hashable, Codable, Sendable {
    public let size: UInt64
    public let modifiedAt: Date?
    public init(size: UInt64, modifiedAt: Date?) { self.size = size; self.modifiedAt = modifiedAt }
    /// Without a modification time a changed source of the same size can't be told apart, so nothing continues.
    public var allowsResume: Bool { modifiedAt != nil }
}

/// Where an upload's bytes come from: a file on this device, or a file on another server.
public protocol TransferSource: Sendable {
    func describe() async throws -> TransferSourceVersion
    /// Exactly `count` bytes at `offset`, to compare with a partial copy before continuing it.
    func read(at offset: UInt64, count: Int) async throws -> Data
    /// Hands `sink` every byte from `offset` to the end, in order, waiting for each call to return.
    /// Throws `RemoteUploadError.sourceChanged` if the source no longer has `version`.
    func send(from offset: UInt64, expecting version: TransferSourceVersion,
              to sink: @escaping @Sendable (Data) async throws -> Void) async throws
}

public enum RemoteUploadError: LocalizedError, Equatable, Sendable {
    case destinationExists(String), destinationIsFolder(String), destinationMoved, invalidName, sourceChanged
    case sourceUnavailable, tooLarge(UInt64), refused, noFreeName(String)
    public var errorDescription: String? {
        switch self {
        case .destinationExists(let name): return "“\(RemotePath.displayName(name))” already exists in this folder. Replace it or keep both."
        case .destinationIsFolder(let name): return "A folder named “\(RemotePath.displayName(name))” is already there, and a file can’t replace a folder."
        case .destinationMoved: return "The destination folder has moved or now leads somewhere else. Open it again and retry."
        case .invalidName: return "This name can’t be used on the server."
        case .sourceChanged: return "The file changed while it was being transferred. Retry to send the current version."
        case .sourceUnavailable: return "The file to send is no longer on this device. Choose it again."
        case .tooLarge(let limit):
            return "Too large to transfer. The limit is \(ByteCountFormatter.string(fromByteCount: Int64(clamping: limit), countStyle: .file))."
        case .refused: return "The server couldn’t write this file. The folder may be read-only or out of space."
        case .noFreeName(let name): return "Couldn’t find a free name for “\(RemotePath.displayName(name))”. Rename or remove some copies first."
        }
    }
}

public struct UploadRequest: Sendable {
    /// The destination folder's canonical path. It must still resolve to exactly this path.
    public var directory: String
    public var name: String
    public var conflict: UploadConflictPolicy
    /// The hidden name the bytes are written under until they are complete. See `partialName(for:)`.
    public var partialName: String
    /// The source version an existing partial copy was written from, or nil to start again.
    public var resumeVersion: TransferSourceVersion?
    public var limit: UInt64
    public init(directory: String, name: String, conflict: UploadConflictPolicy, partialName: String,
                resumeVersion: TransferSourceVersion? = nil, limit: UInt64) {
        self.directory = directory; self.name = name; self.conflict = conflict
        self.partialName = partialName; self.resumeVersion = resumeVersion; self.limit = limit
    }

    static let partialPrefix = ".rf-upload-", partialSuffix = ".part", backupSuffix = ".old"
    /// One hidden name per transfer, so a retry finds its own bytes and never another transfer's.
    public static func partialName(for id: UUID) -> String { partialPrefix + id.uuidString.lowercased() + partialSuffix }
    /// Only names this app made are ever written over or removed as a partial copy.
    static func isPartialName(_ name: String) -> Bool {
        guard name.hasPrefix(partialPrefix), name.hasSuffix(partialSuffix) else { return false }
        return UUID(uuidString: String(name.dropFirst(partialPrefix.count).dropLast(partialSuffix.count))) != nil
    }
    /// A name a file may be given on a server: one path component the app can show and later open.
    public static func isValidName(_ name: String) -> Bool {
        RemotePath.isSingleName(name) && !name.utf8.contains(0) && !RemotePath.hasControlCharacter(name)
            && name.utf8.count <= 255 && !name.hasPrefix(partialPrefix)
    }
    /// `name`, then `name 2`, `name 3`…, each number going before the extension.
    static func numberedNames(for name: String, limit: Int = 100) -> [String] {
        let bytes = Array(name.utf8)
        // A leading full stop makes a hidden name, not an extension.
        let dot = bytes.lastIndex(of: 0x2E).flatMap { $0 > 0 ? $0 : nil }
        let stem = dot.map { String(decoding: bytes[..<$0], as: UTF8.self) } ?? name
        let ending = dot.map { String(decoding: bytes[$0...], as: UTF8.self) } ?? ""
        return [name] + (2...max(2, limit)).map { "\(stem) \($0)\(ending)" }.filter(isValidName)
    }
}

/// Called once the destination is open and before any byte is written: the source's version, and the
/// offset the transfer continues from (zero for a fresh one).
public typealias UploadStartHandler = @Sendable (_ version: TransferSourceVersion, _ offset: UInt64) async -> Void

/// Writes a file into a folder on a server. The bytes go to a hidden partial name in that folder and take
/// their real name only once every one of them is there, so nothing ever reads half a file under it.
public protocol RemoteFileUploading: Sendable {
    func uploadFile(profile: ConnectionProfile, request: UploadRequest, source: any TransferSource,
                    started: @escaping UploadStartHandler, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry
    /// Removes a partial copy this app left in `directory`, and puts back under `name` a file that an
    /// unfinished Replace had moved aside. A copy that is already gone is not an error.
    func removePartialUpload(profile: ConnectionProfile, directory: String, partialName: String, restoring name: String?) async throws
}

/// Reads a file for sending somewhere else. The root and the file must still resolve to exactly these
/// canonical paths, as for a saved-index download.
public protocol RemoteFileStreaming: Sendable {
    func transferVersion(profile: ConnectionProfile, path: String, canonicalRoot: String) async throws -> TransferSourceVersion
    func readFileRange(profile: ConnectionProfile, path: String, canonicalRoot: String, offset: UInt64, count: Int) async throws -> Data
    func streamFile(profile: ConnectionProfile, path: String, canonicalRoot: String, from offset: UInt64,
                    expecting version: TransferSourceVersion,
                    consume: @escaping @Sendable (Data) async throws -> Void) async throws
}

/// A file staged in the app's own storage.
public struct LocalFileTransferSource: TransferSource {
    public let url: URL
    /// Bytes read and handed on at a time.
    static let chunkBytes = 256 * 1024
    public init(url: URL) { self.url = url }

    public func describe() async throws -> TransferSourceVersion { try Self.version(of: url) }

    static func version(of url: URL) throws -> TransferSourceVersion {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { throw RemoteUploadError.sourceUnavailable }
        // Servers keep whole seconds, and so does the comparison with what a partial copy was written from.
        let modified = (attributes[.modificationDate] as? Date).map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        return TransferSourceVersion(size: size, modifiedAt: modified)
    }

    public func read(at offset: UInt64, count: Int) async throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw RemoteUploadError.sourceUnavailable }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let bytes = try handle.read(upToCount: count), bytes.count == count else { throw RemoteUploadError.sourceChanged }
        return bytes
    }

    public func send(from offset: UInt64, expecting version: TransferSourceVersion,
                     to sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw RemoteUploadError.sourceUnavailable }
        defer { try? handle.close() }
        guard try Self.version(of: url) == version, offset <= version.size else { throw RemoteUploadError.sourceChanged }
        try handle.seek(toOffset: offset)
        var remaining = version.size - offset
        while remaining > 0 {
            try Task.checkCancellation()
            let wanted = Int(min(UInt64(Self.chunkBytes), remaining))
            guard let bytes = try handle.read(upToCount: wanted), !bytes.isEmpty else { throw RemoteUploadError.sourceChanged }
            remaining -= UInt64(bytes.count)
            try await sink(bytes)
        }
    }
}

/// A file on a server, read over that server's own connection while another connection writes it.
public struct RemoteFileTransferSource: TransferSource {
    public let service: any RemoteFileStreaming
    public let profile: ConnectionProfile
    public let path: String
    public let canonicalRoot: String
    /// The channel a queue's copies from this server share, when its transport offers one.
    var batch: SnapshotTransferBatch?
    /// The file is on the server it is being copied to, over the same connection. A transport that can
    /// reads it over the channel it writes on, so the copy needs no second channel.
    var sameConnection = false
    public init(service: any RemoteFileStreaming, profile: ConnectionProfile, path: String, canonicalRoot: String) {
        self.service = service; self.profile = profile; self.path = path; self.canonicalRoot = canonicalRoot
    }
    public func describe() async throws -> TransferSourceVersion {
        try await service.transferVersion(profile: profile, path: path, canonicalRoot: canonicalRoot)
    }
    public func read(at offset: UInt64, count: Int) async throws -> Data {
        try await service.readFileRange(profile: profile, path: path, canonicalRoot: canonicalRoot, offset: offset, count: count)
    }
    public func send(from offset: UInt64, expecting version: TransferSourceVersion,
                     to sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        if let batch, let batched = service as? any BatchedStreaming {
            try await batched.streamFile(profile: profile, path: path, canonicalRoot: canonicalRoot, from: offset,
                                         expecting: version, batch: batch, consume: sink)
        } else {
            try await service.streamFile(profile: profile, path: path, canonicalRoot: canonicalRoot, from: offset,
                                         expecting: version, consume: sink)
        }
    }
}
