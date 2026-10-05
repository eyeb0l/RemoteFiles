import XCTest
import Foundation
import Crypto
import NIOSSH
import NIOCore
import NIOPosix
import Citadel
@testable import RemoteFilesCore

final class PublicKeyInstallerTests: XCTestCase {
    func testPasswordDiscoveryDoesNotOfferPasswordUntilServerAdvertisesItAndDistinguishesRejection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        addTeardownBlock { try await group.shutdownGracefully() }
        let loop = group.next()
        func next(_ authentication: SSHAuthenticationMethod, methods: NIOSSHAvailableUserAuthenticationMethods) async throws -> NIOSSHUserAuthenticationOffer? {
            let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
            loop.execute { authentication.nextAuthenticationType(availableMethods: methods, nextChallengePromise: promise) }
            return try await promise.futureResult.get()
        }
        let disabled = SSHAuthenticationMethod.passwordBased(username: "fixture", password: "owned-fixture-password", discoverMethods: true)
        let discovered = try await next(disabled, methods: .all)
        let discovery = try XCTUnwrap(discovered)
        guard case .none = discovery.offer else { XCTFail("Discovery must not send the password"); return }
        XCTAssertFalse(disabled.hasOfferedPassword, "A server accepting discovery alone must not authorize this password-only installer")
        do { _ = try await next(disabled, methods: .publicKey); XCTFail("Password-disabled server must block before a password offer") }
        catch SSHClientError.unsupportedPasswordAuthentication { }
        let enabled = SSHAuthenticationMethod.passwordBased(username: "fixture", password: "owned-fixture-password", discoverMethods: true)
        _ = try await next(enabled, methods: .all)
        let offered = try await next(enabled, methods: .password)
        let offer = try XCTUnwrap(offered)
        guard case .password(let password) = offer.offer else { XCTFail("An advertised password method must receive a password offer"); return }
        XCTAssertTrue(enabled.hasOfferedPassword)
        XCTAssertEqual(offer.username, "fixture"); XCTAssertEqual(password.password, "owned-fixture-password")
        do { _ = try await next(enabled, methods: .password); XCTFail("A rejected password must not be offered repeatedly") }
        catch SSHClientError.allAuthenticationOptionsFailed { }
    }

    private func identity(seed: UInt8 = 7, comment: String = "") throws -> IdentityMetadata {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        return .init(name: "Fixture public identity", publicKey: String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) + comment,
                     fingerprint: "untrusted metadata fingerprint", requiresPassphrase: true, keychainReference: "private-material-never-read")
    }
    private func request(seed: UInt8 = 7, comment: String = "") throws -> PublicKeyInstallationRequest {
        try .init(host: "fixture.invalid", port: 22222, username: "fixture", identity: identity(seed: seed, comment: comment))
    }
    func testReviewCanonicalizesOnlyPublicMaterialAndRecomputesFingerprint() throws {
        let value = try request(comment: " RemoteFiles fixture")
        XCTAssertEqual(value.publicKey.split(separator: " ").count, 2)
        XCTAssertTrue(value.fingerprint.hasPrefix("SHA256:"))
        XCTAssertEqual(value.account, "fixture@fixture.invalid:22222")
        let command = PublicKeyInstallCommand.command(value)
        XCTAssertTrue(command.contains(value.publicKey))
        XCTAssertFalse(command.contains("private-material-never-read"))
        XCTAssertFalse(command.contains(value.username + "@"))
        XCTAssertFalse(command.contains("RemoteFiles fixture"))
    }
    func testMalformedPrivateMultilineKeysAndTargetsAreRejectedBeforeTransport() throws {
        for text in ["-----BEGIN OPENSSH PRIVATE KEY-----", "ssh-ed25519 broken", try identity().publicKey + "\ncommand=bad", try identity().publicKey + "\0"] {
            let key = IdentityMetadata(name: "Bad", publicKey: text, fingerprint: "", requiresPassphrase: false, keychainReference: "")
            XCTAssertThrowsError(try PublicKeyInstallationRequest(host: "fixture.invalid", port: 22, username: "fixture", identity: key))
        }
        for host in ["", "a\nb", "server/path", "server\0"] {
            XCTAssertThrowsError(try PublicKeyInstallationRequest(host: host, port: 22, username: "fixture", identity: identity()))
        }
        XCTAssertThrowsError(try PublicKeyInstallationRequest(host: "fixture.invalid", port: 0, username: "fixture", identity: identity()))
        XCTAssertThrowsError(try PublicKeyInstallationRequest(host: "fixture.invalid", port: 22, username: "", identity: identity()))
    }
    func testUnexpectedOrMissingServerReplyNeverReportsConfirmedInstallation() throws {
        XCTAssertEqual(try PublicKeyInstallCommand.result("REMOTEFILES_KEY_INSTALLED\n"), .installed)
        XCTAssertEqual(try PublicKeyInstallCommand.result("REMOTEFILES_KEY_PRESENT\n"), .alreadyInstalled)
        for output in ["", "ok", "REMOTEFILES_KEY_INSTALLED\nerror", "REMOTEFILES_KEY_PRESENT_FAKE"] {
            XCTAssertThrowsError(try PublicKeyInstallCommand.result(output))
        }
    }
    #if os(macOS)
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFiles-key-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func run(_ request: PublicKeyInstallationRequest, home: URL) throws -> (Int32, String) {
        // Redirect only the script's home lookup; never replace the process/system HOME.
        let script = PublicKeyInstallCommand.script.replacingOccurrences(of: "${HOME:-}", with: "${REMOTEFILES_FIXTURE_HOME:-}")
            .replacingOccurrences(of: "$HOME", with: "$REMOTEFILES_FIXTURE_HOME")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "remotefiles", request.publicKey]
        var environment = ProcessInfo.processInfo.environment; environment["REMOTEFILES_FIXTURE_HOME"] = home.path
        process.environment = environment
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    func testOwnedLocalFixtureFirstInstallRepeatAndPreserveExistingBytesWithoutNewline() throws {
        let home = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh"); try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = ssh.appendingPathComponent("authorized_keys")
        let original = Data((try request(seed: 9).publicKey + " previous-key-without-newline").utf8)
        try original.write(to: file)
        let first = try run(request(), home: home)
        XCTAssertEqual(first.0, 0); XCTAssertEqual(try PublicKeyInstallCommand.result(first.1), .installed)
        let added = try Data(contentsOf: file); XCTAssertEqual(added.prefix(original.count), original)
        XCTAssertTrue(String(decoding: added, as: UTF8.self).hasSuffix(try request().publicKey + "\n"))
        let second = try run(request(), home: home)
        XCTAssertEqual(second.0, 0); XCTAssertEqual(try PublicKeyInstallCommand.result(second.1), .alreadyInstalled)
        XCTAssertEqual(try Data(contentsOf: file), added)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ssh.appendingPathComponent(".remotefiles-key-install.lock").path))
    }
    func testOwnedLocalFixtureRestrictedDuplicateAndCommentMentionAreDistinguished() throws {
        let home = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh"); try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = ssh.appendingPathComponent("authorized_keys"); let key = try request().publicKey
        let restricted = Data(("command=\"echo hello world\",no-pty " + key + " fixture\r\n").utf8)
        try restricted.write(to: file)
        let duplicate = try run(request(), home: home)
        XCTAssertEqual(duplicate.0, 0); XCTAssertEqual(try PublicKeyInstallCommand.result(duplicate.1), .alreadyInstalled)
        XCTAssertEqual(try Data(contentsOf: file), restricted)
        let other = try request(seed: 9).publicKey
        let mentioned = Data((other + " comment mentions " + key + "\n# " + key + "\n").utf8)
        try mentioned.write(to: file)
        let installed = try run(request(), home: home)
        XCTAssertEqual(installed.0, 0); XCTAssertEqual(try PublicKeyInstallCommand.result(installed.1), .installed)
        XCTAssertEqual(try Data(contentsOf: file).prefix(mentioned.count), mentioned)
    }
    func testOwnedLocalFixtureSymlinkAndBusyLockFailWithoutChangingExistingBytes() throws {
        let home = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh"); try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let original = home.appendingPathComponent("original"); let bytes = Data("owned untouched fixture".utf8); try bytes.write(to: original)
        let file = ssh.appendingPathComponent("authorized_keys"); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        XCTAssertEqual(try run(request(), home: home).0, 70); XCTAssertEqual(try Data(contentsOf: original), bytes)
        try FileManager.default.removeItem(at: file); try bytes.write(to: file)
        let lock = ssh.appendingPathComponent(".remotefiles-key-install.lock"); try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        XCTAssertEqual(try run(request(), home: home).0, 71); XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "Never remove another operation’s lock")
    }
    func testOwnedLocalFixtureInterruptedPartialAppendIsSafelyRetried() throws {
        let home = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh"); try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = ssh.appendingPathComponent("authorized_keys")
        let previous = try request(seed: 9).publicKey
        let partial = Data((previous + "\nssh-ed25519 AAAAC3NzaC1lZDI1").utf8); try partial.write(to: file)
        let retry = try run(request(), home: home)
        XCTAssertEqual(retry.0, 0); XCTAssertEqual(try PublicKeyInstallCommand.result(retry.1), .installed)
        XCTAssertEqual(try Data(contentsOf: file).prefix(partial.count), partial)
        XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).hasSuffix(try request().publicKey + "\n"))
    }
    #endif
}
