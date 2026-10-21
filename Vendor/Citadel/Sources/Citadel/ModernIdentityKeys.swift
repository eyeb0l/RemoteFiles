import Foundation
import Crypto
import _CryptoExtras
import BigInt
import NIO
import NIOSSH

/// RSA client authentication with SHA-2 only. Public material retains the ssh-rsa wire format.
public struct RSASHA2PrivateKey: NIOSSHPrivateKeyProtocol, Sendable {
    public static let keyPrefix = "ssh-rsa"
    let key: _RSA.Signing.PrivateKey
    let sha256: Bool

    public init(sshOpenSSH text: String, decryptionKey: Data? = nil) throws {
        self = try OpenSSH.PrivateKey<Self>(string: text, decryptionKey: decryptionKey).privateKey
    }

    public init(derRepresentation: Data) throws {
        key = try _RSA.Signing.PrivateKey(derRepresentation: derRepresentation)
        guard (2048...8192).contains(key.keySizeInBits) else { throw InvalidOpenSSHKey.invalidLayout }
        sha256 = false
    }

    init(key: _RSA.Signing.PrivateKey, sha256: Bool = false) { self.key = key; self.sha256 = sha256 }
    public var derRepresentation: Data { key.derRepresentation }
    public var usingSHA256: Self { Self(key: key, sha256: true) }
    public var publicKey: NIOSSHPublicKeyProtocol { RSASHA2PublicKey(key: key.publicKey, sha256: sha256) }

    public func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        if sha256 {
            return RSASHA256Signature(rawRepresentation: try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation)
        }
        return RSASHA512Signature(rawRepresentation: try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation)
    }
}

public struct RSASHA2PublicKey: NIOSSHPublicKeyProtocol {
    public static let publicKeyPrefix = "ssh-rsa"
    let key: _RSA.Signing.PublicKey
    let sha256: Bool
    public var authenticationAlgorithm: String { sha256 ? "rsa-sha2-256" : "rsa-sha2-512" }
    public var rawRepresentation: Data { var buffer = ByteBuffer(); _ = write(to: &buffer); return Data(buffer.readableBytesView) }
    public func write(to buffer: inout ByteBuffer) -> Int {
        // Extracting primitives cannot fail for a previously validated RSA key.
        guard let parts = try? key.getKeyPrimitives() else { return 0 }
        return buffer.writePositiveMPInt(parts.publicExponent) + buffer.writePositiveMPInt(parts.modulus)
    }
    public static func read(from buffer: inout ByteBuffer) throws -> Self {
        let e = try buffer.readIdentityMPInt(maximum: 5)
        let n = try buffer.readIdentityMPInt(maximum: 1025)
        let key = try _RSA.Signing.PublicKey(n: n, e: e)
        guard (2048...8192).contains(key.keySizeInBits) else { throw InvalidOpenSSHKey.invalidLayout }
        return Self(key: key, sha256: false)
    }
    public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        if let signature = signature as? RSASHA256Signature {
            return key.isValidSignature(.init(rawRepresentation: signature.rawRepresentation), for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
        }
        if let signature = signature as? RSASHA512Signature {
            return key.isValidSignature(.init(rawRepresentation: signature.rawRepresentation), for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
        }
        return false
    }
}

public struct RSASHA256Signature: NIOSSHSignatureProtocol {
    public static let signaturePrefix = "rsa-sha2-256"
    public let rawRepresentation: Data
    public func write(to buffer: inout ByteBuffer) -> Int { buffer.writeSSHString(rawRepresentation) }
    public static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let bytes = buffer.readSSHBuffer(), bytes.readableBytes <= 1024 else { throw InvalidOpenSSHKey.invalidLayout }
        return Self(rawRepresentation: Data(bytes.readableBytesView))
    }
}
public struct RSASHA512Signature: NIOSSHSignatureProtocol {
    public static let signaturePrefix = "rsa-sha2-512"
    public let rawRepresentation: Data
    public func write(to buffer: inout ByteBuffer) -> Int { buffer.writeSSHString(rawRepresentation) }
    public static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let bytes = buffer.readSSHBuffer(), bytes.readableBytes <= 1024 else { throw InvalidOpenSSHKey.invalidLayout }
        return Self(rawRepresentation: Data(bytes.readableBytesView))
    }
}

extension RSASHA2PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self { try read(from: &buffer) }
}
extension RSASHA2PrivateKey: OpenSSHPrivateKey {
    typealias PublicKey = RSASHA2PublicKey
    static var publicKeyPrefix: String { "ssh-rsa" }
    static var privateKeyPrefix: String { "ssh-rsa" }
    static var keyType: OpenSSH.KeyType { .sshRSA }
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        let n = try buffer.readIdentityMPInt(maximum: 1025)
        let e = try buffer.readIdentityMPInt(maximum: 5)
        let d = try buffer.readIdentityMPInt(maximum: 1025)
        let iqmp = try buffer.readIdentityMPInt(maximum: 1025)
        let p = try buffer.readIdentityMPInt(maximum: 1025)
        let q = try buffer.readIdentityMPInt(maximum: 1025)
        let bp = BigUInt(p), bq = BigUInt(q), bn = BigUInt(n), be = BigUInt(e)
        guard bp > 1, bq > 1, bp != bq, bp * bq == bn,
              bq * BigUInt(iqmp) % bp == 1, be >= 3, be % 2 == 1,
              (2048...8192).contains(bn.bitWidth) else { throw InvalidOpenSSHKey.invalidLayout }
        return Self(key: try _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q))
    }
    func write(to buffer: inout ByteBuffer) -> Int { 0 } // Import-only; DER is used for protected biometric copies.
}

private extension ByteBuffer {
    mutating func readIdentityMPInt(maximum: Int) throws -> Data {
        guard let size = readInteger(as: UInt32.self), size > 0, size <= maximum,
              let bytes = readData(length: Int(size)), let first = bytes.first,
              first < 0x80, first != 0 || (bytes.count > 1 && bytes[bytes.startIndex + 1] >= 0x80) else {
            throw InvalidOpenSSHKey.invalidLayout
        }
        return first == 0 ? Data(bytes.dropFirst()) : bytes
    }
}

// OpenSSH stores the curve name and public point before the private scalar. Verify both public
// copies against the derived key, and reject negative, oversized or non-canonical scalars.
private func readECDSA(_ buffer: inout ByteBuffer, curve: String, size: Int) throws -> (Data, Data) {
    guard buffer.readSSHString() == curve, let point = buffer.readSSHBuffer() else { throw InvalidOpenSSHKey.invalidLayout }
    var scalar = try buffer.readIdentityMPInt(maximum: size + 1)
    guard scalar.count <= size else { throw InvalidOpenSSHKey.invalidLayout }
    scalar = Data(repeating: 0, count: size - scalar.count) + scalar
    return (Data(point.readableBytesView), scalar)
}

extension P256.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        guard buffer.readSSHString() == "nistp256", let point = buffer.readSSHBuffer() else { throw InvalidOpenSSHKey.invalidLayout }
        return try Self(x963Representation: Data(point.readableBytesView))
    }
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeSSHString("nistp256".utf8) + buffer.writeSSHString(x963Representation) }
}
extension P256.Signing.PrivateKey: OpenSSHPrivateKey {
    typealias PublicKey = P256.Signing.PublicKey
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp256" }
    static var privateKeyPrefix: String { publicKeyPrefix }
    static var keyType: OpenSSH.KeyType { .ecdsaP256 }
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        let (point, scalar) = try readECDSA(&buffer, curve: "nistp256", size: 32)
        let key = try Self(rawRepresentation: scalar)
        guard key.publicKey.x963Representation == point else { throw InvalidOpenSSHKey.invalidLayout }; return key
    }
    func write(to buffer: inout ByteBuffer) -> Int { 0 }
    public init(sshOpenSSH text: String, decryptionKey: Data? = nil) throws { self = try OpenSSH.PrivateKey<Self>(string: text, decryptionKey: decryptionKey).privateKey }
}
extension P384.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        guard buffer.readSSHString() == "nistp384", let point = buffer.readSSHBuffer() else { throw InvalidOpenSSHKey.invalidLayout }
        return try Self(x963Representation: Data(point.readableBytesView))
    }
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeSSHString("nistp384".utf8) + buffer.writeSSHString(x963Representation) }
}
extension P384.Signing.PrivateKey: OpenSSHPrivateKey {
    typealias PublicKey = P384.Signing.PublicKey
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp384" }
    static var privateKeyPrefix: String { publicKeyPrefix }
    static var keyType: OpenSSH.KeyType { .ecdsaP384 }
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        let (point, scalar) = try readECDSA(&buffer, curve: "nistp384", size: 48)
        let key = try Self(rawRepresentation: scalar)
        guard key.publicKey.x963Representation == point else { throw InvalidOpenSSHKey.invalidLayout }; return key
    }
    func write(to buffer: inout ByteBuffer) -> Int { 0 }
    public init(sshOpenSSH text: String, decryptionKey: Data? = nil) throws { self = try OpenSSH.PrivateKey<Self>(string: text, decryptionKey: decryptionKey).privateKey }
}
extension P521.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        guard buffer.readSSHString() == "nistp521", let point = buffer.readSSHBuffer() else { throw InvalidOpenSSHKey.invalidLayout }
        return try Self(x963Representation: Data(point.readableBytesView))
    }
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeSSHString("nistp521".utf8) + buffer.writeSSHString(x963Representation) }
}
extension P521.Signing.PrivateKey: OpenSSHPrivateKey {
    typealias PublicKey = P521.Signing.PublicKey
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp521" }
    static var privateKeyPrefix: String { publicKeyPrefix }
    static var keyType: OpenSSH.KeyType { .ecdsaP521 }
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        let (point, scalar) = try readECDSA(&buffer, curve: "nistp521", size: 66)
        let key = try Self(rawRepresentation: scalar)
        guard key.publicKey.x963Representation == point else { throw InvalidOpenSSHKey.invalidLayout }; return key
    }
    func write(to buffer: inout ByteBuffer) -> Int { 0 }
    public init(sshOpenSSH text: String, decryptionKey: Data? = nil) throws { self = try OpenSSH.PrivateKey<Self>(string: text, decryptionKey: decryptionKey).privateKey }
}
