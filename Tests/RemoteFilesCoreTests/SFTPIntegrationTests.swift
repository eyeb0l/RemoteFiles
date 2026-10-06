import XCTest
import Foundation
import Crypto
import NIOSSH
import NIOCore
import NIOPosix
@testable import RemoteFilesCore

/// Real OpenSSH checks are opt-in; the isolated launcher supplies temporary paths.
/// A skip without that fixture must never be reported as an authentication pass.
final class SFTPIntegrationTests: XCTestCase {
    func testPasswordInstallerRetainsHostVerificationAndRejectsDisabledPasswordWithoutWrites() async throws {
        let fixture = try Fixture(), stores = try Stores(fixture: Fixture())
        let key = try await stores.identity.generate(name: "Public-only installer fixture")
        let request = try PublicKeyInstallationRequest(host: "127.0.0.1", port: fixture.port, username: fixture.username, identity: key)
        let file = URL(fileURLWithPath: fixture.directory + "/authorized_keys"), before = try Data(contentsOf: URL(fileURLWithPath: fixture.directory + "/authorized_keys"))
        let installer = SSHPublicKeyInstaller(trust: stores.trust, timeoutSeconds: 5)
        do { _ = try await installer.install(request, password: "not-a-real-password"); XCTFail("Unknown host must block before password login") }
        catch HostTrustError.unknown { }
        try await stores.trustFixtureHost()
        do { _ = try await installer.install(request, password: "not-a-real-password"); XCTFail("Fixture password login is disabled") }
        catch PublicKeyInstallationError.passwordUnavailable { }
        XCTAssertEqual(try Data(contentsOf: file), before, "No authorized key is added during this transport check")
        let changed = try HostTrustStore(fileURL: URL(fileURLWithPath: fixture.directory + "/installer-changed-\(UUID().uuidString).json"))
        let wrongHost = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: key.publicKey))
        try await changed.trustUnknown(endpoint: fixture.endpoint, key: wrongHost)
        let changedInstaller = SSHPublicKeyInstaller(trust: changed, timeoutSeconds: 5)
        do { _ = try await changedInstaller.install(request, password: "not-a-real-password"); XCTFail("Changed host must block") }
        catch HostTrustError.changed { }
        XCTAssertEqual(try Data(contentsOf: file), before)
        await installer.cancelAll(); await changedInstaller.cancelAll()
    }
    func testGeneratedEd25519AndReadOnlyJourney() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let generated = try await stores.identity.generate(name: "Ephemeral integration key")
        try fixture.authorize(generated.publicKey)
        let profile = try await stores.profile(identity: generated)
        try await stores.trustFixtureHost()
        let service = stores.service()
        defer { Task { await service.disconnect() } }
        let listing = try await service.listDirectory(profile: profile, path: fixture.files)
        let cold = await service.metrics()
        print("SFTP cold: connectionSeconds=\(cold.lastConnectionSeconds), directorySeconds=\(cold.lastDirectorySeconds)")
        XCTAssertEqual(listing.path, fixture.files)
        XCTAssertTrue(listing.entries.contains { $0.name == "Unicode café.txt" })
        XCTAssertTrue(listing.entries.contains { $0.name == ".hidden" })
        XCTAssertTrue(listing.entries.contains { $0.name == "empty" && $0.kind == .directory })
        let report = try await service.readFile(profile: profile, path: fixture.files + "/report.md", limit: 2_097_152)
        XCTAssertTrue(String(decoding: report, as: UTF8.self).contains("independent OpenSSH"))
        let largeReport = try await service.readFile(profile: profile, path: fixture.files + "/large-report.md", limit: 2_097_152)
        let largeMetrics = await service.metrics()
        print("SFTP warm report: bytes=\(largeReport.count), seconds=\(largeMetrics.lastReadSeconds), totalReadRequests=\(largeMetrics.readRequests)")
        XCTAssertGreaterThan(largeReport.count, 100 * 1024)
        XCTAssertLessThan(largeReport.count, 200 * 1024)
        let link = try await service.resolveEntry(profile: profile, path: fixture.files + "/report-link.md")
        XCTAssertEqual(link.kind, .file)
        XCTAssertEqual(link.path, fixture.files + "/report.md")
        let empty = try await service.listDirectory(profile: profile, path: fixture.files + "/empty")
        XCTAssertTrue(empty.entries.isEmpty)
        let thousand = try await service.listDirectory(profile: profile, path: fixture.files + "/thousand")
        XCTAssertEqual(thousand.entries.count, 1000)
        do {
            _ = try await service.readFile(profile: profile, path: fixture.files + "/oversized.txt", limit: 2_097_152)
            XCTFail("Oversized document must be rejected")
        } catch RemoteFileError.tooLarge { }
        do {
            _ = try await service.readFile(profile: profile, path: fixture.files + "/removed.txt", limit: 1024)
            XCTFail("Missing remote file must fail")
        } catch { XCTAssertFalse(error is CancellationError) }
        let emptyFile = try await service.readFile(profile: profile, path: fixture.files + "/empty.txt", limit: 0)
        XCTAssertTrue(emptyFile.isEmpty)
        let exact = try await service.readFile(profile: profile, path: fixture.files + "/report.md", limit: report.count)
        XCTAssertEqual(exact, report)
        do {
            _ = try await service.readFile(profile: profile, path: fixture.files + "/permission-denied.txt", limit: 1024)
            XCTFail("Unreadable remote file must fail")
        } catch { XCTAssertFalse(error is CancellationError) }
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1, "Browsing must reuse one authenticated SSH connection")
        print("SFTP fixture: connections=\(metrics.connections), directorySeconds=\(metrics.lastDirectorySeconds), fileSeconds=\(metrics.lastReadSeconds), bytes=\(metrics.bytesReceived), readRequests=\(metrics.readRequests)")
        await service.disconnect()
        _ = try await service.listDirectory(profile: profile, path: fixture.files)
        let reconnected = await service.metrics()
        XCTAssertEqual(reconnected.connections, 2)
        await service.disconnect()
    }

    func testResourceStreamUsesSessionAndRejectsSymlinkEscape() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Resource test")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        defer { Task { await service.disconnect() } }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await service.listDirectory(profile: profile, path: fixture.files)
        let result = try await service.downloadFile(profile: profile, path: fixture.files + "/report-link.md", allowedRoot: fixture.files, destination: temp, limit: 1024)
        XCTAssertEqual(result.path, fixture.files + "/report.md")
        XCTAssertTrue(String(decoding: try Data(contentsOf: temp), as: UTF8.self).contains("independent OpenSSH"))
        do {
            _ = try await service.downloadFile(profile: profile, path: fixture.files + "/report.md", allowedRoot: fixture.files + "/empty", destination: temp, limit: 1024)
            XCTFail("Canonical path outside resource root must be rejected")
        } catch RemoteResourceError.outsideDocument { }
        do {
            _ = try await service.downloadFile(profile: profile, path: fixture.files + "/report.md", allowedRoot: fixture.files, destination: temp, limit: 3)
            XCTFail("Resource byte cap must be enforced")
        } catch RemoteFileError.tooLarge { }
        #if os(macOS)
        let escape = fixture.files + "/resource-escape"
        try FileManager.default.createSymbolicLink(atPath: escape, withDestinationPath: "/etc/hosts")
        defer { try? FileManager.default.removeItem(atPath: escape) }
        do {
            _ = try await service.downloadFile(profile: profile, path: escape, allowedRoot: fixture.files, destination: temp, limit: 4096)
            XCTFail("Symlink escape must be rejected before download")
        } catch RemoteResourceError.outsideDocument { }
        #endif
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1)
    }
    func testOpenFileDistinguishesMissingReferencesFromExistingOutsideFiles() async throws {
        let fixture = try Fixture(), stores = try Stores(fixture: Fixture())
        let key = try await stores.identity.generate(name: "Image existence test")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); Task { await service.disconnect() } }
        let resolver = RemoteResourceResolver(service: service, directory: directory)
        let document = RemoteDocumentLocation(profile: profile, path: fixture.files + "/docs/source.md")
        for missing in [fixture.directory + "/old/missing.png", fixture.files + "/docs/missing.png"] {
            do {
                _ = try await resolver.localFileForOpening(for: missing, in: document)
                XCTFail("Real SFTP NO_SUCH_FILE must identify the missing linked path")
            } catch RemoteResourceError.missingFile(let path) {
                XCTAssertEqual(path, missing)
            }
        }
        do {
            _ = try await resolver.localFile(for: "missing.png", in: document)
            XCTFail("Missing automatic resources must use the same file-not-found error")
        } catch RemoteResourceError.missingFile(let path) {
            XCTAssertEqual(path, document.resourceRoot + "/missing.png")
        }
        do {
            _ = try await resolver.localFileForOpening(for: fixture.files + "/report.md", in: document)
            XCTFail("An existing file outside the document tree still cannot be downloaded")
        } catch RemoteResourceError.outsideDocument { }
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.bytesReceived, 0)
        XCTAssertEqual(metrics.connections, 1)
    }

    func testRelativeDocumentsUseCanonicalConnectionRootAndRejectEscapes() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Document links")
        try fixture.authorize(key.publicKey)
        var profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        defer { Task { await service.disconnect() } }
        let source = fixture.files + "/docs/source.md"
        let parent = try await service.resolveDocumentLink(profile: profile, documentPath: source, reference: "../report.md")
        XCTAssertEqual(parent.path, fixture.files + "/report.md")
        let unicode = try await service.resolveDocumentLink(profile: profile, documentPath: source, reference: "../Unicode%20caf%C3%A9.txt")
        XCTAssertEqual(unicode.name, "Unicode café.txt")
        let symlink = try await service.resolveDocumentLink(profile: profile, documentPath: source, reference: "../report-link.md")
        XCTAssertEqual(symlink.path, parent.path)
        XCTAssertEqual(symlink.exportFilename, "report-link.md")
        for reference in ["../../outside.md", "escape.md"] {
            do {
                _ = try await service.resolveDocumentLink(profile: profile, documentPath: source, reference: reference)
                XCTFail("Escaping document link must not navigate: \(reference)")
            } catch RemoteDocumentLinkError.outsideConnection { }
        }
        for reference in ["../binary.bin", "../empty"] {
            do {
                _ = try await service.resolveDocumentLink(profile: profile, documentPath: source, reference: reference)
                XCTFail("Unsupported/directory targets must not navigate")
            } catch RemoteDocumentLinkError.unsupportedFile { }
        }
        do {
            _ = try await service.resolveDocumentLink(profile: profile, documentPath: source, reference: "missing.md")
            XCTFail("Missing document must return a recoverable error")
        } catch { XCTAssertFalse(error is CancellationError) }
        profile.startingDirectory = fixture.directory + "/root-alias"
        let alias = try await service.resolveDocumentLink(profile: profile, documentPath: fixture.directory + "/root-alias/docs/source.md", reference: "../report.md")
        XCTAssertEqual(alias.path, parent.path, "Configured root symlinks are canonicalized before confinement")
    }

    #if os(macOS)
    func testConfinedRefreshRejectsChangedSymlinkAndReconnectReadsChangedServerBytes() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Changed document")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        defer { Task { await service.disconnect() } }
        let filename = fixture.files + "/docs/refresh-target.md"
        let before = Data("first version\r\n".utf8)
        try before.write(to: URL(fileURLWithPath: filename))
        defer { try? FileManager.default.removeItem(atPath: filename) }
        let target = try await service.resolveDocumentLink(profile: profile,
            documentPath: fixture.files + "/docs/source.md", reference: "refresh-target.md")
        let root = try XCTUnwrap(target.navigationRoot)
        let first = try await service.readDocumentFile(profile: profile, path: target.path, allowedRoot: root, limit: 1024)
        XCTAssertEqual(first, before)
        await service.disconnect()
        let after = Data("updated on server\r\n東京  \r\n".utf8)
        try after.write(to: URL(fileURLWithPath: filename))
        let refreshed = try await service.readDocumentFile(profile: profile, path: target.path, allowedRoot: root, limit: 1024)
        XCTAssertEqual(refreshed, after, "A new session must read changed server bytes")
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 2, "Explicit teardown must require a new SSH connection")
        try FileManager.default.removeItem(atPath: filename)
        try FileManager.default.createSymbolicLink(atPath: filename, withDestinationPath: fixture.directory + "/outside.md")
        do {
            _ = try await service.readDocumentFile(profile: profile, path: target.path, allowedRoot: root, limit: 1024)
            XCTFail("Refresh must recheck canonical confinement after the linked target changes")
        } catch RemoteDocumentLinkError.outsideConnection { }
    }
    #endif

    func testOriginalStreamingPreservesBytesAndRejectsCanonicalEscape() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Original streaming")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        defer { Task { await service.disconnect() } }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        let expected = Data("é 東京\r\n\ttrailing spaces  \r\n".utf8)
        _ = try await service.downloadFile(profile: profile, path: fixture.files + "/original.txt", allowedRoot: profile.startingDirectory, destination: target, limit: expected.count)
        XCTAssertEqual(try Data(contentsOf: target), expected)
        _ = try await service.downloadFile(profile: profile, path: fixture.files + "/empty.txt", allowedRoot: profile.startingDirectory, destination: target, limit: 1)
        XCTAssertEqual(try Data(contentsOf: target).count, 0)
        do {
            _ = try await service.downloadFile(profile: profile, path: fixture.files + "/outside-export.txt", allowedRoot: profile.startingDirectory, destination: target, limit: 4096)
            XCTFail("Original export must reject symlink escape before download")
        } catch RemoteResourceError.outsideDocument { }
    }

    func testOrdinaryUnencryptedAndEncryptedOpenSSHAuthentication() async throws {
        let fixture = try Fixture()
        for (filename, passphrase) in [("plain", Optional<String>.none), ("encrypted", Optional("fixture-passphrase"))] {
            let stores = try Stores(fixture: fixture)
            let source = try String(contentsOfFile: fixture.directory + "/" + filename, encoding: .utf8)
            let identity = try await stores.identity.importKey(name: filename, openSSH: source, passphrase: passphrase)
            let profile = try await stores.profile(identity: identity)
            try await stores.trustFixtureHost()
            _ = try await stores.identity.unlock(identity, passphrase: passphrase)
            let service = stores.service()
            let result = try await service.readFile(profile: profile, path: fixture.files + "/report.md", limit: 1024)
            XCTAssertFalse(result.isEmpty)
            await service.disconnect()
            if passphrase != nil {
                do {
                    _ = try await stores.identity.unlock(identity)
                    XCTFail("Disconnect must release the unlocked encrypted key")
                } catch IdentityError.missingPassphrase { }
            }
        }
    }

    func testUnknownAndChangedHostFailBeforeAuthentication() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        // This identity is deliberately not authorized. If user authentication runs,
        // it fails differently; the fixture log provides an independent assertion.
        let identity = try await stores.identity.generate(name: "Not authorized")
        let profile = try await stores.profile(identity: identity)
        let service = stores.service()
        let logBefore = try String(contentsOfFile: fixture.directory + "/sshd.log", encoding: .utf8)
        var presented: HostKeyDetails?
        do {
            _ = try await service.listDirectory(profile: profile, path: fixture.files)
            XCTFail("Unknown host must be rejected")
        } catch HostTrustError.unknown(let endpoint, let key) {
            XCTAssertEqual(endpoint.port, fixture.port)
            presented = key
        }
        XCTAssertNotNil(presented)
        let different = try HostKeyDetails(publicKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey)
        try await stores.trust.trustUnknown(endpoint: fixture.endpoint, key: different)
        do {
            _ = try await service.listDirectory(profile: profile, path: fixture.files)
            XCTFail("Changed host must be rejected")
        } catch HostTrustError.changed(_, let previous, let current) {
            XCTAssertEqual(previous, different)
            XCTAssertEqual(current, presented)
        }
        await service.disconnect()
        let logAfter = try String(contentsOfFile: fixture.directory + "/sshd.log", encoding: .utf8)
        let appended = String(logAfter.dropFirst(logBefore.count))
        XCTAssertFalse(appended.contains("Failed publickey"), "Host-key rejection must precede user authentication")
        XCTAssertFalse(appended.contains("Accepted publickey"), "Host-key rejection must precede user authentication")
    }

    func testCancellationAndDeadlineCloseSilentHandshakeSocket() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let identity = try await stores.identity.generate(name: "Silent handshake")
        let baseProfile = try await stores.profile(identity: identity)
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }.bind(host: "127.0.0.1", port: 0).get()
        defer { listener.close(promise: nil) }
        var profile = baseProfile
        profile.port = try XCTUnwrap(listener.localAddress?.port)
        let service = stores.service(timeoutSeconds: 1)
        let task = Task { try await service.listDirectory(profile: profile, path: fixture.files) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let cancelledAt = Date()
        task.cancel()
        // Start a new request before the cancelled handshake has drained. It must
        // get a fresh socket, not inherit the cancelled pending connection task.
        let timedAt = Date()
        let refresh = Task { try await service.listDirectory(profile: profile, path: fixture.files) }
        do { _ = try await task.value; XCTFail("Cancelled handshake must not succeed") }
        catch { XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
        do {
            _ = try await refresh.value
            XCTFail("Silent handshake must time out")
        } catch RemoteFileError.timedOut { }
        XCTAssertLessThan(Date().timeIntervalSince(timedAt), 2.5)
        await service.disconnect()
    }

    func testCancelBeforeConnectDoesNotAuthenticate() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let identity = try await stores.identity.generate(name: "Cancelled")
        let profile = try await stores.profile(identity: identity)
        let service = stores.service()
        let task = Task { try await service.listDirectory(profile: profile, path: fixture.files) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work must not succeed") }
        catch is CancellationError { }
        await service.disconnect()
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 0)
    }
}

private struct Fixture {
    let directory: String
    let port: Int
    let username: String
    var files: String { directory + "/files" }
    var endpoint: HostEndpoint { HostEndpoint(host: "127.0.0.1", port: port) }
    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["REMOTEFILES_SFTP_FIXTURE"],
              let port = Int(env["REMOTEFILES_SFTP_PORT"] ?? ""),
              let username = env["REMOTEFILES_SFTP_USER"] else {
            throw XCTSkip("Run scripts/test-openssh.sh to create an isolated real OpenSSH fixture.")
        }
        self.directory = directory; self.port = port; self.username = username
    }
    func authorize(_ publicKey: String) throws {
        let url = URL(fileURLWithPath: directory + "/authorized_keys")
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data((publicKey + "\n").utf8))
    }
}

private struct Stores {
    let fixture: Fixture
    let identity: IdentityStore
    let metadata: MetadataStore
    let trust: HostTrustStore
    init(fixture: Fixture) throws {
        self.fixture = fixture
        let folder = URL(fileURLWithPath: fixture.directory).appendingPathComponent(UUID().uuidString)
        identity = IdentityStore(secretStore: IntegrationSecrets())
        metadata = try MetadataStore(fileURL: folder.appendingPathComponent("metadata.json"))
        trust = try HostTrustStore(fileURL: folder.appendingPathComponent("trust.json"))
    }
    func profile(identity: IdentityMetadata) async throws -> ConnectionProfile {
        let profile = ConnectionProfile(name: "OpenSSH fixture", host: "127.0.0.1", port: fixture.port,
                                        username: fixture.username, identityID: identity.id,
                                        startingDirectory: fixture.files)
        var value = AppMetadata()
        value.identities = [identity]; value.connections = [profile]
        try await metadata.save(value)
        return profile
    }
    func trustFixtureHost() async throws {
        let publicKey = try String(contentsOfFile: fixture.directory + "/host.pub", encoding: .utf8)
        let details = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: publicKey))
        try await trust.trustUnknown(endpoint: fixture.endpoint, key: details)
    }
    func service(timeoutSeconds: UInt64 = 15) -> SFTPRemoteFileService {
        SFTPRemoteFileService(identityStore: identity, trustStore: trust, metadataStore: metadata,
                              timeoutSeconds: timeoutSeconds)
    }
}

private final class IntegrationSecrets: IdentitySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func save(_ value: Data, reference: String) throws {
        lock.lock(); defer { lock.unlock() }; data[reference] = value
    }
    func load(reference: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = data[reference] else { throw IdentityError.missingSecret }
        return value
    }
    func delete(reference: String) throws {
        lock.lock(); defer { lock.unlock() }; data.removeValue(forKey: reference)
    }
}

final class BoundedPreviewReaderTests: XCTestCase {
    func testGrowthBeyondInitialStatIsRejectedWhileReceiving() async throws {
        let chunks = ControlledPreviewChunks(["1234", "56789"])
        do {
            _ = try await BoundedPreviewReader.read(initialSize: 4, limit: 8) { _, amount in
                await chunks.next(maximum: amount)
            }
            XCTFail("A file that grows beyond its stat size must be rejected")
        } catch RemoteFileError.tooLarge(let limit) { XCTAssertEqual(limit, 8) }
        let requested = await chunks.requests
        XCTAssertEqual(requested, [9, 5])
    }

    func testExactLimitRequiresEOFProbeAndHandlesShortReads() async throws {
        let chunks = ControlledPreviewChunks(["12", "345678", ""])
        let result = try await BoundedPreviewReader.read(initialSize: nil, limit: 8) { _, amount in
            await chunks.next(maximum: amount)
        }
        XCTAssertEqual(String(decoding: result.0, as: UTF8.self), "12345678")
        XCTAssertEqual(result.1, 3)
        let requested = await chunks.requests
        XCTAssertEqual(requested, [9, 7, 1])
    }
}

private actor ControlledPreviewChunks {
    private var chunks: [String]
    private(set) var requests: [UInt32] = []
    init(_ chunks: [String]) { self.chunks = chunks }
    func next(maximum: UInt32) -> ByteBuffer {
        requests.append(maximum)
        return ByteBuffer(string: chunks.isEmpty ? "" : chunks.removeFirst())
    }
}
