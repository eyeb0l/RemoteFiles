import Foundation
import Crypto
import Citadel
import NIOSSH

/// Unlocked, foreground-only signing material. The encrypted imported original remains in Keychain.
public enum IdentityPrivateKey: Sendable {
    case ed25519(Curve25519.Signing.PrivateKey)
    case rsa(RSASHA2PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    public var nioPrivateKey: NIOSSHPrivateKey {
        switch self {
        case .ed25519(let key): return .init(ed25519Key: key)
        case .rsa(let key): return .init(custom: key)
        case .p256(let key): return .init(p256Key: key)
        case .p384(let key): return .init(p384Key: key)
        case .p521(let key): return .init(p521Key: key)
        }
    }

    /// This representation belongs only in a protected secret store, never in metadata or logs.
    public var rawRepresentation: Data {
        switch self {
        case .ed25519(let key): return key.rawRepresentation
        case .rsa(let key): return key.derRepresentation
        case .p256(let key): return key.rawRepresentation
        case .p384(let key): return key.rawRepresentation
        case .p521(let key): return key.rawRepresentation
        }
    }

    init(algorithm: String, bytes: Data) throws {
        switch algorithm {
        case "ssh-ed25519": self = .ed25519(try .init(rawRepresentation: bytes))
        case "ssh-rsa": self = .rsa(try .init(derRepresentation: bytes))
        case "ecdsa-sha2-nistp256": self = .p256(try .init(rawRepresentation: bytes))
        case "ecdsa-sha2-nistp384": self = .p384(try .init(rawRepresentation: bytes))
        case "ecdsa-sha2-nistp521": self = .p521(try .init(rawRepresentation: bytes))
        default: throw IdentityError.malformedKey
        }
    }

    func authentication(username: String) -> SSHAuthenticationMethod {
        switch self {
        case .ed25519(let key): return .ed25519(username: username, privateKey: key)
        case .rsa(let key): return .rsaSHA2(username: username, privateKey: key)
        case .p256(let key): return .p256(username: username, privateKey: key)
        case .p384(let key): return .p384(username: username, privateKey: key)
        case .p521(let key): return .p521(username: username, privateKey: key)
        }
    }
}

public extension IdentityMetadata {
    var algorithmName: String {
        switch algorithm {
        case "ssh-ed25519": return "Ed25519"
        case "ssh-rsa": return "RSA"
        case "ecdsa-sha2-nistp256": return "ECDSA P-256"
        case "ecdsa-sha2-nistp384": return "ECDSA P-384"
        case "ecdsa-sha2-nistp521": return "ECDSA P-521"
        default: return algorithm
        }
    }
}
