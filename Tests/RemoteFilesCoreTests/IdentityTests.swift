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
    func testTrustStoreWritesUseCompleteFileProtection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("known-hosts-v1.json")
        let store = try HostTrustStore(fileURL: url)
        let endpoint = HostEndpoint(host: "protected.example", port: 22)
        let key = try HostKeyDetails(publicKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey)
        func protection(_ file: URL = url) throws -> FileProtectionType? {
            try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType
        }
        // The Simulator's filesystem reports no Data Protection class even for explicitly protected
        // writes, so this assertion is only meaningful on a physical device.
        let control = folder.appendingPathComponent("control")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("control".utf8).write(to: control, options: [.atomic, .completeFileProtection])
        guard try protection(control) != nil else {
            throw XCTSkip("This platform does not report Data Protection classes; run on a physical device.")
        }
        try await store.trustUnknown(endpoint: endpoint, key: key)
        XCTAssertEqual(try protection(), .complete)
        // Reset rewrites the file atomically, which must not drop the protection class.
        try await store.reset(endpoint: endpoint)
        XCTAssertEqual(try protection(), .complete)
    }

    func testBiometricKeychainItemIsStoredWithoutPromptingAndRemovable() throws {
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription"),
                        "Face ID needs a usage description before it can prompt")
        let store = KeychainBiometricKeyStore(service: "dev.iris.RemoteFilesTests.biometric")
        let reference = UUID().uuidString
        do { try store.save(Data("seed".utf8), reference: reference) }
        catch IdentityError.keychain(let status) {
            // Saving requires a device passcode, which the Simulator does not have.
            throw XCTSkip("This device cannot hold passcode-protected biometric items (status \(status)); run on a physical device.")
        }
        defer { try? store.delete(reference: reference) }
        XCTAssertTrue(store.contains(reference: reference), "Checking for the copy must not need Face ID")
        try store.save(Data("replacement".utf8), reference: reference)
        XCTAssertTrue(store.contains(reference: reference))
        try store.delete(reference: reference)
        XCTAssertFalse(store.contains(reference: reference))
        XCTAssertNoThrow(try store.delete(reference: reference), "Deleting twice is not an error")
    }

    /// Opt-in: the Simulator must have Face ID enrolled, and the host must send a match while the prompt shows.
    func testSimulatedFaceIDReadsTheStoredKey() async throws {
        guard ProcessInfo.processInfo.environment["REMOTEFILES_BIOMETRIC_SIMULATION"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_REMOTEFILES_BIOMETRIC_SIMULATION=1 and send a Face ID match from the host.")
        }
        let store = KeychainBiometricKeyStore(service: "dev.iris.RemoteFilesTests.biometric")
        let reference = UUID().uuidString
        try store.save(Data("seed".utf8), reference: reference)
        defer { try? store.delete(reference: reference) }
        print("BIOMETRIC_PROMPT_READY")
        let data = try await store.load(reference: reference, reason: "Unlock the test key.")
        XCTAssertEqual(data, Data("seed".utf8))
    }

    /// Opt-in physical-device check, two phases: `save` stores a copy, then add or remove a Face ID
    /// appearance in Settings, and `read` must find the copy unusable even with a matching face.
    /// The Simulator cannot run it: re-enrolling there leaves the biometric domain state unchanged.
    func testSimulatedEnrolmentChangeInvalidatesTheStoredKey() async throws {
        let phase = ProcessInfo.processInfo.environment["REMOTEFILES_BIOMETRIC_ENROLMENT_PHASE"]
        guard let phase else { throw XCTSkip("Set TEST_RUNNER_REMOTEFILES_BIOMETRIC_ENROLMENT_PHASE to save, then read.") }
        let store = KeychainBiometricKeyStore(service: "dev.iris.RemoteFilesTests.biometric")
        let reference = "enrolment-change-check"
        if phase == "save" {
            try store.save(Data("seed".utf8), reference: reference)
            XCTAssertTrue(store.contains(reference: reference))
            return
        }
        defer { try? store.delete(reference: reference) }
        print("BIOMETRIC_PROMPT_READY")
        do {
            _ = try await store.load(reference: reference, reason: "Unlock the test key.")
            XCTFail("A copy saved before an enrolment change must not be readable")
        } catch IdentityError.biometricsUnavailable { }
    }

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

/// Biometric Keychain stand-in: records prompts and can decline, lose its item, or pause a load.
private final class FakeBiometricStore: BiometricKeyStore, @unchecked Sendable {
    enum Outcome { case authenticate, decline, unavailable }
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var gate: CheckedContinuation<Void, Never>?
    var outcome = Outcome.authenticate
    var failDelete = false
    var pauseLoads = false
    private(set) var prompts = 0
    func stored(_ reference: String) -> Data? { lock.lock(); defer { lock.unlock() }; return storage[reference] }
    func replace(_ reference: String, with data: Data) { lock.lock(); storage[reference] = data; lock.unlock() }
    func save(_ data: Data, reference: String) throws { replace(reference, with: data) }
    func load(reference: String, reason: String) async throws -> Data {
        lock.lock(); prompts += 1; let paused = pauseLoads; lock.unlock()
        if paused { await withCheckedContinuation { continuation in lock.lock(); gate = continuation; lock.unlock() } }
        switch outcome {
        case .decline: throw IdentityError.biometricsDeclined
        case .unavailable: throw IdentityError.biometricsUnavailable
        case .authenticate:
            guard let data = stored(reference) else { throw IdentityError.biometricsUnavailable }
            return data
        }
    }
    func resume() { lock.lock(); let waiting = gate; gate = nil; lock.unlock(); waiting?.resume() }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return gate != nil }
    func contains(reference: String) -> Bool { stored(reference) != nil }
    func delete(reference: String) throws {
        if failDelete { throw IdentityError.keychain(errSecIO) }
        lock.lock(); storage.removeValue(forKey: reference); lock.unlock()
    }
}

final class BiometricUnlockTests: XCTestCase {
    /// A generated key marked as passphrase-protected stands in for an encrypted import.
    private func encryptedIdentity(_ store: IdentityStore) async throws -> IdentityMetadata {
        let generated = try await store.generate(name: "Encrypted stand-in")
        return IdentityMetadata(id: generated.id, name: generated.name, algorithm: generated.algorithm, publicKey: generated.publicKey,
                                fingerprint: generated.fingerprint, requiresPassphrase: true, keychainReference: generated.keychainReference)
    }

    func testEnablingNeedsAnUnlockedEncryptedKeyAndStoresOnlyTheKey() async throws {
        let biometrics = FakeBiometricStore(), store = IdentityStore(secretStore: MemorySecrets(), biometricStore: biometrics)
        let identity = try await encryptedIdentity(store)
        do { try await store.enableBiometricUnlock(identity); XCTFail("A locked key cannot be stored") }
        catch IdentityError.missingPassphrase { }
        let key = try await store.unlock(identity)
        try await store.enableBiometricUnlock(identity)
        let hasUnlock = await store.hasBiometricUnlock(identity)
        XCTAssertTrue(hasUnlock)
        let stored = try XCTUnwrap(biometrics.stored(identity.keychainReference))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["version", "format", "bytes"], "Only the key itself is stored")
        XCTAssertEqual((fields["bytes"] as? String).flatMap { Data(base64Encoded: $0) }, key.rawRepresentation)

        let plain = try await store.generate(name: "Unencrypted")
        _ = try await store.unlock(plain)
        do { try await store.enableBiometricUnlock(plain); XCTFail("Unencrypted keys have no passphrase to replace") }
        catch IdentityError.missingPassphrase { }
    }

    func testFaceIDUnlockReturnsTheSameKeyEachForegroundSession() async throws {
        let biometrics = FakeBiometricStore(), store = IdentityStore(secretStore: MemorySecrets(), biometricStore: biometrics)
        let identity = try await encryptedIdentity(store)
        let key = try await store.unlock(identity)
        try await store.enableBiometricUnlock(identity)
        await store.clearSession()
        let unlocked = try await store.unlockWithBiometrics(identity, reason: "Connect")
        XCTAssertEqual(unlocked.rawRepresentation, key.rawRepresentation)
        _ = try await store.unlockWithBiometrics(identity, reason: "Connect")
        XCTAssertEqual(biometrics.prompts, 1, "An unlocked key is reused within the session")
        let cached = try await store.unlock(identity)
        XCTAssertEqual(cached.rawRepresentation, key.rawRepresentation, "Connections use the Face ID-unlocked key")
        await store.clearSession()
        _ = try await store.unlockWithBiometrics(identity, reason: "Connect")
        XCTAssertEqual(biometrics.prompts, 2, "Backgrounding still clears the unlocked key")
    }

    func testDeclinedUnavailableAndMismatchedCopiesFallBackToThePassphrase() async throws {
        let biometrics = FakeBiometricStore(), store = IdentityStore(secretStore: MemorySecrets(), biometricStore: biometrics)
        let identity = try await encryptedIdentity(store)
        _ = try await store.unlock(identity)
        try await store.enableBiometricUnlock(identity)
        await store.clearSession()
        biometrics.outcome = .decline
        do { _ = try await store.unlockWithBiometrics(identity, reason: "Connect"); XCTFail() } catch IdentityError.biometricsDeclined { }
        biometrics.outcome = .unavailable
        do { _ = try await store.unlockWithBiometrics(identity, reason: "Connect"); XCTFail() } catch IdentityError.biometricsUnavailable { }

        biometrics.outcome = .authenticate
        let foreign = Curve25519.Signing.PrivateKey().rawRepresentation
        biometrics.replace(identity.keychainReference,
                           with: Data(#"{"version":1,"format":"generatedEd25519","bytes":"\#(foreign.base64EncodedString())"}"#.utf8))
        do { _ = try await store.unlockWithBiometrics(identity, reason: "Connect"); XCTFail("A different key must never be used") }
        catch IdentityError.biometricsUnavailable { }
        XCTAssertNil(biometrics.stored(identity.keychainReference), "The mismatched copy is removed")
        let promptsBefore = biometrics.prompts
        do { _ = try await store.unlockWithBiometrics(identity, reason: "Connect"); XCTFail("Nothing was unlocked") }
        catch IdentityError.biometricsUnavailable { }
        XCTAssertEqual(biometrics.prompts, promptsBefore + 1, "No key was cached by the rejected copy")

        let noBiometrics = IdentityStore(secretStore: MemorySecrets(), biometricStore: nil)
        let other = try await encryptedIdentity(noBiometrics)
        let available = await noBiometrics.hasBiometricUnlock(other)
        XCTAssertFalse(available)
        do { _ = try await noBiometrics.unlockWithBiometrics(other, reason: "Connect"); XCTFail() } catch IdentityError.biometricsUnavailable { }
    }

    func testBackgroundingDuringFaceIDLeavesNothingUnlocked() async throws {
        let biometrics = FakeBiometricStore(), store = IdentityStore(secretStore: MemorySecrets(), biometricStore: biometrics)
        let identity = try await encryptedIdentity(store)
        _ = try await store.unlock(identity)
        try await store.enableBiometricUnlock(identity)
        await store.clearSession()
        biometrics.pauseLoads = true
        let unlock = Task { try await store.unlockWithBiometrics(identity, reason: "Connect") }
        for _ in 0..<200 where !biometrics.isPaused { try await Task.sleep(for: .milliseconds(5)) }
        await store.clearSession()
        biometrics.resume()
        do { _ = try await unlock.value; XCTFail("A superseded unlock must not complete") } catch IdentityError.sessionEnded { }
        biometrics.pauseLoads = false
        _ = try await store.unlockWithBiometrics(identity, reason: "Connect")
        XCTAssertEqual(biometrics.prompts, 2, "The superseded unlock cached nothing, so Face ID is asked again")
    }

    func testDeletingAnIdentityRemovesItsFaceIDCopyFirst() async throws {
        let biometrics = FakeBiometricStore(), secrets = MemorySecrets()
        let store = IdentityStore(secretStore: secrets, biometricStore: biometrics)
        let identity = try await encryptedIdentity(store)
        _ = try await store.unlock(identity)
        try await store.enableBiometricUnlock(identity)
        biometrics.failDelete = true
        do { try await store.delete(identity, referencedBy: []); XCTFail() } catch IdentityError.keychain { }
        XCTAssertNoThrow(try secrets.load(reference: identity.keychainReference), "The identity survives a failed cleanup")
        biometrics.failDelete = false
        try await store.delete(identity, referencedBy: [])
        XCTAssertNil(biometrics.stored(identity.keychainReference))
        XCTAssertThrowsError(try secrets.load(reference: identity.keychainReference))

        let kept = try await encryptedIdentity(store)
        _ = try await store.unlock(kept)
        try await store.enableBiometricUnlock(kept)
        try await store.disableBiometricUnlock(kept)
        let stillEnabled = await store.hasBiometricUnlock(kept)
        XCTAssertFalse(stillEnabled)
    }
}
