import Foundation

public struct AppMetadata: Codable, Sendable {
    public var version = 1
    public var connections: [ConnectionProfile] = []
    public var identities: [IdentityMetadata] = []
    public var favourites: [SavedLocation] = []
    public var recents: [SavedLocation] = []
    public init() {}
}

public actor MetadataStore {
    private let fileURL: URL
    private var metadata: AppMetadata
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            metadata = try JSONDecoder().decode(AppMetadata.self, from: Data(contentsOf: fileURL))
            guard metadata.version == 1 else { throw RemoteFileError.unavailable("This library was saved by a newer app version.") }
        } else { metadata = AppMetadata() }
    }
    public func snapshot() -> AppMetadata { metadata }
    public func identity(id: UUID) throws -> IdentityMetadata {
        guard let identity = metadata.identities.first(where: { $0.id == id }) else {
            throw RemoteFileError.unavailable("The SSH identity for this connection is missing. Choose a key in connection settings.")
        }
        return identity
    }
    public func save(_ value: AppMetadata) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(value)
        try bytes.write(to: fileURL, options: [.atomic, .completeFileProtection])
        metadata = value
    }
}
