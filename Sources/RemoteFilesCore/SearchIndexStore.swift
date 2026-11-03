import Foundation
import Crypto
import Darwin

public struct SearchIndexDocument: Sendable {
    public let entry: RemoteEntry
    public let segments: [SearchTextSegment]
    /// Whether extraction stopped at a text or page limit; nil for indexes saved before this was recorded.
    public let isTruncated: Bool?
    public init(entry: RemoteEntry, segments: [SearchTextSegment], isTruncated: Bool? = nil) {
        self.entry = entry; self.segments = segments; self.isTruncated = isTruncated
    }
}

/// A deliberately saved point-in-time copy, never a claim that remote files are unchanged.
public struct SearchIndexSnapshot: Sendable {
    public let createdAt: Date
    public let documents: [SearchIndexDocument]
    public let includeHidden: Bool
    public let extraction: SearchExtractionOptions
    public let isPartial: Bool
    public init(createdAt: Date = Date(), documents: [SearchIndexDocument], includeHidden: Bool,
                extraction: SearchExtractionOptions, isPartial: Bool) {
        self.createdAt = createdAt; self.documents = documents; self.includeHidden = includeHidden
        self.extraction = extraction; self.isPartial = isPartial
    }

    /// How old an index set to update automatically must be before opening its folder updates it.
    public static let automaticUpdateInterval: TimeInterval = 15 * 60

    /// Whether an automatic update is due. A creation date in the future means the device clock
    /// moved backwards, so the age is unknown and the index is treated as due.
    public func isDueForAutomaticUpdate(at now: Date = Date(), interval: TimeInterval = automaticUpdateInterval) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age < 0 || age >= interval
    }
}

public enum SearchIndexError: LocalizedError, Sendable {
    case invalidSnapshot, tooLarge, damaged, invalidDirectory, superseded, notSaved
    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "The search index contains invalid file details. Rebuild it from the folder."
        case .tooLarge: return "The search index exceeds its storage limit. Build an index from a smaller folder."
        case .damaged: return "The saved search index cannot be read. Remove it and build it again."
        case .invalidDirectory: return "Search index storage is unavailable."
        case .superseded: return "A newer build or deletion replaced this search index operation."
        case .notSaved: return "Build the index before turning on automatic updates."
        }
    }
}

/// Explicitly saved, protected local search snapshots. Refresh replaces the whole snapshot,
/// so files removed remotely cannot survive a successful rebuild or update. A cancelled build never saves.
public actor SearchIndexStore {
    static let maximumDocuments = 500
    static let maximumTextBytes = 16 * 1_024 * 1_024
    static let maximumEncodedBytes = 32 * 1_024 * 1_024
    static let maximumIndexes = 8
    static let maximumDiskBytes = 128 * 1_024 * 1_024
    private let directory: URL
    private struct Build { let generation: UUID; let connectionID: UUID }
    private var builds: [String: Build] = [:]
    /// Index keys set to update automatically, with their connection so removal can find them.
    /// Kept apart from the snapshots, so a save never changes the setting and changing the
    /// setting never rewrites saved text.
    private var automaticKeys: [String: UUID]?
    private static let automaticFileName = "automatic-updates-v1.json"

    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    /// App windows use the same actor for a directory, including equivalent URL spellings.
    public static func shared(directory: URL) async -> SearchIndexStore {
        await SearchIndexStores.shared.store(directory)
    }

    /// Reserve the next replacement before traversing remote files. All windows sharing this
    /// actor observe the reservation; a newer build or deletion invalidates the older token.
    public func beginBuild(profile: ConnectionProfile, root: String) throws -> UUID {
        try Task.checkCancellation()
        guard Self.validPath(root) else { throw SearchIndexError.invalidSnapshot }
        let key = try Self.key(profile: profile, root: root), generation = UUID()
        builds[key] = Build(generation: generation, connectionID: profile.id)
        return generation
    }

    public func save(_ snapshot: SearchIndexSnapshot, profile: ConnectionProfile, root: String,
                     generation: UUID? = nil) throws {
        try Task.checkCancellation()
        let key = try Self.key(profile: profile, root: root)
        if let generation, builds[key]?.generation != generation { throw SearchIndexError.superseded }
        try Self.validate(snapshot, root: root)
        let envelope = Envelope(version: 1, key: key, connectionID: profile.id, root: root,
                                createdAt: snapshot.createdAt, includeHidden: snapshot.includeHidden,
                                extraction: snapshot.extraction, isPartial: snapshot.isPartial,
                                documents: snapshot.documents.map(Record.init))
        let bytes = try JSONEncoder().encode(envelope)
        guard bytes.count <= Self.maximumEncodedBytes else { throw SearchIndexError.tooLarge }
        try Task.checkCancellation()
        try prepareDirectory()
        let destination = directory.appendingPathComponent(key + ".json")
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        #if os(iOS)
        try bytes.write(to: temporary, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: temporary, options: .atomic)
        #endif
        try OfflineFileStore.protectFile(temporary)
        try Task.checkCancellation()
        // Evict oldest writes, using the hash as a stable tie-breaker. Never evict the copy being
        // replaced before its atomic rename succeeds.
        var files = try storedFiles().filter { $0.url != destination }
        var total = files.reduce(bytes.count) { $0 + $1.size }
        while files.count >= Self.maximumIndexes || total > Self.maximumDiskBytes {
            let oldest = files.removeFirst()
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            try forgetAutomatic { $0.key == oldest.url.deletingPathExtension().lastPathComponent }
        }
        try Task.checkCancellation()
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        builds.removeValue(forKey: key)
    }

    public func load(profile: ConnectionProfile, root: String) throws -> SearchIndexSnapshot? {
        try Task.checkCancellation()
        guard Self.validPath(root) else { throw SearchIndexError.invalidSnapshot }
        guard try existingDirectory() else { return nil }
        let key = try Self.key(profile: profile, root: root)
        let file = directory.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let envelope = try read(file)
        guard envelope.version == 1, envelope.key == key, envelope.connectionID == profile.id,
              envelope.root.utf8.elementsEqual(root.utf8) else { throw SearchIndexError.damaged }
        let snapshot = envelope.snapshot
        do { try Self.validate(snapshot, root: root) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SearchIndexError.damaged }
        try Task.checkCancellation()
        return snapshot
    }

    public func remove(profile: ConnectionProfile, root: String) throws {
        try Task.checkCancellation()
        guard Self.validPath(root) else { throw SearchIndexError.invalidSnapshot }
        let key = try Self.key(profile: profile, root: root)
        builds.removeValue(forKey: key)
        guard try existingDirectory() else { return }
        let file = directory.appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try forgetAutomatic { $0.key == key }
    }

    /// Whether the saved index for this connection and folder is set to update automatically.
    /// False when no index is saved, including after it was evicted.
    public func updatesAutomatically(profile: ConnectionProfile, root: String) throws -> Bool {
        try Task.checkCancellation()
        guard Self.validPath(root) else { throw SearchIndexError.invalidSnapshot }
        guard try existingDirectory() else { return false }
        let key = try Self.key(profile: profile, root: root)
        guard try automatic()[key] == profile.id else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(key + ".json").path)
    }

    /// Turning the setting on requires a saved index; deleting or evicting the index turns it off.
    public func setUpdatesAutomatically(_ enabled: Bool, profile: ConnectionProfile, root: String) throws {
        try Task.checkCancellation()
        guard Self.validPath(root) else { throw SearchIndexError.invalidSnapshot }
        let key = try Self.key(profile: profile, root: root)
        guard enabled else {
            if try existingDirectory() { try forgetAutomatic { $0.key == key } }
            return
        }
        guard try existingDirectory(),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(key + ".json").path) else {
            throw SearchIndexError.notSaved
        }
        var keys = try automatic()
        guard keys[key] != profile.id else { return }
        keys[key] = profile.id
        try writeAutomatic(keys)
    }

    public func remove(connectionID: UUID) throws {
        try Task.checkCancellation()
        builds = builds.filter { $0.value.connectionID != connectionID }
        guard try existingDirectory() else { return }
        for file in try storedFiles() {
            try Task.checkCancellation()
            // A corrupt file cannot be associated safely; remove it as unusable cached data.
            let envelope: Envelope?
            do { envelope = try read(file.url) }
            catch is CancellationError { throw CancellationError() }
            catch { envelope = nil }
            if envelope == nil || envelope?.connectionID == connectionID {
                try FileManager.default.removeItem(at: file.url)
            }
        }
        try forgetAutomatic { $0.value == connectionID }
    }

    private struct Record: Codable {
        let name: String, path: String
        let size: UInt64?
        let modifiedAt: Date?
        let segments: [SearchTextSegment]
        // Optional so indexes saved before it was recorded still load.
        let isTruncated: Bool?
        init(_ value: SearchIndexDocument) {
            name = value.entry.name; path = value.entry.path; size = value.entry.size
            modifiedAt = value.entry.modifiedAt; segments = value.segments; isTruncated = value.isTruncated
        }
        var document: SearchIndexDocument {
            .init(entry: .init(name: name, path: path, kind: .file, size: size, modifiedAt: modifiedAt), segments: segments,
                  isTruncated: isTruncated)
        }
    }
    private struct Envelope: Codable {
        let version: Int
        let key: String
        let connectionID: UUID
        let root: String
        let createdAt: Date
        let includeHidden: Bool
        let extraction: SearchExtractionOptions
        let isPartial: Bool
        let documents: [Record]
        var snapshot: SearchIndexSnapshot {
            .init(createdAt: createdAt, documents: documents.map(\.document), includeHidden: includeHidden,
                  extraction: extraction, isPartial: isPartial)
        }
    }

    private static func key(profile: ConnectionProfile, root: String) throws -> String {
        struct Identity: Encodable { let profile: ConnectionProfile; let root: String }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(Identity(profile: profile, root: root)))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func validPath(_ path: String) -> Bool { OfflineFolderPin.validPath(path) }

    private static func validate(_ snapshot: SearchIndexSnapshot, root: String) throws {
        guard validPath(root), snapshot.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SearchIndexError.invalidSnapshot
        }
        guard snapshot.documents.count <= maximumDocuments else { throw SearchIndexError.tooLarge }
        var used = 0, paths = Set<Data>()
        for document in snapshot.documents {
            try Task.checkCancellation()
            let entry = document.entry
            guard entry.kind == .file, entry.link == nil, validPath(entry.path),
                  !entry.path.utf8.elementsEqual(root.utf8), RemoteResourcePath.contains(entry.path, in: root),
                  entry.name.utf8.elementsEqual(RemotePath.name(of: entry.path).utf8),
                  paths.insert(Data(entry.path.utf8)).inserted else { throw SearchIndexError.invalidSnapshot }
            let relative = entry.path.dropFirst(root == "/" ? 1 : root.count + 1)
            guard snapshot.includeHidden || !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
                throw SearchIndexError.invalidSnapshot
            }
            guard document.segments.count <= 100 else { throw SearchIndexError.tooLarge }
            for segment in document.segments {
                guard segment.page.map({ (1...100).contains($0) }) ?? true else { throw SearchIndexError.invalidSnapshot }
                let count = segment.text.utf8.count
                guard count <= maximumTextBytes - used else { throw SearchIndexError.tooLarge }
                used += count
            }
        }
    }

    private func existingDirectory() throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw SearchIndexError.invalidDirectory
        }
        return true
    }
    private func prepareDirectory() throws {
        if try existingDirectory() { /* Validate before changing protection. */ }
        try OfflineFileStore.protectDirectory(directory)
    }
    private struct StoredFile { let url: URL; let size: Int; let modified: Date }
    private func storedFiles() throws -> [StoredFile] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 64 }
            .map { url in
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber else { throw SearchIndexError.damaged }
                return StoredFile(url: url, size: size.intValue, modified: attributes[.modificationDate] as? Date ?? .distantPast)
            }.sorted {
                $0.modified == $1.modified ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.modified < $1.modified
            }
    }
    /// An unreadable settings file turns automatic updates off rather than failing index use.
    private func automatic() throws -> [String: UUID] {
        if let automaticKeys { return automaticKeys }
        let file = directory.appendingPathComponent(Self.automaticFileName)
        var keys: [String: UUID] = [:]
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
           let bytes = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: UUID].self, from: bytes) {
            keys = decoded.filter { $0.key.count == 64 && $0.key.allSatisfy(\.isHexDigit) }
        }
        automaticKeys = keys
        return keys
    }
    private func forgetAutomatic(where shouldRemove: (Dictionary<String, UUID>.Element) -> Bool) throws {
        let keys = try automatic()
        let kept = keys.filter { !shouldRemove($0) }
        if kept.count != keys.count { try writeAutomatic(kept) }
    }
    private func writeAutomatic(_ keys: [String: UUID]) throws {
        try prepareDirectory()
        let file = directory.appendingPathComponent(Self.automaticFileName)
        if keys.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } else {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(keys)
            #if os(iOS)
            try bytes.write(to: file, options: [.atomic, .completeFileProtection])
            #else
            try bytes.write(to: file, options: .atomic)
            #endif
            try OfflineFileStore.protectFile(file)
        }
        automaticKeys = keys
    }
    private func read(_ file: URL) throws -> Envelope {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(Self.maximumEncodedBytes) else {
            throw SearchIndexError.damaged
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: min(65_536, Self.maximumEncodedBytes - bytes.count + 1)), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= Self.maximumEncodedBytes - bytes.count else { throw SearchIndexError.damaged }
            bytes.append(chunk)
        }
        do { return try JSONDecoder().decode(Envelope.self, from: bytes) }
        catch { throw SearchIndexError.damaged }
    }
}

private actor SearchIndexStores {
    static let shared = SearchIndexStores()
    var stores: [String: SearchIndexStore] = [:]
    func store(_ directory: URL) -> SearchIndexStore {
        let key = Self.directoryKey(directory)
        if let store = stores[key] { return store }
        let store = SearchIndexStore(directory: URL(fileURLWithPath: key, isDirectory: true))
        stores[key] = store
        return store
    }

    private static func directoryKey(_ directory: URL) -> String {
        // Foundation can resolve /var and other parent aliases differently once the index
        // exists. Normalize dot components lexically, then resolve only an existing parent:
        // resolving a nonexistent whole path leaves its symlink ancestors unresolved.
        var components: [String] = []
        for component in directory.absoluteURL.path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(String(component)) }
        }
        guard let leaf = components.popLast() else { return "/" }
        var suffix = [leaf]
        var parent = URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
        while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
            suffix.insert(parent.lastPathComponent, at: 0)
            parent.deleteLastPathComponent()
        }
        // Keep the final component unresolved: storage still rejects an index directory
        // that is itself a symbolic link rather than silently accepting its target.
        return suffix.reduce(parent.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.path
    }
}
