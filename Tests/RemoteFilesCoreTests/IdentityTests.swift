import XCTest
import Foundation
import Security
import Crypto
import NIOSSH
@testable import RemoteFilesCore

private final class MemorySecrets: IdentitySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    func save(_ data: Data, reference: String) throws {
        lock.lock(); defer { lock.unlock() }; storage[reference] = data
    }
    func load(reference: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = storage[reference] else { throw IdentityError.missingSecret }
        return data
    }
    func delete(reference: String) throws {
        lock.lock(); defer { lock.unlock() }; storage.removeValue(forKey: reference)
    }
}

final class IdentityTests: XCTestCase {
    func testGeneratedKeyHasCanonicalPublicKeyAndSecretFreeMetadata() async throws {
        let secrets = MemorySecrets()
        let store = IdentityStore(secretStore: secrets)
        let metadata = try await store.generate(name: "Preview identity")
        let key = try await store.unlock(metadata)
        XCTAssertEqual(metadata.publicKey, String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey))
        XCTAssertTrue(metadata.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(metadata.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(metadata.requiresPassphrase)
        let document = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        XCTAssertFalse(document.contains("PRIVATE KEY"))
        XCTAssertFalse(document.contains(key.rawRepresentation.base64EncodedString()))
        let restored = try JSONDecoder().decode(IdentityMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(restored, metadata)
        do {
            try await store.delete(metadata, referencedBy: [metadata.id])
            XCTFail("An identity in use must not be deleted")
        } catch { XCTAssertEqual(error as? IdentityError, .identityInUse) }
        try await store.delete(metadata, referencedBy: [])
        do {
            _ = try await store.unlock(metadata)
            XCTFail("Deleted identity must be unavailable")
        } catch { XCTAssertEqual(error as? IdentityError, .missingSecret) }
    }

    func testPublicOnlyAndMalformedInputHaveSpecificErrors() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
        XCTAssertThrowsError(try OpenSSHIdentityParser.parse(publicKey, passphrase: nil)) {
            XCTAssertEqual($0 as? IdentityError, .publicKeyOnly)
        }
        for value in ["", "not a private key", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"] {
            XCTAssertThrowsError(try OpenSSHIdentityParser.parse(value, passphrase: nil)) {
                XCTAssertEqual($0 as? IdentityError, .malformedKey)
            }
        }
    }

    func testTrustRequiresAcceptancePersistsAndNeverSilentlyReplacesAKey() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("trusted-hosts.json")
        let store = try HostTrustStore(fileURL: url)
        let endpoint = HostEndpoint(host: "TEST.EXAMPLE", port: 2222)
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let replacement = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let details = try HostKeyDetails(publicKey: key)
        do {
            try await store.validate(endpoint: endpoint, publicKey: key)
            XCTFail("Unknown hosts must block")
        } catch HostTrustError.unknown(let actualEndpoint, let actualDetails) {
            XCTAssertEqual(actualEndpoint, endpoint); XCTAssertEqual(actualDetails, details)
        }
        try await store.trustUnknown(endpoint: endpoint, key: details)
        try await store.validate(endpoint: endpoint, publicKey: key)
        let restored = try HostTrustStore(fileURL: url)
        try await restored.validate(endpoint: HostEndpoint(host: "test.example", port: 2222), publicKey: key)
        do {
            try await restored.validate(endpoint: endpoint, publicKey: replacement)
            XCTFail("Changed hosts must block")
        } catch HostTrustError.changed(_, let previous, let current) {
            XCTAssertEqual(previous, details); XCTAssertNotEqual(current.fingerprint, details.fingerprint)
        }
        do {
            try await restored.trustUnknown(endpoint: endpoint, key: HostKeyDetails(publicKey: replacement))
            XCTFail("Trust acceptance must not replace a changed key")
        } catch HostTrustError.changed { }
        try await restored.reset(endpoint: endpoint)
        do {
            try await restored.validate(endpoint: endpoint, publicKey: replacement)
            XCTFail("Reset must still require fresh trust acceptance")
        } catch HostTrustError.unknown { }
    }

    func testCorruptTrustStoreBlocksInsteadOfForgettingTrust() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try HostTrustStore(fileURL: url)) {
            guard case HostTrustError.invalidStore = $0 else { return XCTFail("Expected invalid-store error") }
        }
    }

    #if os(iOS)
    func testDeviceKeychainPersistenceAndAccessibility() async throws {
        let service = "app.remotefiles.tests." + UUID().uuidString
        let secrets = KeychainIdentitySecretStore(service: service)
        let store = IdentityStore(secretStore: secrets)
        let identity = try await store.generate(name: "Temporary device Keychain test")
        defer { try? secrets.delete(reference: identity.keychainReference) }
        let first = try await store.unlock(identity)
        await store.clearSession()
        // A distinct store has no foreground cache and must read the actual Keychain item.
        let reopened = IdentityStore(secretStore: KeychainIdentitySecretStore(service: service))
        let second = try await reopened.unlock(identity)
        let probe = Data("Keychain persistence verification".utf8)
        XCTAssertTrue(second.publicKey.isValidSignature(try first.signature(for: probe), for: probe))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identity.keychainReference,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
        await reopened.clearSession()
        try await reopened.delete(identity, referencedBy: [])
        XCTAssertThrowsError(try secrets.load(reference: identity.keychainReference)) {
            XCTAssertEqual($0 as? IdentityError, .missingSecret)
        }
    }
    #endif

    #if os(macOS)
    /// Independent system ssh-keygen produces every private fixture at runtime; none is checked in.
    func testSystemSSHKeygenImportMatrixAndSessionClearing() async throws {
        try await withGeneratedKey(passphrase: "") { text, publicKey, fingerprint in
            let store = IdentityStore(secretStore: MemorySecrets())
            let metadata = try await store.importKey(name: "Unencrypted", openSSH: text)
            XCTAssertFalse(metadata.requiresPassphrase)
            XCTAssertEqual(metadata.publicKey, publicKey)
            XCTAssertEqual(metadata.fingerprint, fingerprint)
            _ = try await store.unlock(metadata)
        }
        try await withGeneratedKey(passphrase: "fixture-only-passphrase") { text, publicKey, fingerprint in
            let secrets = MemorySecrets()
            let store = IdentityStore(secretStore: secrets)
            for (passphrase, expected) in [(nil, IdentityError.missingPassphrase), ("wrong", .decryptionFailed)] {
                do {
                    _ = try await store.importKey(name: "Encrypted", openSSH: text, passphrase: passphrase)
                    XCTFail("Invalid or absent passphrase must not import")
                } catch { XCTAssertEqual(error as? IdentityError, expected) }
            }
            let metadata = try await store.importKey(name: "Encrypted", openSSH: text, passphrase: "fixture-only-passphrase")
            XCTAssertTrue(metadata.requiresPassphrase)
            XCTAssertEqual(metadata.publicKey, publicKey)
            XCTAssertEqual(metadata.fingerprint, fingerprint)
            let stored = try JSONSerialization.jsonObject(with: secrets.load(reference: metadata.keychainReference)) as? [String: Any]
            // Compare as a boolean so a failure never prints the key material.
            XCTAssertTrue((stored?["bytes"] as? String) == Data(text.utf8).base64EncodedString(), "Encrypted representation must be preserved")
            do {
                _ = try await store.unlock(metadata)
                XCTFail("Import should not retain an unlocked key")
            } catch { XCTAssertEqual(error as? IdentityError, .missingPassphrase) }
            _ = try await store.unlock(metadata, passphrase: "fixture-only-passphrase")
            _ = try await store.unlock(metadata) // Reuse only during the foreground session.
            await store.clearSession()
            do {
                _ = try await store.unlock(metadata)
                XCTFail("Cleared session must ask for a passphrase again")
            } catch { XCTAssertEqual(error as? IdentityError, .missingPassphrase) }
        }
        try await withGeneratedKey(passphrase: "fixture-only-passphrase", options: ["-Z", "aes128-ctr"]) { text, _, _ in
            let result = try OpenSSHIdentityParser.parse(text, passphrase: "fixture-only-passphrase")
            XCTAssertTrue(result.encrypted)
        }
        try await withGeneratedKey(passphrase: "fixture-only-passphrase", options: ["-a", "32"]) { text, _, _ in
            XCTAssertThrowsError(try OpenSSHIdentityParser.parse(text, passphrase: "fixture-only-passphrase")) {
                guard case IdentityError.unsupportedFormat = $0 else { return XCTFail("Expected unsupported bcrypt configuration") }
            }
        }
        try await withGeneratedKey(passphrase: "fixture-only-passphrase", options: ["-Z", "aes256-cbc"]) { text, _, _ in
            XCTAssertThrowsError(try OpenSSHIdentityParser.parse(text, passphrase: "fixture-only-passphrase")) {
                guard case IdentityError.unsupportedFormat = $0 else { return XCTFail("Expected unsupported encryption") }
            }
        }
    }

    private func withGeneratedKey(passphrase: String, options: [String] = [],
                                  body: (String, String, String) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = folder.appendingPathComponent("id_ed25519")
        _ = try runSSHKeygen(["-q", "-t", "ed25519", "-N", passphrase, "-C", "", "-f", key.path] + options)
        let text = try String(contentsOf: key, encoding: .utf8)
        let publicFields = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8).split(separator: " ")
        let publicKey = publicFields.prefix(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try runSSHKeygen(["-l", "-E", "sha256", "-f", key.appendingPathExtension("pub").path])
        let fingerprint = String(result.split(separator: " ")[1])
        try await body(text, publicKey, fingerprint)
    }

    private func runSSHKeygen(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IdentityError.unsupportedFormat("The system key fixture command failed.") }
        return String(decoding: data, as: UTF8.self)
    }
    #endif
}
