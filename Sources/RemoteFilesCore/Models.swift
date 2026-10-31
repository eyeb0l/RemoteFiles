import Foundation

public struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var identityID: UUID
    public var jumpHost: JumpHost?
    public var startingDirectory: String
    /// Only shows Tailscale setup tips in the connection editor; connections never route differently.
    /// The stored name is kept so saved profiles keep decoding.
    public var usesTailscale: Bool
    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
                identityID: UUID, startingDirectory: String = ".", usesTailscale: Bool = false, jumpHost: JumpHost? = nil) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.username = username; self.identityID = identityID
        self.startingDirectory = startingDirectory.isEmpty ? "." : startingDirectory
        self.usesTailscale = usesTailscale
        self.jumpHost = jumpHost
    }
}

/// One SSH bastion. The destination hostname is resolved by this server, through direct-tcpip.
/// No passwords or private key material are stored in the profile.
public struct JumpHost: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var identityID: UUID
    public init(host: String, port: Int = 22, username: String, identityID: UUID) {
        self.host = host; self.port = port; self.username = username; self.identityID = identityID
    }
}

public extension ConnectionProfile {
    var identityIDs: Set<UUID> { Set([identityID] + (jumpHost.map { [$0.identityID] } ?? [])) }
    /// Used by the editor and transport, including profiles loaded from disk.
    var hasValidSSHEndpoints: Bool {
        Self.validEndpoint(host: host, port: port, username: username) &&
        (jumpHost.map { Self.validEndpoint(host: $0.host, port: $0.port, username: $0.username) } ?? true)
    }
    private static func validEndpoint(host: String, port: Int, username: String) -> Bool {
        (1...65535).contains(port) && !host.isEmpty && !host.contains(where: { $0.isWhitespace || $0.isNewline }) &&
        !host.contains("/") && !host.contains("\0") && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.contains("\0")
    }
}

/// Identifies the locked key at either hop, so the UI never prompts for the other endpoint's key.
public struct ConnectionIdentityUnlockRequired: LocalizedError, Sendable {
    public let identity: IdentityMetadata
    public var errorDescription: String? { IdentityError.missingPassphrase.localizedDescription }
    public init(identity: IdentityMetadata) { self.identity = identity }
}

public struct RemoteEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case directory, file, symlink, other }
    public var id: String { path }
    public let name: String
    public let path: String
    public let kind: Kind
    public let size: UInt64?
    public let modifiedAt: Date?
    /// Present only for a user-tapped document link; rechecked by every reader fetch.
    public let navigationRoot: String?
    /// For saved search results, retain the exact canonical folder used to build the index.
    public let canonicalRoot: String?
    /// The tapped alias name, retained for exporting the original after canonical resolution.
    public let exportFilename: String?
    /// A user-tapped heading link; never part of the remote filesystem path.
    public let headingFragment: String?
    /// One-based PDF page from a search result, opened once instead of the saved reading position.
    public let openingPage: Int?
    /// For a symbolic link resolved while listing; nil when it was not resolved.
    public let link: LinkResolution?
    public init(name: String, path: String, kind: Kind, size: UInt64? = nil, modifiedAt: Date? = nil, navigationRoot: String? = nil,
                exportFilename: String? = nil, link: LinkResolution? = nil, canonicalRoot: String? = nil) {
        self.name = name; self.path = path; self.kind = kind; self.size = size; self.modifiedAt = modifiedAt
        self.navigationRoot = navigationRoot; self.exportFilename = exportFilename
        self.canonicalRoot = canonicalRoot
        self.headingFragment = nil; self.openingPage = nil; self.link = link
    }
    public func openingHeading(_ fragment: String) -> RemoteEntry {
        RemoteEntry(copying: self, headingFragment: fragment, openingPage: nil)
    }
    /// A one-based page; values outside 1...Int32.max are ignored rather than clamped.
    public func openingPage(_ page: Int?) -> RemoteEntry {
        RemoteEntry(copying: self, headingFragment: headingFragment,
                    openingPage: page.flatMap { (1...Int(Int32.max)).contains($0) ? $0 : nil })
    }
    private init(copying entry: RemoteEntry, headingFragment: String?, openingPage: Int?) {
        name = entry.name; path = entry.path; kind = entry.kind; size = entry.size; modifiedAt = entry.modifiedAt
        navigationRoot = entry.navigationRoot; exportFilename = entry.exportFilename; link = entry.link
        canonicalRoot = entry.canonicalRoot
        self.headingFragment = headingFragment; self.openingPage = openingPage
    }
    /// The resolved target of a symbolic link, if any.
    public var linkTarget: RemoteEntry? {
        if case .target(let target) = link { return target }
        return nil
    }
    /// What this entry behaves as: a resolved link takes its target's kind.
    public var effectiveKind: Kind { linkTarget?.kind ?? kind }
    /// The canonical target to open for a resolved link, keeping the link's own name for export.
    public func followingLink() -> RemoteEntry? {
        guard let target = linkTarget else { return nil }
        return RemoteEntry(name: target.name, path: target.path, kind: target.kind, size: target.size,
                           modifiedAt: target.modifiedAt, exportFilename: name)
    }
}

/// What a symbolic link pointed to when its folder was listed. Like the listing itself, it can be
/// stale; opening the target reads the server again.
public indirect enum LinkResolution: Hashable, Sendable {
    /// The canonical target, with its own kind, size and modification time.
    case target(RemoteEntry)
    /// The target is missing, or the link is part of a loop.
    case broken
}

/// Size and modification time observed when a file's bytes were read. SFTP v3 reports whole
/// seconds, so a same-size rewrite within one second looks unchanged; explicit refreshes always read.
public struct RemoteFileVersion: Hashable, Sendable {
    public let size: UInt64
    public let modifiedAt: Date
    public init?(size: UInt64?, modifiedAt: Date?) {
        guard let size, let modifiedAt else { return nil }
        self.size = size; self.modifiedAt = modifiedAt
    }
}

public enum RemoteFileRead: Sendable {
    case unchanged
    case contents(Data, RemoteFileVersion?)
}

public struct DirectorySnapshot: Sendable {
    public let path: String
    public let entries: [RemoteEntry]
    public init(path: String, entries: [RemoteEntry]) { self.path = path; self.entries = entries }
}

public struct SavedLocation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var connectionID: UUID
    public var path: String
    public var name: String
    public var visitedAt: Date
    public init(id: UUID = UUID(), connectionID: UUID, path: String, name: String, visitedAt: Date = .now) {
        self.id = id; self.connectionID = connectionID; self.path = path; self.name = name; self.visitedAt = visitedAt
    }
}

public protocol RemoteFileService: Sendable {
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry
    func readDocumentFile(profile: ConnectionProfile, path: String, allowedRoot: String, limit: Int) async throws -> Data
    /// Search roots are already canonical: reject a root redirected since the listing was read.
    func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data
    /// Returns `.unchanged` without transferring bytes when `since` still matches the file.
    /// A non-nil `allowedRoot` applies the same canonical confinement as `readDocumentFile`.
    func readFileIfChanged(profile: ConnectionProfile, path: String, allowedRoot: String?, limit: Int, since: RemoteFileVersion?) async throws -> RemoteFileRead
    func resolveDocumentLink(profile: ConnectionProfile, documentPath: String, reference: String) async throws -> RemoteEntry
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry
    /// Snapshot roots and files are already canonical. Reject redirects rather than following a
    /// link that appeared after traversal. Adapters opt in to this stronger download contract.
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry
    func disconnect() async
}

public extension RemoteFileService {
    /// Indexed results must recheck the original canonical boundary, including on refresh.
    /// Ordinary navigation keeps its existing conditional-read and document-link behavior.
    func readFileIfChanged(profile: ConnectionProfile, entry: RemoteEntry, limit: Int,
                           since: RemoteFileVersion?) async throws -> RemoteFileRead {
        if let root = entry.canonicalRoot {
            return .contents(try await readSearchFile(profile: profile, path: entry.path, canonicalRoot: root, limit: limit), nil)
        }
        return try await readFileIfChanged(profile: profile, path: entry.path, allowedRoot: entry.navigationRoot,
                                          limit: limit, since: since)
    }
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        throw RemoteFileError.unsupportedFile
    }
    /// Older adapters can finish without chunk progress. Read the actual local size at completion.
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL,
                      limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        let entry = try await downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit)
        try Task.checkCancellation()
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        await progress(.init(receivedBytes: UInt64(size), totalBytes: UInt64(size), isComplete: true))
        return entry
    }
    func readDocumentFile(profile: ConnectionProfile, path: String, allowedRoot: String, limit: Int) async throws -> Data {
        throw RemoteFileError.unsupportedFile
    }
    func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data {
        // Adapters must opt in to preserving the original canonical boundary, not just a root alias.
        throw RemoteFileError.unsupportedFile
    }
    /// Adapters without file versions always transfer the bytes.
    func readFileIfChanged(profile: ConnectionProfile, path: String, allowedRoot: String?, limit: Int, since: RemoteFileVersion?) async throws -> RemoteFileRead {
        if let allowedRoot {
            return .contents(try await readDocumentFile(profile: profile, path: path, allowedRoot: allowedRoot, limit: limit), nil)
        }
        return .contents(try await readFile(profile: profile, path: path, limit: limit), nil)
    }
    /// Adapters must opt in with canonical connection-root confinement.
    func resolveDocumentLink(profile: ConnectionProfile, documentPath: String, reference: String) async throws -> RemoteEntry {
        throw RemoteFileError.unsupportedFile
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        throw RemoteFileError.unsupportedFile
    }
}

public enum RemoteFileError: LocalizedError, Sendable {
    case tooLarge(Int), unavailable(String), notFound, permissionDenied, connectionEnded, timedOut, invalidPath, unsupportedFile
    public var errorDescription: String? {
        switch self {
        case .tooLarge(let limit): return "Too Large to Preview. The limit is \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .unavailable(let message): return message
        case .notFound: return "This file or folder no longer exists at that path. Refresh the folder and try again."
        case .permissionDenied: return "Permission denied. This account cannot read that location on the server."
        case .connectionEnded: return "The SSH connection ended. Refresh to reconnect."
        case .timedOut: return "The connection timed out. Check the address, server availability, network permissions, and Tailscale connection if used."
        case .invalidPath: return "This remote path cannot be resolved."
        case .unsupportedFile: return "Preview is not available for this file type."
        }
    }
}

public enum RemotePath {
    public static func appending(_ name: String, to parent: String) -> String {
        parent == "/" ? "/" + name : parent.trimmingCharacters(in: CharacterSet(charactersIn: "/")) .withLeadingSlash(if: parent.hasPrefix("/")) + "/" + name
    }
    public static func parent(of path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return "/" + parts.joined(separator: "/")
    }
    public static func name(of path: String) -> String { path.split(separator: "/").last.map(String.init) ?? "/" }
}
private extension String {
    func withLeadingSlash(if condition: Bool) -> String { condition ? "/" + self : self }
}
