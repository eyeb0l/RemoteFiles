import Foundation
import Crypto
import NIOSSH

public struct HostEndpoint: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int
    /// The jump host this server is reached through, or nil when it is reached directly. An
    /// address behind a jump host means whatever that jump host's network says it means, so the
    /// same private address behind two jump hosts is two servers, each with its own trusted key.
    /// Kept as two plain fields so a saved record without them is a server reached directly.
    public let viaHost: String?
    public let viaPort: Int?

    public init(host: String, port: Int = 22, via jumpHost: HostEndpoint? = nil) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
        viaHost = jumpHost?.host; viaPort = jumpHost?.port
    }

    public var via: HostEndpoint? { viaHost.map { HostEndpoint(host: $0, port: viaPort ?? 22) } }

    /// The server a connection reads from, as trust knows it: through its jump host if it has one.
    public static func destination(of profile: ConnectionProfile) -> HostEndpoint {
        HostEndpoint(host: profile.host, port: profile.port, via: jumpHost(of: profile))
    }
    /// A connection's jump host, which is itself reached directly.
    public static func jumpHost(of profile: ConnectionProfile) -> HostEndpoint? {
        profile.jumpHost.map { HostEndpoint(host: $0.host, port: $0.port) }
    }
    /// Both, for asking which connections use a trusted key.
    public static func all(of profile: ConnectionProfile) -> [HostEndpoint] {
        [destination(of: profile)] + (jumpHost(of: profile).map { [$0] } ?? [])
    }

    /// `host:port`, and the jump host when there is one.
    public var displayName: String {
        "\(host):\(port)" + (via.map { " through \($0.host):\($0.port)" } ?? "")
    }
}

public struct HostKeyDetails: Codable, Hashable, Sendable {
    public let publicKey: String
    public let algorithm: String
    public let fingerprint: String

    public init(publicKey: NIOSSHPublicKey) throws {
        let canonical = String(openSSHPublicKey: publicKey)
        let fields = canonical.split(separator: " ")
        guard fields.count == 2, let bytes = Data(base64Encoded: String(fields[1])) else {
            throw HostTrustError.invalidKey
        }
        self.publicKey = canonical
        algorithm = String(fields[0])
        fingerprint = "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// The host keys a connection authenticated its server, and its jump host if it has one, with.
public struct ServerHostKeys: Hashable, Sendable {
    public let destination: HostKeyDetails
    public let jumpHost: HostKeyDetails?
    public init(destination: HostKeyDetails, jumpHost: HostKeyDetails? = nil) {
        self.destination = destination; self.jumpHost = jumpHost
    }
}

/// A download, with the host keys of the connection its bytes came through: nil when the
/// transport cannot say.
public struct AttestedDownload: Sendable {
    public let entry: RemoteEntry
    public let hostKeys: ServerHostKeys?
    public init(entry: RemoteEntry, hostKeys: ServerHostKeys?) { self.entry = entry; self.hostKeys = hostKeys }
}

/// A transport that can say which host keys a download's bytes came through, and which keys are
/// trusted now. Keeping copies of what was read binds them to the first and looks them up by the
/// second: a connection opened before a trust reset keeps the key it verified, whatever is trusted since.
public protocol HostKeyAttesting: Sendable {
    /// The keys trusted now for the profile's server and its jump host, or nil while either has none.
    func trustedHostKeys(for profile: ConnectionProfile) async -> ServerHostKeys?
    func attestedDownloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> AttestedDownload
    func attestedDownloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                                      limit: Int, progress: @escaping DownloadProgressHandler) async throws -> AttestedDownload
}

public enum HostTrustError: LocalizedError, Sendable {
    case unknown(endpoint: HostEndpoint, key: HostKeyDetails)
    case changed(endpoint: HostEndpoint, previous: HostKeyDetails, current: HostKeyDetails)
    case invalidKey, invalidStore

    public var errorDescription: String? {
        switch self {
        case .unknown(let endpoint, _): return "Verify the host key for \(endpoint.displayName) before connecting."
        case .changed(let endpoint, _, _): return "The host key for \(endpoint.displayName) has changed. The connection was blocked. Verify the new key independently before resetting trust."
        case .invalidKey: return "The server presented an invalid host key."
        case .invalidStore: return "The saved host-trust data cannot be read. Connection is blocked until it is repaired."
        }
    }
}

public actor HostTrustStore {
    private struct Record: Codable { let endpoint: HostEndpoint; let key: HostKeyDetails }
    /// `routed` marks a file whose servers behind jump hosts already have their own records. It is
    /// a separate field, and the version stays 1, so an earlier build still reads the file.
    private struct Document: Codable { let version: Int; let records: [Record]; var routed: Bool? = nil }
    private let fileURL: URL
    private var keys: [HostEndpoint: HostKeyDetails]
    private var routed: Bool
    private static let stores = SharedFileStores<HostTrustStore>()

    /// App windows use the same store for a trust file. With one each, a window that still held a
    /// host's old key went on accepting it after another window reset that host's trust, and wrote
    /// the old key back when it next trusted any host at all.
    public static func shared(fileURL: URL) throws -> HostTrustStore {
        try stores.store(at: fileURL) { try HostTrustStore(fileURL: $0) }
    }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
                guard document.version == 1 else { throw HostTrustError.invalidStore }
                var loaded: [HostEndpoint: HostKeyDetails] = [:]
                for record in document.records {
                    let canonical = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: record.key.publicKey))
                    guard canonical == record.key, loaded[record.endpoint] == nil else { throw HostTrustError.invalidStore }
                    loaded[record.endpoint] = canonical
                }
                keys = loaded
                routed = document.routed == true
            } catch { throw HostTrustError.invalidStore }
        } else { keys = [:]; routed = true }
    }

    /// Before servers behind jump hosts had their own records, such a server's key was saved as
    /// if it were reached directly. Once, for a file from then: each saved connection through a
    /// jump host takes over that record for its own route, so nobody is asked to verify again a
    /// key they already trusted, and the directly-reached record goes unless a saved connection
    /// does reach that address directly or uses it as a jump host.
    public func adoptJumpRoutes(of connections: [ConnectionProfile]) throws {
        guard !routed else { return }
        var next = keys
        let direct = Set(connections.flatMap { profile in
            (profile.jumpHost == nil ? [HostEndpoint.destination(of: profile)] : []) + (HostEndpoint.jumpHost(of: profile).map { [$0] } ?? [])
        })
        for profile in connections where profile.jumpHost != nil {
            let before = HostEndpoint(host: profile.host, port: profile.port), now = HostEndpoint.destination(of: profile)
            guard let key = keys[before] else { continue }
            if next[now] == nil { next[now] = key }
            if !direct.contains(before) { next.removeValue(forKey: before) }
        }
        try persist(next, routed: true)
        keys = next; routed = true
    }

    /// Called by the transport's asynchronous server-authentication delegate before user auth.
    /// Returns the key it accepted, so the connection can record which key it is talking to.
    @discardableResult
    public func validate(endpoint: HostEndpoint, publicKey: NIOSSHPublicKey) throws -> HostKeyDetails {
        let current = try HostKeyDetails(publicKey: publicKey)
        guard let previous = keys[endpoint] else { throw HostTrustError.unknown(endpoint: endpoint, key: current) }
        guard previous.publicKey == current.publicKey else {
            throw HostTrustError.changed(endpoint: endpoint, previous: previous, current: current)
        }
        return current
    }

    /// The key trusted for this endpoint now, if any.
    public func trustedKey(for endpoint: HostEndpoint) -> HostKeyDetails? { keys[endpoint] }

    /// The keys trusted now for a connection's server and its jump host, read together, or nil
    /// while either has none.
    public func trustedKeys(for profile: ConnectionProfile) -> ServerHostKeys? {
        guard let destination = keys[.destination(of: profile)] else { return nil }
        guard let hop = HostEndpoint.jumpHost(of: profile) else { return ServerHostKeys(destination: destination) }
        guard let jump = keys[hop] else { return nil }
        return ServerHostKeys(destination: destination, jumpHost: jump)
    }

    /// Explicit UI acceptance of an unknown key. A different already-trusted key cannot be overwritten.
    public func trustUnknown(endpoint: HostEndpoint, key: HostKeyDetails) throws {
        let canonical = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: key.publicKey))
        guard canonical == key else { throw HostTrustError.invalidKey }
        if let previous = keys[endpoint] {
            guard previous == canonical else { throw HostTrustError.changed(endpoint: endpoint, previous: previous, current: canonical) }
            return
        }
        var next = keys
        next[endpoint] = canonical
        try persist(next)
        keys = next
    }

    /// Reset only removes trust. A subsequent connection must present its key for acceptance again.
    public func reset(endpoint: HostEndpoint) throws {
        var next = keys
        next.removeValue(forKey: endpoint)
        try persist(next)
        keys = next
    }

    private func persist(_ values: [HostEndpoint: HostKeyDetails], routed: Bool? = nil) throws {
        let records = values.map { Record(endpoint: $0.key, key: $0.value) }
            .sorted { ($0.endpoint.host, $0.endpoint.port, $0.endpoint.viaHost ?? "", $0.endpoint.viaPort ?? 0)
                < ($1.endpoint.host, $1.endpoint.port, $1.endpoint.viaHost ?? "", $1.endpoint.viaPort ?? 0) }
        let bytes = try JSONEncoder().encode(Document(version: 1, records: records, routed: (routed ?? self.routed) ? true : nil))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        // Matches the library: trust is read at launch and written on acceptance, both while unlocked.
        try bytes.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        // iOS Data Protection is not supported by the macOS test host's filesystem.
        try bytes.write(to: fileURL, options: .atomic)
        #endif
    }
}
