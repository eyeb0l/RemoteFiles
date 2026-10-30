import Foundation
import Security
import LocalAuthentication
import Crypto
import Citadel
import NIOSSH

/// Safe to persist with connection metadata. This value never contains private material.
public struct IdentityMetadata: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let algorithm: String
    public let publicKey: String
    public let fingerprint: String
    public let requiresPassphrase: Bool
    public let keychainReference: String

    public init(id: UUID = UUID(), name: String, algorithm: String = "ssh-ed25519", publicKey: String,
                fingerprint: String, requiresPassphrase: Bool, keychainReference: String) {
        self.id = id; self.name = name; self.algorithm = algorithm; self.publicKey = publicKey
        self.fingerprint = fingerprint; self.requiresPassphrase = requiresPassphrase
        self.keychainReference = keychainReference
    }
}

public enum IdentityError: LocalizedError, Equatable, Sendable {
    case publicKeyOnly, malformedKey, unsupportedFormat(String), missingPassphrase, decryptionFailed
    case missingSecret, keychain(Int32), identityInUse, sessionEnded
    case biometricsUnavailable, biometricsDeclined

    public var errorDescription: String? {
        switch self {
        case .publicKeyOnly: return "This is a public key. Import its OpenSSH private-key file instead."
        case .malformedKey: return "This private key is malformed or damaged. Choose a complete OpenSSH Ed25519, RSA or ECDSA private key."
        case .unsupportedFormat(let reason): return "This key format is not supported in the preview. \(reason)"
        case .missingPassphrase: return "Enter the passphrase for this encrypted private key."
        case .decryptionFailed: return "The private key could not be unlocked. Check its passphrase; a damaged encrypted key can cause the same error."
        case .missingSecret: return "This identity's private key is no longer available on this device. Import it again or choose another identity."
        case .keychain(let status): return "The device could not access the private key in Keychain (\(status)). Unlock the device and try again."
        case .identityInUse: return "A saved connection still uses this identity. Choose another identity for that connection before deleting it."
        case .sessionEnded: return "The connection session ended. Unlock the identity again to reconnect."
        case .biometricsUnavailable: return "Face ID unlock is no longer available for this key, for example because Face ID changed. Enter its passphrase; you can turn Face ID unlock on again."
        case .biometricsDeclined: return "Face ID didn't unlock the key. Enter its passphrase instead."
        }
    }
}

/// Injectable only for deterministic tests. The app always uses KeychainIdentitySecretStore.
public protocol IdentitySecretStore: Sendable {
    func save(_ data: Data, reference: String) throws
    func load(reference: String) throws -> Data
    func delete(reference: String) throws
}

public struct KeychainIdentitySecretStore: IdentitySecretStore {
    private let service: String
    public init(service: String = "app.remotefiles.ssh-identities") { self.service = service }

    private func query(reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: reference,
         kSecAttrSynchronizable as String: false]
    }

    public func save(_ data: Data, reference: String) throws {
        var attributes = query(reference: reference)
        attributes[kSecValueData as String] = data
        // No migration to another device, iCloud sync, or access while the device is locked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
    }

    public func load(reference: String) throws -> Data {
        try Task.checkCancellation()
        var attributes = query(reference: reference)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw IdentityError.missingSecret }
        guard status == errSecSuccess, let data = result as? Data else { throw IdentityError.keychain(status) }
        return data
    }

    public func delete(reference: String) throws {
        let status = SecItemDelete(query(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError.keychain(status) }
    }
}

/// Keychain items readable only after the currently enrolled Face ID or Touch ID. Injectable for tests.
public protocol BiometricKeyStore: Sendable {
    /// Replaces any existing item. Never prompts.
    func save(_ data: Data, reference: String) throws
    /// Asks for Face ID or Touch ID with `reason`, then reads the item. Cancelling the task dismisses
    /// the prompt and throws `CancellationError` without reading.
    func load(reference: String, reason: String) async throws -> Data
    /// Whether an item exists, without prompting.
    func contains(reference: String) -> Bool
    func delete(reference: String) throws
}

/// Unlocked keys for Face ID unlock: this device only, never synchronised, readable only while a
/// passcode is set and only after biometrics enrolled when the item was saved. Changing Face ID
/// enrolment makes the item unreadable; the passphrase then unlocks the original as before.
public struct KeychainBiometricKeyStore: BiometricKeyStore {
    private let service: String
    public init(service: String = "app.remotefiles.ssh-identities.biometric") { self.service = service }

    private func query(reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: reference,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func save(_ data: Data, reference: String) throws {
        try delete(reference: reference)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, &error) else {
            throw IdentityError.biometricsUnavailable
        }
        var attributes = query(reference: reference)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
    }

    public func load(reference: String, reason: String) async throws -> Data {
        // Authenticate first so cancellation and lockout are reported before Keychain is touched.
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Passphrase"
        do {
            // Cancelling the task does not stop the prompt; invalidating its context does.
            _ = try await withTaskCancellationHandler {
                try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            } onCancel: { context.invalidate() }
        } catch let error as LAError {
            try Task.checkCancellation()
            switch error.code {
            case .biometryNotAvailable, .biometryNotEnrolled: throw IdentityError.biometricsUnavailable
            default: throw IdentityError.biometricsDeclined
            }
        }
        var attributes = query(reference: reference)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw IdentityError.biometricsUnavailable }
            return data
        case errSecUserCanceled: throw IdentityError.biometricsDeclined
        // A missing item, or one invalidated by a Face ID enrolment change.
        case errSecItemNotFound, errSecAuthFailed: throw IdentityError.biometricsUnavailable
        default: throw IdentityError.keychain(status)
        }
    }

    public func contains(reference: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var attributes = query(reference: reference)
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(attributes as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func delete(reference: String) throws {
        let status = SecItemDelete(query(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError.keychain(status) }
    }
}

public actor IdentityStore {
    private struct StoredSecret: Codable {
        enum Format: String, Codable { case generatedEd25519, importedOpenSSH, biometricSigningKey }
        let version: Int
        let format: Format
        let bytes: Data
    }

    private let secretStore: any IdentitySecretStore
    /// Nil where biometric Keychain items are unavailable, such as the macOS test host.
    private let biometricStore: (any BiometricKeyStore)?
    private var unlocked: [UUID: IdentityPrivateKey] = [:]
    private var sessionGeneration: UInt64 = 0

    public init(secretStore: any IdentitySecretStore = KeychainIdentitySecretStore(),
                biometricStore: (any BiometricKeyStore)? = IdentityStore.defaultBiometricStore) {
        self.secretStore = secretStore
        self.biometricStore = biometricStore
    }

    public static var defaultBiometricStore: (any BiometricKeyStore)? {
        #if os(iOS)
        KeychainBiometricKeyStore()
        #else
        nil
        #endif
    }

    public func generate(name: String) throws -> IdentityMetadata {
        let key = Curve25519.Signing.PrivateKey()
        let metadata = try makeMetadata(name: name, key: .ed25519(key), requiresPassphrase: false)
        let secret = StoredSecret(version: 1, format: .generatedEd25519, bytes: key.rawRepresentation)
        try secretStore.save(JSONEncoder().encode(secret), reference: metadata.keychainReference)
        return metadata
    }

    /// Validates before saving. In particular, encrypted imports retain their encrypted original bytes.
    public func importKey(name: String, openSSH: String, passphrase: String? = nil) async throws -> IdentityMetadata {
        let generation = sessionGeneration
        let parsed = try await Task.detached(priority: .userInitiated) {
            try OpenSSHIdentityParser.parse(openSSH, passphrase: passphrase)
        }.value
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw IdentityError.sessionEnded }
        let metadata = try makeMetadata(name: name, key: parsed.key, requiresPassphrase: parsed.encrypted)
        let secret = StoredSecret(version: 1, format: .importedOpenSSH, bytes: Data(openSSH.utf8))
        try secretStore.save(JSONEncoder().encode(secret), reference: metadata.keychainReference)
        // Import validation must not create a long-lived unlocked session.
        return metadata
    }

    public func unlock(_ metadata: IdentityMetadata, passphrase: String? = nil) async throws -> IdentityPrivateKey {
        if let key = unlocked[metadata.id] { return key }
        let data = try secretStore.load(reference: metadata.keychainReference)
        guard let secret = try? JSONDecoder().decode(StoredSecret.self, from: data), secret.version == 1 else {
            throw IdentityError.malformedKey
        }
        let generation = sessionGeneration
        let key = try await Task.detached(priority: .userInitiated) {
            switch secret.format {
            case .generatedEd25519:
                return IdentityPrivateKey.ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: secret.bytes))
            case .importedOpenSSH:
                guard let text = String(data: secret.bytes, encoding: .utf8) else { throw IdentityError.malformedKey }
                return try OpenSSHIdentityParser.parse(text, passphrase: passphrase).key
            case .biometricSigningKey:
                throw IdentityError.malformedKey // Never stored as the primary secret.
            }
        }.value
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw IdentityError.sessionEnded }
        guard String(openSSHPublicKey: key.nioPrivateKey.publicKey) == metadata.publicKey else {
            throw IdentityError.malformedKey
        }
        unlocked[metadata.id] = key
        return key
    }

    public func delete(_ metadata: IdentityMetadata, referencedBy connectionIdentityIDs: Set<UUID>) throws {
        guard !connectionIdentityIDs.contains(metadata.id) else { throw IdentityError.identityInUse }
        // The unlocked copy goes first: a failure must not leave it behind after its identity is gone.
        try biometricStore?.delete(reference: metadata.keychainReference)
        try secretStore.delete(reference: metadata.keychainReference)
        unlocked.removeValue(forKey: metadata.id)
    }

    /// Explicit export only. Callers must obtain user confirmation and device authentication.
    /// Encrypted imports leave Keychain in their original encrypted form, never the cached signing
    /// key or biometric copy. Generated keys use the interoperable, unencrypted OpenSSH format.
    public func exportOpenSSH(_ metadata: IdentityMetadata) throws -> Data {
        try Task.checkCancellation()
        let data = try secretStore.load(reference: metadata.keychainReference)
        guard let secret = try? JSONDecoder().decode(StoredSecret.self, from: data), secret.version == 1 else {
            throw IdentityError.malformedKey
        }
        let exported: Data
        switch secret.format {
        case .generatedEd25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.bytes)
            guard !metadata.requiresPassphrase, metadata.algorithm == "ssh-ed25519",
                  String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) == metadata.publicKey else {
                throw IdentityError.malformedKey
            }
            exported = Data(key.makeSSHRepresentation().utf8)
        case .importedOpenSSH:
            try OpenSSHIdentityParser.validateExport(secret.bytes, metadata: metadata)
            exported = secret.bytes
        case .biometricSigningKey:
            throw IdentityError.malformedKey
        }
        try Task.checkCancellation()
        return exported
    }

    /// Whether this identity can be unlocked with Face ID or Touch ID. Never prompts.
    public func hasBiometricUnlock(_ metadata: IdentityMetadata) -> Bool {
        biometricStore?.contains(reference: metadata.keychainReference) ?? false
    }

    /// Keeps this encrypted identity's unlocked key behind the currently enrolled biometrics. It must
    /// already be unlocked with its passphrase in this session; the passphrase itself is never stored.
    public func enableBiometricUnlock(_ metadata: IdentityMetadata) throws {
        guard metadata.requiresPassphrase, let key = unlocked[metadata.id] else { throw IdentityError.missingPassphrase }
        guard let biometricStore else { throw IdentityError.biometricsUnavailable }
        let secret = StoredSecret(version: 1, format: .biometricSigningKey, bytes: key.rawRepresentation)
        try biometricStore.save(JSONEncoder().encode(secret), reference: metadata.keychainReference)
    }

    public func disableBiometricUnlock(_ metadata: IdentityMetadata) throws {
        try biometricStore?.delete(reference: metadata.keychainReference)
    }

    /// Unlocks with Face ID or Touch ID for this foreground session. Throws `biometricsUnavailable`
    /// when there is no usable copy, and `biometricsDeclined` when authentication is cancelled or fails;
    /// either way the passphrase still unlocks the original.
    public func unlockWithBiometrics(_ metadata: IdentityMetadata, reason: String) async throws -> IdentityPrivateKey {
        if let key = unlocked[metadata.id] { return key }
        guard let biometricStore else { throw IdentityError.biometricsUnavailable }
        let generation = sessionGeneration
        let data = try await biometricStore.load(reference: metadata.keychainReference, reason: reason)
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw IdentityError.sessionEnded }
        guard let secret = try? JSONDecoder().decode(StoredSecret.self, from: data), secret.version == 1,
              (secret.format == .biometricSigningKey || secret.format == .generatedEd25519 && metadata.algorithm == "ssh-ed25519"),
              let key = try? IdentityPrivateKey(algorithm: metadata.algorithm, bytes: secret.bytes),
              String(openSSHPublicKey: key.nioPrivateKey.publicKey) == metadata.publicKey else {
            // A copy that does not match this identity is never used.
            try? biometricStore.delete(reference: metadata.keychainReference)
            throw IdentityError.biometricsUnavailable
        }
        unlocked[metadata.id] = key
        return key
    }

    /// Call on disconnect and backgrounding. Passphrases themselves are never retained by this store.
    public func clearSession() {
        sessionGeneration &+= 1
        unlocked.removeAll(keepingCapacity: false)
    }

    private func makeMetadata(name: String, key: IdentityPrivateKey, requiresPassphrase: Bool) throws -> IdentityMetadata {
        let details = try HostKeyDetails(publicKey: key.nioPrivateKey.publicKey)
        let id = UUID()
        return IdentityMetadata(id: id, name: name, algorithm: details.algorithm, publicKey: details.publicKey,
                                fingerprint: details.fingerprint, requiresPassphrase: requiresPassphrase,
                                keychainReference: id.uuidString)
    }
}

/// Reads only the bounded OpenSSH container header to give useful errors and constrain the
/// supported matrix. Citadel performs all private-key parsing, KDF work, and decryption.
enum OpenSSHIdentityParser {
    struct Parsed { let key: IdentityPrivateKey; let encrypted: Bool }

    /// Checks the public envelope without decrypting an imported original for export.
    static func validateExport(_ bytes: Data, metadata: IdentityMetadata) throws {
        guard bytes.count <= 256 * 1024, let input = String(data: bytes, encoding: .utf8) else {
            throw IdentityError.malformedKey
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----", end = "-----END OPENSSH PRIVATE KEY-----"
        guard text.hasPrefix(begin), text.hasSuffix(end),
              let data = Data(base64Encoded: String(text.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace })) else {
            throw IdentityError.malformedKey
        }
        var reader = SSHContainerReader(data: data)
        guard try reader.take(15) == Data("openssh-key-v1\0".utf8) else { throw IdentityError.malformedKey }
        let cipher = try reader.string(), kdf = try reader.string(), options = try reader.field()
        guard ["none", "aes128-ctr", "aes256-ctr"].contains(cipher),
              (cipher != "none") == metadata.requiresPassphrase,
              cipher == "none" ? (kdf == "none" && options.isEmpty) : kdf == "bcrypt",
              try reader.integer() == 1 else { throw IdentityError.malformedKey }
        let publicBytes = try reader.field()
        let fields = metadata.publicKey.split(separator: " ")
        guard fields.count == 2, fields[0] == Substring(metadata.algorithm),
              Data(base64Encoded: String(fields[1])) == publicBytes,
              !(try reader.field()).isEmpty, reader.remaining == 0 else { throw IdentityError.malformedKey }
    }

    static func parse(_ input: String, passphrase: String?) throws -> Parsed {
        guard input.utf8.count <= 256 * 1024 else { throw IdentityError.malformedKey }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ssh-") || text.hasPrefix("ecdsa-") || text.hasPrefix("sk-") ||
            text.hasPrefix("-----BEGIN PUBLIC KEY-----") || text.hasPrefix("---- BEGIN SSH2 PUBLIC KEY ----") {
            throw IdentityError.publicKeyOnly
        }
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard text.hasPrefix(begin) else {
            if text.hasPrefix("-----BEGIN") { throw IdentityError.unsupportedFormat("Use an OpenSSH Ed25519, RSA or ECDSA private key.") }
            throw IdentityError.malformedKey
        }
        guard text.hasSuffix(end) else { throw IdentityError.malformedKey }
        let body = text.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else { throw IdentityError.malformedKey }
        var reader = SSHContainerReader(data: data)
        guard try reader.take(15) == Data("openssh-key-v1\0".utf8) else { throw IdentityError.malformedKey }
        let cipher = try reader.string()
        let kdf = try reader.string()
        let options = try reader.field()
        guard ["none", "aes128-ctr", "aes256-ctr"].contains(cipher) else {
            throw IdentityError.unsupportedFormat("Supported encryption is AES-128-CTR or AES-256-CTR with bcrypt rounds below 32.")
        }
        let encrypted = cipher != "none"
        if encrypted {
            guard kdf == "bcrypt" else { throw IdentityError.unsupportedFormat("Only the bcrypt key derivation format is supported.") }
            var kdfReader = SSHContainerReader(data: options)
            let salt = try kdfReader.field()
            let rounds = try kdfReader.integer()
            guard !salt.isEmpty, kdfReader.remaining == 0, rounds > 0, rounds < 32 else {
                throw IdentityError.unsupportedFormat("Citadel supports bcrypt round counts from 1 through 31. Keep your existing key protected; generate a dedicated app identity instead.")
            }
        } else {
            guard kdf == "none", options.isEmpty else { throw IdentityError.malformedKey }
        }
        guard try reader.integer() == 1 else { throw IdentityError.unsupportedFormat("Only single-key files are supported.") }
        let publicBytes = try reader.field()
        var publicReader = SSHContainerReader(data: publicBytes)
        let algorithm = try publicReader.string()
        guard ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"].contains(algorithm) else {
            throw IdentityError.unsupportedFormat("Supported identities are Ed25519, RSA (2048–8192 bits) and ECDSA (P-256, P-384 or P-521).")
        }
        let privateBytes = try reader.field()
        guard !privateBytes.isEmpty, reader.remaining == 0, privateBytes.count % (encrypted ? 16 : 8) == 0 else {
            throw IdentityError.malformedKey
        }
        if encrypted && (passphrase == nil || passphrase?.isEmpty == true) { throw IdentityError.missingPassphrase }
        // Citadel accepts LF wrapping; normalise container whitespace only for parsing.
        let normalised = begin + "\n" + body + "\n" + end + "\n"
        let key: IdentityPrivateKey
        let decryptionKey = encrypted ? passphrase.map { Data($0.utf8) } : nil
        do {
            switch algorithm {
            case "ssh-ed25519": key = .ed25519(try .init(sshEd25519: normalised, decryptionKey: decryptionKey))
            case "ssh-rsa": key = .rsa(try .init(sshOpenSSH: normalised, decryptionKey: decryptionKey))
            case "ecdsa-sha2-nistp256": key = .p256(try .init(sshOpenSSH: normalised, decryptionKey: decryptionKey))
            case "ecdsa-sha2-nistp384": key = .p384(try .init(sshOpenSSH: normalised, decryptionKey: decryptionKey))
            case "ecdsa-sha2-nistp521": key = .p521(try .init(sshOpenSSH: normalised, decryptionKey: decryptionKey))
            default: throw IdentityError.malformedKey
            }
        } catch {
            throw encrypted ? IdentityError.decryptionFailed : IdentityError.malformedKey
        }
        guard String(openSSHPublicKey: key.nioPrivateKey.publicKey) == algorithm + " " + publicBytes.base64EncodedString() else { throw IdentityError.malformedKey }
        return Parsed(key: key, encrypted: encrypted)
    }
}

private struct SSHContainerReader {
    let data: Data
    private var offset = 0
    init(data: Data) { self.data = data }
    var remaining: Int { data.count - offset }
    mutating func take(_ length: Int) throws -> Data {
        guard length >= 0, length <= remaining else { throw IdentityError.malformedKey }
        defer { offset += length }
        return data.subdata(in: offset..<(offset + length))
    }
    mutating func integer() throws -> UInt32 {
        try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    mutating func field() throws -> Data { try take(Int(integer())) }
    mutating func string() throws -> String {
        guard let value = String(data: try field(), encoding: .utf8) else { throw IdentityError.malformedKey }
        return value
    }
}
