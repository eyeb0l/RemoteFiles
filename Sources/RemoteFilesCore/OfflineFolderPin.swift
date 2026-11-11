import Foundation

/// One complete, manually refreshed tree. File bytes use the same protected store as single pins.
public struct OfflineFolderPin: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let connectionID: UUID
    public let connectionName: String
    public let routeKey: String
    public let path: String
    public let name: String
    public let savedAt: Date
    public let includeHidden: Bool
    public let directories: [String]
    public let fileIDs: [UUID]
    public let skippedLinks: Int
    public let skippedOtherEntries: Int
    /// Files left out because their name can't name a file on this device, such as one holding a backslash.
    /// Missing in what earlier versions saved, which never left a file out for its name.
    public let skippedNames: Int

    public init(id: UUID, connectionID: UUID, connectionName: String, routeKey: String, path: String, name: String,
                savedAt: Date, includeHidden: Bool, directories: [String], fileIDs: [UUID],
                skippedLinks: Int, skippedOtherEntries: Int, skippedNames: Int = 0) {
        self.id = id; self.connectionID = connectionID; self.connectionName = connectionName; self.routeKey = routeKey
        self.path = path; self.name = name; self.savedAt = savedAt; self.includeHidden = includeHidden
        self.directories = directories; self.fileIDs = fileIDs
        self.skippedLinks = skippedLinks; self.skippedOtherEntries = skippedOtherEntries; self.skippedNames = skippedNames
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), connectionID: try values.decode(UUID.self, forKey: .connectionID),
                  connectionName: try values.decode(String.self, forKey: .connectionName),
                  routeKey: try values.decode(String.self, forKey: .routeKey), path: try values.decode(String.self, forKey: .path),
                  name: try values.decode(String.self, forKey: .name), savedAt: try values.decode(Date.self, forKey: .savedAt),
                  includeHidden: try values.decode(Bool.self, forKey: .includeHidden),
                  directories: try values.decode([String].self, forKey: .directories),
                  fileIDs: try values.decode([UUID].self, forKey: .fileIDs),
                  skippedLinks: try values.decode(Int.self, forKey: .skippedLinks),
                  skippedOtherEntries: try values.decode(Int.self, forKey: .skippedOtherEntries),
                  skippedNames: try values.decodeIfPresent(Int.self, forKey: .skippedNames) ?? 0)
    }

    public func matches(_ profile: ConnectionProfile, path: String) -> Bool {
        connectionID == profile.id && routeKey == OfflinePin.routeKey(profile) && self.path.utf8.elementsEqual(path.utf8)
    }
}

public struct OfflineFolderLimits: Sendable {
    public let depth: Int
    public let directories: Int
    public let entries: Int
    public let seconds: UInt64
    public init(depth: Int = 16, directories: Int = 256, entries: Int = 10_000, seconds: UInt64 = 600) {
        self.depth = min(16, max(0, depth))
        self.directories = min(256, max(1, directories))
        self.entries = min(10_000, max(1, entries))
        self.seconds = min(600, max(1, seconds))
    }
}

public struct OfflineFolderProgress: Sendable {
    public var folders = 0
    public var files = 0
    public var currentFile: String?
    public var bytes: UInt64 = 0
    public var skippedLinks = 0
    public init() {}
}
public typealias OfflineFolderProgressHandler = @Sendable (OfflineFolderProgress) async -> Void

public struct OfflineLibrarySnapshot: Sendable {
    public let files: [OfflinePin]
    public let folders: [OfflineFolderPin]
}

extension OfflineFolderPin {
    /// A remote path as the server names it. A backslash is a byte of a name to the server, as in a file copied
    /// from Windows, so it is allowed here; only a name that becomes a file on this device refuses it
    /// (`OfflineFileStore.validFilename`), as a link's reference does (`RemoteDocumentLinkPath`).
    static func validPath(_ path: String) -> Bool {
        // By bytes: a slash beside a combining mark is still a slash to the server.
        RemotePath.isAbsolute(path) && !RemotePath.hasDoubledSeparator(path) &&
        (path.utf8.elementsEqual("/".utf8) || !RemotePath.endsWithSeparator(path)) &&
        !RemotePath.components(of: path).contains(where: RemotePath.isDotName) &&
        !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }
}
