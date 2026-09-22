import Foundation
import Crypto
import NIOSSH

public struct HostEndpoint: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public init(host: String, port: Int = 22) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
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

public enum HostTrustError: LocalizedError, Sendable {
    case unknown(endpoint: HostEndpoint, key: HostKeyDetails)
    case changed(endpoint: HostEndpoint, previous: HostKeyDetails, current: HostKeyDetails)
    case invalidKey, invalidStore

    public var errorDescription: String? {
        switch self {
        case .unknown(let endpoint, _): return "Verify the host key for \(endpoint.host):\(endpoint.port) before connecting."
        case .changed(let endpoint, _, _): return "The host key for \(endpoint.host):\(endpoint.port) has changed. The connection was blocked. Verify the new key independently before resetting trust."
        case .invalidKey: return "The server presented an invalid host key."
        case .invalidStore: return "The saved host-trust data cannot be read. Connection is blocked until it is repaired."
        }
    }
}

public actor HostTrustStore {
    private struct Record: Codable { let endpoint: HostEndpoint; let key: HostKeyDetails }
    private struct Document: Codable { let version: Int; let records: [Record] }
    private let fileURL: URL
    private var keys: [HostEndpoint: HostKeyDetails]

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
            } catch { throw HostTrustError.invalidStore }
        } else { keys = [:] }
    }

    /// Called by the transport's asynchronous server-authentication delegate before user auth.
    public func validate(endpoint: HostEndpoint, publicKey: NIOSSHPublicKey) throws {
        let current = try HostKeyDetails(publicKey: publicKey)
        guard let previous = keys[endpoint] else { throw HostTrustError.unknown(endpoint: endpoint, key: current) }
        guard previous.publicKey == current.publicKey else {
            throw HostTrustError.changed(endpoint: endpoint, previous: previous, current: current)
        }
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

    private func persist(_ values: [HostEndpoint: HostKeyDetails]) throws {
        let records = values.map { Record(endpoint: $0.key, key: $0.value) }
            .sorted { ($0.endpoint.host, $0.endpoint.port) < ($1.endpoint.host, $1.endpoint.port) }
        let bytes = try JSONEncoder().encode(Document(version: 1, records: records))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: fileURL, options: .atomic)
    }
}
