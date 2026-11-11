import Foundation

public struct AppMetadata: Codable, Equatable, Sendable {
    public var version = 1
    public var connections: [ConnectionProfile] = []
    public var identities: [IdentityMetadata] = []
    public var favourites: [SavedLocation] = []
    public var recents: [SavedLocation] = []
    public init() {}
}

/// One store for each file, shared by everything in the process that names it. Each window has its
/// own model; with a store apiece, each wrote back its own copy of the file and so undid whatever
/// another had saved since: a new connection or key, a host whose trust was reset, deleted history.
final class SharedFileStores<Store: AnyObject>: @unchecked Sendable {
    private struct Entry { weak var store: Store? }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// The store already open on this file, or a new one. Held weakly: when its last user goes, so does it.
    func store(at fileURL: URL, make: (URL) throws -> Store) rethrows -> Store {
        let file = fileURL.standardizedFileURL
        lock.lock(); defer { lock.unlock() }
        if let store = entries[file.path]?.store { return store }
        let store = try make(file)
        entries = entries.filter { $0.value.store != nil }
        entries[file.path] = Entry(store: store)
        return store
    }
}

public actor MetadataStore {
    private let fileURL: URL
    private var metadata: AppMetadata
    private var removedRecentIDs: Set<UUID> = []
    /// The library as saved, which save it was, counted from this store's start, and who made it.
    /// A window compares the count with the last it has seen: a report of something it already has,
    /// arriving late, must not replace what it has saved since.
    public struct Saved: Sendable {
        public let metadata: AppMetadata
        public let revision: Int
        public let origin: UUID?
    }
    private var revision = 0
    private var lastOrigin: UUID?
    private var observers: [UUID: AsyncStream<Saved>.Continuation] = [:]
    private static let stores = SharedFileStores<MetadataStore>()
    /// App windows use the same store for a library file. See `SharedFileStores`.
    public static func shared(fileURL: URL) throws -> MetadataStore {
        try stores.store(at: fileURL) { try MetadataStore(fileURL: $0) }
    }
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            metadata = try JSONDecoder().decode(AppMetadata.self, from: Data(contentsOf: fileURL))
            guard metadata.version == 1 else { throw RemoteFileError.unavailable("This library was saved by a newer app version.") }
        } else { metadata = AppMetadata() }
    }
    public func snapshot() -> AppMetadata { metadata }
    public func current() -> Saved { Saved(metadata: metadata, revision: revision, origin: lastOrigin) }
    public func identity(id: UUID) throws -> IdentityMetadata {
        guard let identity = metadata.identities.first(where: { $0.id == id }) else {
            throw RemoteFileError.unavailable("The SSH identity for this connection is missing. Choose a key in connection settings.")
        }
        return identity
    }
    @discardableResult
    public func save(_ value: AppMetadata, origin: UUID? = nil) throws -> Saved {
        var value = value
        // A save captured before removal must not resurrect that same entry. Opening the
        // file again creates a fresh ID, so legitimate new visits remain unaffected.
        value.recents.removeAll { removedRecentIDs.contains($0.id) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(value)
        #if os(iOS)
        try bytes.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        // iOS Data Protection is not supported by the macOS test host's filesystem.
        try bytes.write(to: fileURL, options: .atomic)
        #endif
        metadata = value
        revision += 1; lastOrigin = origin
        let saved = current()
        for observer in observers.values { observer.yield(saved) }
        return saved
    }

    /// Changes the library as it is saved now, and returns the result. A window's own copy can be
    /// older than this, so saving that copy whole would drop what another window added meanwhile.
    @discardableResult
    public func update(origin: UUID? = nil, _ change: @Sendable (inout AppMetadata) throws -> Void) throws -> Saved {
        var candidate = metadata
        try change(&candidate)
        return try save(candidate, origin: origin)
    }

    /// The library now, and again after every save, for each window to show what another changed.
    /// A slow observer is given only the newest: each value is the whole library.
    public func changes() -> AsyncStream<Saved> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Saved>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(current())
        return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    /// Removes the library entry, never the remote file or a favourite pointing to it.
    public func removeRecent(id: UUID, origin: UUID? = nil) throws {
        guard metadata.recents.contains(where: { $0.id == id }) else { removedRecentIDs.insert(id); return }
        var candidate = metadata
        candidate.recents.removeAll { $0.id == id }
        try save(candidate, origin: origin)
        removedRecentIDs.insert(id)
    }
}
