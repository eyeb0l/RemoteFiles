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
    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("//") && (path == "/" || !path.hasSuffix("/")) &&
        !path.contains("\\") && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) &&
        !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) && !path.contains("//")
    }
}
