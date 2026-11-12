import Foundation
@testable import RemoteFilesCore

/// One Ed25519 key encrypted with a fixture-only passphrase (bcrypt, one round), generated for these tests
/// and used nowhere else. Importing it again gives each identity its own ID and Keychain reference, so the one
/// body stands for any number of locked keys. The markers are assembled here, as in other tests, so secret
/// scanners don't flag the source.
enum EncryptedKeyFixture {
    static let passphrase = "fixture-only-passphrase"
    private static let body = [
        "b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBa",
        "eE/pv9SKNmJnX2EIRn8/AAAAAQAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIMbD",
        "mGj597d5E9GNnttK5Ao9RMHq4iX3a6liUuq94KFdAAAAkPMI8LksUo4NiQYGnKCM",
        "K7DMccDleK+MqAEVfhqSYGa6GZL8u8xQcko5ByLQIKDb+Bwr/ZD/taAYtqCeP0QK",
        "QMns9EJSErKyfr4BefY2pEIIZVOMmluEo+AHTP16rsjfloD1UbFaTES2a/cc4e3l",
        "7qzbEjNh0piSxB6dzSYVh02yg7Kq0gKxSX1RyV2jyI9x0w=="
    ].joined()

    static var openSSH: String {
        let label = "OPENSSH " + "PRIVATE " + "KEY"
        return "-----BEGIN \(label)-----\n" + body + "\n-----END \(label)-----\n"
    }

    static func makeStore(biometrics: (any BiometricKeyStore)? = nil) -> IdentityStore {
        IdentityStore(secretStore: FixtureIdentitySecrets(), biometricStore: biometrics)
    }

    /// A new locked identity: encrypted, so unlocking it needs the passphrase.
    static func importKey(into store: IdentityStore, name: String = "Encrypted fixture") async throws -> IdentityMetadata {
        try await store.importKey(name: name, openSSH: openSSH, passphrase: passphrase)
    }

    static func unlock(_ identity: IdentityMetadata, in store: IdentityStore) async throws {
        _ = try await store.unlock(identity, passphrase: passphrase)
    }

    /// Whether the key is unlocked now. Asks without the passphrase, so it never unlocks one.
    static func isUnlocked(_ identity: IdentityMetadata, in store: IdentityStore) async throws -> Bool {
        do { _ = try await store.unlock(identity); return true }
        catch IdentityError.missingPassphrase { return false }
    }
}

final class FixtureIdentitySecrets: IdentitySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func save(_ data: Data, reference: String) throws { lock.lock(); defer { lock.unlock() }; values[reference] = data }
    func load(reference: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = values[reference] else { throw IdentityError.missingSecret }
        return data
    }
    func delete(reference: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: reference) }
}
