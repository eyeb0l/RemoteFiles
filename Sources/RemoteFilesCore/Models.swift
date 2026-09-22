import Foundation

public struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var identityID: UUID
    public var startingDirectory: String
    public var usesTailscale: Bool
    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
                identityID: UUID, startingDirectory: String = ".", usesTailscale: Bool = false) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.username = username; self.identityID = identityID
        self.startingDirectory = startingDirectory.isEmpty ? "." : startingDirectory
        self.usesTailscale = usesTailscale
    }
}

public struct RemoteEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case directory, file, symlink, other }
    public var id: String { path }
    public let name: String
    public let path: String
    public let kind: Kind
    public let size: UInt64?
    public let modifiedAt: Date?
    public init(name: String, path: String, kind: Kind, size: UInt64? = nil, modifiedAt: Date? = nil) {
        self.name = name; self.path = path; self.kind = kind; self.size = size; self.modifiedAt = modifiedAt
    }
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
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry
    func disconnect() async
}

public extension RemoteFileService {
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        throw RemoteFileError.unsupportedFile
    }
}

public enum RemoteFileError: LocalizedError, Sendable {
    case tooLarge(Int), unavailable(String), timedOut, invalidPath, unsupportedFile
    public var errorDescription: String? {
        switch self {
        case .tooLarge(let limit): return "Too Large to Preview. The limit is \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .unavailable(let message): return message
        case .timedOut: return "The connection timed out. Check the address, Mac availability, network permissions, and Tailscale connection if used."
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
