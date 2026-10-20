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
        case .malformedKey: return "This private key is malformed or damaged. Choose a complete OpenSSH Ed25519 private key."
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
        enum Format: String, Codable { case generatedEd25519, importedOpenSSH }
        let version: Int
        let format: Format
        let bytes: Data
    }

    private let secretStore: any IdentitySecretStore
    /// Nil where biometric Keychain items are unavailable, such as the macOS test host.
    private let biometricStore: (any BiometricKeyStore)?
    private var unlocked: [UUID: Curve25519.Signing.PrivateKey] = [:]
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
        let metadata = try makeMetadata(name: name, key: key, requiresPassphrase: false)
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

    public func unlock(_ metadata: IdentityMetadata, passphrase: String? = nil) async throws -> Curve25519.Signing.PrivateKey {
        if let key = unlocked[metadata.id] { return key }
        let data = try secretStore.load(reference: metadata.keychainReference)
        guard let secret = try? JSONDecoder().decode(StoredSecret.self, from: data), secret.version == 1 else {
            throw IdentityError.malformedKey
        }
        let generation = sessionGeneration
        let key = try await Task.detached(priority: .userInitiated) {
            switch secret.format {
            case .generatedEd25519:
                return try Curve25519.Signing.PrivateKey(rawRepresentation: secret.bytes)
            case .importedOpenSSH:
                guard let text = String(data: secret.bytes, encoding: .utf8) else { throw IdentityError.malformedKey }
                return try OpenSSHIdentityParser.parse(text, passphrase: passphrase).key
            }
        }.value
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw IdentityError.sessionEnded }
        guard String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) == metadata.publicKey else {
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

    /// Whether this identity can be unlocked with Face ID or Touch ID. Never prompts.
    public func hasBiometricUnlock(_ metadata: IdentityMetadata) -> Bool {
        biometricStore?.contains(reference: metadata.keychainReference) ?? false
    }

    /// Keeps this encrypted identity's unlocked key behind the currently enrolled biometrics. It must
    /// already be unlocked with its passphrase in this session; the passphrase itself is never stored.
    public func enableBiometricUnlock(_ metadata: IdentityMetadata) throws {
        guard metadata.requiresPassphrase, let key = unlocked[metadata.id] else { throw IdentityError.missingPassphrase }
        guard let biometricStore else { throw IdentityError.biometricsUnavailable }
        let secret = StoredSecret(version: 1, format: .generatedEd25519, bytes: key.rawRepresentation)
        try biometricStore.save(JSONEncoder().encode(secret), reference: metadata.keychainReference)
    }

    public func disableBiometricUnlock(_ metadata: IdentityMetadata) throws {
        try biometricStore?.delete(reference: metadata.keychainReference)
    }

    /// Unlocks with Face ID or Touch ID for this foreground session. Throws `biometricsUnavailable`
    /// when there is no usable copy, and `biometricsDeclined` when authentication is cancelled or fails;
    /// either way the passphrase still unlocks the original.
    public func unlockWithBiometrics(_ metadata: IdentityMetadata, reason: String) async throws -> Curve25519.Signing.PrivateKey {
        if let key = unlocked[metadata.id] { return key }
        guard let biometricStore else { throw IdentityError.biometricsUnavailable }
        let generation = sessionGeneration
        let data = try await biometricStore.load(reference: metadata.keychainReference, reason: reason)
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw IdentityError.sessionEnded }
        guard let secret = try? JSONDecoder().decode(StoredSecret.self, from: data), secret.version == 1,
              secret.format == .generatedEd25519,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret.bytes),
              String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) == metadata.publicKey else {
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

    private func makeMetadata(name: String, key: Curve25519.Signing.PrivateKey, requiresPassphrase: Bool) throws -> IdentityMetadata {
        let details = try HostKeyDetails(publicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
        let id = UUID()
        return IdentityMetadata(id: id, name: name, algorithm: details.algorithm, publicKey: details.publicKey,
                                fingerprint: details.fingerprint, requiresPassphrase: requiresPassphrase,
                                keychainReference: id.uuidString)
    }
}

/// Reads only the bounded OpenSSH container header to give useful errors and constrain the
/// supported matrix. Citadel performs all private-key parsing, KDF work, and decryption.
enum OpenSSHIdentityParser {
    struct Parsed { let key: Curve25519.Signing.PrivateKey; let encrypted: Bool }

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
            if text.hasPrefix("-----BEGIN") { throw IdentityError.unsupportedFormat("Use an OpenSSH Ed25519 private key.") }
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
        guard try publicReader.string() == "ssh-ed25519" else {
            throw IdentityError.unsupportedFormat("Only Ed25519 identities are supported in this preview.")
        }
        let publicKey: NIOSSHPublicKey
        do { publicKey = try NIOSSHPublicKey(openSSHPublicKey: "ssh-ed25519 " + publicBytes.base64EncodedString()) }
        catch { throw IdentityError.malformedKey }
        let privateBytes = try reader.field()
        guard !privateBytes.isEmpty, reader.remaining == 0, privateBytes.count % (encrypted ? 16 : 8) == 0 else {
            throw IdentityError.malformedKey
        }
        if encrypted && (passphrase == nil || passphrase?.isEmpty == true) { throw IdentityError.missingPassphrase }
        // Citadel accepts LF wrapping; normalise container whitespace only for parsing.
        let normalised = begin + "\n" + body + "\n" + end + "\n"
        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(sshEd25519: normalised,
                    decryptionKey: encrypted ? passphrase.map { Data($0.utf8) } : nil)
        } catch {
            throw encrypted ? IdentityError.decryptionFailed : IdentityError.malformedKey
        }
        guard NIOSSHPrivateKey(ed25519Key: key).publicKey == publicKey else { throw IdentityError.malformedKey }
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
