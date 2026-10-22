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
    private func jumpFixture() async throws -> (Fixture, Stores, ConnectionProfile) {
        let fixture = try Fixture(), stores = try Stores(fixture: fixture)
        guard let port = Int(ProcessInfo.processInfo.environment["REMOTEFILES_SFTP_JUMP_PORT"] ?? "") else {
            throw XCTSkip("Run the updated isolated OpenSSH fixture with its jump server.")
        }
        let destination = try await stores.identity.importKey(name: "Destination", openSSH: String(contentsOfFile: fixture.directory + "/plain", encoding: .utf8))
        let jump = try await stores.identity.importKey(name: "Bastion", openSSH: String(contentsOfFile: fixture.directory + "/jump-key", encoding: .utf8))
        var profile = try await stores.profile(identity: destination)
        profile.jumpHost = JumpHost(host: "127.0.0.1", port: port, username: fixture.username, identityID: jump.id)
        var value = await stores.metadata.snapshot(); value.identities.append(jump); value.connections = [profile]
        try await stores.metadata.save(value)
        return (fixture, stores, profile)
    }

    func testJumpHostVerifiesBothHostsAndUsesIndependentKeysThenReusesAndReconnects() async throws {
        let (fixture, stores, profile) = try await jumpFixture()
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
        let hop = try XCTUnwrap(profile.jumpHost)
        let jumpEndpoint = HostEndpoint(host: hop.host, port: hop.port)
        let hopBefore = try String(contentsOfFile: fixture.directory + "/jump-sshd.log", encoding: .utf8)
        let targetBefore = try String(contentsOfFile: fixture.directory + "/sshd.log", encoding: .utf8)
        // Unknown bastion fails before either server receives a key offer.
        do { _ = try await service.listDirectory(profile: profile, path: fixture.files); XCTFail("Require jump trust") }
        catch HostTrustError.unknown(let endpoint, _) { XCTAssertEqual(endpoint, jumpEndpoint) }
        let before = try String(contentsOfFile: fixture.directory + "/jump-sshd.log", encoding: .utf8)
        XCTAssertFalse(String(before.dropFirst(hopBefore.count)).contains("Accepted publickey")); XCTAssertFalse(String(before.dropFirst(hopBefore.count)).contains("Failed publickey"))
        let jumpPublic = try String(contentsOfFile: fixture.directory + "/jump-host.pub", encoding: .utf8)
        try await stores.trust.trustUnknown(endpoint: jumpEndpoint, key: HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: jumpPublic)))
        do { _ = try await service.listDirectory(profile: profile, path: fixture.files); XCTFail("Require destination trust") }
        catch HostTrustError.unknown(let endpoint, _) { XCTAssertEqual(endpoint, fixture.endpoint) }
        let destinationLog = try String(contentsOfFile: fixture.directory + "/sshd.log", encoding: .utf8)
        XCTAssertFalse(String(destinationLog.dropFirst(targetBefore.count)).contains("Accepted publickey"), "Destination trust precedes its authentication")
        try await stores.trustFixtureHost()
        let bytes = try await service.readFile(profile: profile, path: fixture.files + "/report.md", limit: 4096)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Fixture report"))
        _ = try await service.listDirectory(profile: profile, path: fixture.files + "/empty")
        let reused = await service.metrics(); XCTAssertEqual(reused.connections, 1); XCTAssertEqual(reused.sftpChannels, 1)
        await service.disconnect()
        _ = try await service.readFile(profile: profile, path: fixture.files + "/report.md", limit: 4096)
        let reconnected = await service.metrics(); XCTAssertEqual(reconnected.connections, 2)
        let hopLog = try String(contentsOfFile: fixture.directory + "/jump-sshd.log", encoding: .utf8)
        XCTAssertTrue(hopLog.contains("Accepted publickey"))
        XCTAssertFalse(String(hopLog.dropFirst(hopBefore.count)).contains("Failed publickey"), "Destination key must never be offered to the bastion")
    }

    func testJumpHostChangedDestinationKeyBlocksDestinationAuthentication() async throws {
        let (fixture, stores, profile) = try await jumpFixture()
        let hop = try XCTUnwrap(profile.jumpHost)
        let jumpPublic = try String(contentsOfFile: fixture.directory + "/jump-host.pub", encoding: .utf8)
        try await stores.trust.trustUnknown(endpoint: HostEndpoint(host: hop.host, port: hop.port), key: HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: jumpPublic)))
        let wrongKey = try HostKeyDetails(publicKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey)
        try await stores.trust.trustUnknown(endpoint: fixture.endpoint, key: wrongKey)
        let service = stores.service(); addTeardownBlock { await service.disconnect() }
        let before = try String(contentsOfFile: fixture.directory + "/sshd.log", encoding: .utf8)
        do { _ = try await service.listDirectory(profile: profile, path: fixture.files); XCTFail("Changed destination must block") }
        catch HostTrustError.changed(let endpoint, _, _) { XCTAssertEqual(endpoint, fixture.endpoint) }
        let after = try String(contentsOfFile: fixture.directory + "/sshd.log", encoding: .utf8)
        let added = String(after.dropFirst(before.count))
        XCTAssertFalse(added.contains("Accepted publickey")); XCTAssertFalse(added.contains("Failed publickey"))
    }

    func testJumpHostForwardingRejectionExplainsTheFailureAndAllowsRetry() async throws {
        let (fixture, stores, base) = try await jumpFixture()
        let hop = try XCTUnwrap(base.jumpHost)
        let jumpPublic = try String(contentsOfFile: fixture.directory + "/jump-host.pub", encoding: .utf8)
        try await stores.trust.trustUnknown(endpoint: HostEndpoint(host: hop.host, port: hop.port), key: HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: jumpPublic)))
        try await stores.trustFixtureHost()
        let service = stores.service(); addTeardownBlock { await service.disconnect() }
        var denied = base; denied.host = "127.0.0.2" // The bastion permits only 127.0.0.1.
        do { _ = try await service.listDirectory(profile: denied, path: fixture.files); XCTFail("Forwarding must be refused") }
        catch RemoteFileError.unavailable(let message) { XCTAssertTrue(message.contains("TCP forwarding")) }
        let bytes = try await service.readFile(profile: base, path: fixture.files + "/report.md", limit: 4096)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Fixture report"))
    }

    func testJumpHostCancellationAndDeadlineCloseTheSilentDestinationTunnel() async throws {
        let (_, stores, base) = try await jumpFixture()
        let hop = try XCTUnwrap(base.jumpHost)
        let fixture = try Fixture()
        let jumpPublic = try String(contentsOfFile: fixture.directory + "/jump-host.pub", encoding: .utf8)
        try await stores.trust.trustUnknown(endpoint: HostEndpoint(host: hop.host, port: hop.port), key: HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: jumpPublic)))
        for cancel in [true, false] {
            let accepted = expectation(description: "Forwarded destination connected")
            let closed = expectation(description: "Forwarded destination closed")
            let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { channel in
                    channel.closeFuture.whenComplete { _ in closed.fulfill() }
                    accepted.fulfill()
                    return channel.eventLoop.makeSucceededVoidFuture()
                }.bind(host: "127.0.0.1", port: 0).get()
            addTeardownBlock { try? await listener.close() }
            var profile = base; profile.port = try XCTUnwrap(listener.localAddress?.port)
            let service = stores.service(timeoutSeconds: cancel ? 10 : 3)
            addTeardownBlock { await service.disconnect() }
            let operation = Task { try await service.listDirectory(profile: profile, path: "/") }
            await fulfillment(of: [accepted], timeout: 5)
            if cancel { operation.cancel() }
            do { _ = try await operation.value; XCTFail("Silent destination cannot authenticate") }
            catch is CancellationError { XCTAssertTrue(cancel) }
            catch RemoteFileError.timedOut { XCTAssertFalse(cancel) }
            await fulfillment(of: [closed], timeout: 5)
            await service.disconnect()
        }
    }

    func testJumpHostLockedIdentityReportsTheJumpKeyBeforeOpeningSockets() async throws {
        let (fixture, stores, original) = try await jumpFixture()
        let encrypted = try await stores.identity.importKey(name: "Locked bastion", openSSH: String(contentsOfFile: fixture.directory + "/encrypted", encoding: .utf8), passphrase: "fixture-passphrase")
        await stores.identity.clearSession()
        var metadata = await stores.metadata.snapshot(); metadata.identities.append(encrypted); try await stores.metadata.save(metadata)
        var profile = original; profile.jumpHost?.identityID = encrypted.id
        let service = stores.service(); addTeardownBlock { await service.disconnect() }
        do { _ = try await service.listDirectory(profile: profile, path: fixture.files); XCTFail("Require the jump key") }
        catch let error as ConnectionIdentityUnlockRequired { XCTAssertEqual(error.identity.id, encrypted.id) }
        let measured = await service.metrics(); XCTAssertEqual(measured.connections, 0)
    }

    func testRSAAndECDSAAuthenticateAndReadUsingOpenSSH() async throws {
        let fixture = try Fixture()
        for spec in ["rsa-2048", "ecdsa-256", "ecdsa-384", "ecdsa-521"] {
            for protection in ["plain", "encrypted"] {
                let stores = try Stores(fixture: fixture)
                let text = try String(contentsOfFile: fixture.directory + "/" + spec + "-" + protection, encoding: .utf8)
                let passphrase = protection == "encrypted" ? "fixture-passphrase" : nil
                let identity = try await stores.identity.importKey(name: spec, openSSH: text, passphrase: passphrase)
                _ = try await stores.identity.unlock(identity, passphrase: passphrase)
                let profile = try await stores.profile(identity: identity)
                try await stores.trustFixtureHost()
                let service = stores.service()
                addTeardownBlock { await service.disconnect() }
                let bytes = try await service.readFile(profile: profile, path: fixture.files + "/report.md", limit: 4096)
                XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Fixture report"), spec + " " + protection)
                await service.disconnect()
            }
        }
    }

    func testPasswordInstallerRetainsHostVerificationAndRejectsDisabledPasswordWithoutWrites() async throws {
        let fixture = try Fixture(), stores = try Stores(fixture: Fixture())
        let key = try await stores.identity.generate(name: "Public-only installer fixture")
        let request = try PublicKeyInstallationRequest(host: "127.0.0.1", port: fixture.port, username: fixture.username, identity: key)
        let file = URL(fileURLWithPath: fixture.directory + "/authorized_keys"), before = try Data(contentsOf: URL(fileURLWithPath: fixture.directory + "/authorized_keys"))
        // The product's own 30-second bound: under CI load the fixture handshake alone has taken
        // nearly five seconds, and an expired deadline is reported as an uncertain installation.
        let installer = SSHPublicKeyInstaller(trust: stores.trust)
        do { _ = try await installer.install(request, password: "not-a-real-password"); XCTFail("Unknown host must block before password login") }
        catch HostTrustError.unknown { }
        try await stores.trustFixtureHost()
        do { _ = try await installer.install(request, password: "not-a-real-password"); XCTFail("Fixture password login is disabled") }
        catch PublicKeyInstallationError.passwordUnavailable { }
        XCTAssertEqual(try Data(contentsOf: file), before, "No authorized key is added during this transport check")
        let changed = try HostTrustStore(fileURL: URL(fileURLWithPath: fixture.directory + "/installer-changed-\(UUID().uuidString).json"))
        let wrongHost = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: key.publicKey))
        try await changed.trustUnknown(endpoint: fixture.endpoint, key: wrongHost)
        let changedInstaller = SSHPublicKeyInstaller(trust: changed)
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
        addTeardownBlock { await service.disconnect() }
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
        print("SFTP journey: resolve report symlink")
        let link = try await service.resolveEntry(profile: profile, path: fixture.files + "/report-link.md")
        XCTAssertEqual(link.kind, .file)
        XCTAssertEqual(link.path, fixture.files + "/report.md")
        print("SFTP journey: list empty directory")
        let empty = try await service.listDirectory(profile: profile, path: fixture.files + "/empty")
        XCTAssertTrue(empty.entries.isEmpty)
        print("SFTP journey: list thousand-entry directory")
        let thousand = try await service.listDirectory(profile: profile, path: fixture.files + "/thousand")
        XCTAssertEqual(thousand.entries.count, 1000)
        print("SFTP journey: reject oversized file")
        do {
            _ = try await service.readFile(profile: profile, path: fixture.files + "/oversized.txt", limit: 2_097_152)
            XCTFail("Oversized document must be rejected")
        } catch RemoteFileError.tooLarge { }
        print("SFTP journey: reject missing file")
        do {
            _ = try await service.readFile(profile: profile, path: fixture.files + "/removed.txt", limit: 1024)
            XCTFail("Missing remote file must fail")
        } catch { XCTAssertFalse(error is CancellationError) }
        print("SFTP journey: read empty file")
        let emptyFile = try await service.readFile(profile: profile, path: fixture.files + "/empty.txt", limit: 0)
        XCTAssertTrue(emptyFile.isEmpty)
        print("SFTP journey: read exact-limit file")
        let exact = try await service.readFile(profile: profile, path: fixture.files + "/report.md", limit: report.count)
        XCTAssertEqual(exact, report)
        print("SFTP journey: reject unreadable file")
        do {
            _ = try await service.readFile(profile: profile, path: fixture.files + "/permission-denied.txt", limit: 1024)
            XCTFail("Unreadable remote file must fail")
        } catch { XCTAssertFalse(error is CancellationError) }
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1, "Browsing must reuse one authenticated SSH connection")
        print("SFTP fixture: connections=\(metrics.connections), directorySeconds=\(metrics.lastDirectorySeconds), fileSeconds=\(metrics.lastReadSeconds), bytes=\(metrics.bytesReceived), readRequests=\(metrics.readRequests)")
        print("SFTP journey: disconnect and reconnect")
        await service.disconnect()
        _ = try await service.listDirectory(profile: profile, path: fixture.files)
        let reconnected = await service.metrics()
        XCTAssertEqual(reconnected.connections, 2)
        await service.disconnect()
    }

    func testContentSearchReadsSourceOverSFTPAndNeverFollowsEscapeLinks() async throws {
        let fixture = try Fixture(), stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Content search")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
        var matches: [RemoteFolderSearch.ContentMatch] = []
        var final: RemoteFolderSearch.Update?
        for try await update in RemoteFolderSearch.contents(matching: "INDEPENDENT openssh", below: fixture.files,
            profile: profile, service: service, includeHidden: false, limits: .init(maxDepth: 0),
            contentLimits: .init(maxFileBytes: 1024)) {
            matches += update.contentMatches
            if update.isFinished { final = update }
        }
        XCTAssertEqual(matches.map(\.entry.path), [fixture.files + "/report.md"], "A linked alias is not read or duplicated")
        XCTAssertEqual(matches.first?.line, 3)
        XCTAssertTrue(matches.first?.snippet.contains("independent OpenSSH") == true)
        let completed = try XCTUnwrap(final)
        XCTAssertNil(completed.stop); XCTAssertGreaterThan(completed.skippedFiles, 0)
        XCTAssertEqual(completed.unreadableFiles, 1, "The fixture's denied file remains unreadable")
        XCTAssertGreaterThan(completed.skippedDeepFolders, 0)
    }

    func testResourceStreamUsesSessionAndRejectsSymlinkEscape() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Resource test")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
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
        let progress = ProgressRecorder()
        _ = try await service.downloadFile(profile: profile, path: fixture.files + "/oversized.txt", allowedRoot: fixture.files,
            destination: temp, limit: 3 * 1024 * 1024, progress: { await progress.record($0) })
        let updates = await progress.values
        XCTAssertEqual(updates.first, .init(totalBytes: 3 * 1024 * 1024))
        XCTAssertGreaterThan(updates.filter { $0.receivedBytes > 0 && !$0.isComplete }.count, 1)
        XCTAssertEqual(updates.last, .init(receivedBytes: 3 * 1024 * 1024, totalBytes: 3 * 1024 * 1024, isComplete: true))
        for pair in zip(updates, updates.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.receivedBytes, pair.1.receivedBytes) }
        XCTAssertEqual(try Data(contentsOf: temp).count, 3 * 1024 * 1024)
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
        defer { try? FileManager.default.removeItem(at: directory) }
        addTeardownBlock { await service.disconnect() }
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
        addTeardownBlock { await service.disconnect() }
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
    func testContentSearchRejectsAnEntireRootRedirectedAfterListing() async throws {
        let fixture = try Fixture(), stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Search boundary")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
        let root = fixture.files + "/search-root"
        let original = root + "-original"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: original)
        }
        try Data("needle in the selected folder".utf8).write(to: URL(fileURLWithPath: root + "/source.md"))
        let listing = try await service.listDirectory(profile: profile, path: root)
        XCTAssertEqual(listing.path, root)
        let before = try await service.readSearchFile(profile: profile, path: root + "/source.md", canonicalRoot: root, limit: 1024)
        XCTAssertEqual(String(decoding: before, as: UTF8.self), "needle in the selected folder")
        try FileManager.default.moveItem(atPath: root, toPath: original)
        try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: fixture.files + "/docs")
        do {
            _ = try await service.readSearchFile(profile: profile, path: root + "/source.md", canonicalRoot: root, limit: 1024)
            XCTFail("A selected search root must not move with a newly installed alias")
        } catch RemoteDocumentLinkError.outsideConnection { }
    }

    func testConfinedRefreshRejectsChangedSymlinkAndReconnectReadsChangedServerBytes() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Changed document")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
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
        addTeardownBlock { await service.disconnect() }
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

    /// CI saw the 1,000-entry listing exceed its deadline while the fixture server answered slowly; the
    /// client kept eight READDIRs outstanding. A server that stops answering mid-session must fail as
    /// `timedOut` within the listing's deadline, not hang or surface a transport error.
    func testStalledServerRepliesFailTheListingAsTimedOut() async throws {
        let (fixture, proxy, service, profile) = try await connectedThroughProxy(name: "Stalled replies")
        proxy.stallReplies()
        let started = ContinuousClock.now
        do {
            _ = try await service.listDirectory(profile: profile, path: fixture.files + "/thousand")
            XCTFail("A listing whose replies never arrive must not succeed")
        } catch RemoteFileError.timedOut {
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(9), "Only the deadline ends a listing that is still waiting")
        XCTAssertLessThan(elapsed, .seconds(20), "The deadline must end the listing rather than wait for the server")
        XCTAssertGreaterThan(proxy.heldReplyBytes, 0, "The server answered the listing, but its replies were held")
    }

    /// A deadline asks the shared SFTP channel to close, but the timed-out work holds it until the
    /// server confirms. The next operation reused that half-closed channel and failed at once with
    /// NIO's "Output closed"; it must open a fresh channel on the same connection instead.
    func testDeadlineRetiresTheSharedChannelBeforeTheNextOperation() async throws {
        let (fixture, proxy, service, profile) = try await connectedThroughProxy(name: "Deadline retirement")
        let before = await service.metrics()
        proxy.stallReplies()
        do {
            _ = try await service.listDirectory(profile: profile, path: fixture.files + "/empty")
            XCTFail("A listing whose replies never arrive must not succeed")
        } catch RemoteFileError.timedOut {
        }
        // The server answers again before the client has seen it confirm the abandoned channel's close.
        proxy.resumeReplies()
        let listing = try await service.listDirectory(profile: profile, path: fixture.files + "/docs")
        XCTAssertTrue(listing.entries.contains { $0.name == "source.md" })
        let after = await service.metrics()
        XCTAssertEqual(after.connections, before.connections, "Only the channel is replaced, not the SSH connection")
        XCTAssertEqual(after.sftpChannels, before.sftpChannels + 1)
    }

    /// A cancelled caller returns before the deadline; the deadline must still retire the channel.
    func testAbandonedOperationsDeadlineRetiresTheSharedChannel() async throws {
        let (fixture, proxy, service, profile) = try await connectedThroughProxy(name: "Abandoned deadline")
        let before = await service.metrics()
        proxy.stallReplies()
        let abandoned = Task { try await service.listDirectory(profile: profile, path: fixture.files + "/empty") }
        try await proxy.waitForHeldReplies()
        abandoned.cancel()
        do { _ = try await abandoned.value; XCTFail("A cancelled listing must not succeed") }
        catch { XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)") }
        // Past the abandoned listing's 10-second deadline, with margin for a loaded runner.
        try await Task.sleep(for: .seconds(12))
        proxy.resumeReplies()
        let listing = try await service.listDirectory(profile: profile, path: fixture.files + "/docs")
        XCTAssertTrue(listing.entries.contains { $0.name == "source.md" })
        let after = await service.metrics()
        XCTAssertEqual(after.connections, before.connections, "Only the channel is replaced, not the SSH connection")
        XCTAssertEqual(after.sftpChannels, before.sftpChannels + 1)
    }

    /// A server process ending mid-listing surfaced NIO's raw "Already closed". It must read as an
    /// ended connection, at once rather than at the deadline, and a refresh must reconnect.
    func testDroppedConnectionReportsTheEndedSessionAndReconnects() async throws {
        let (fixture, proxy, service, profile) = try await connectedThroughProxy(name: "Dropped connection")
        let before = await service.metrics()
        proxy.stallReplies()
        let listing = Task { try await service.listDirectory(profile: profile, path: fixture.files + "/thousand") }
        try await proxy.waitForHeldReplies()
        let dropped = ContinuousClock.now
        proxy.dropConnections()
        do {
            _ = try await listing.value
            XCTFail("A listing whose connection ended must not succeed")
        } catch RemoteFileError.connectionEnded {
            XCTAssertEqual(RemoteFileError.connectionEnded.localizedDescription, "The SSH connection ended. Refresh to reconnect.")
        }
        XCTAssertLessThan(ContinuousClock.now - dropped, .seconds(5), "A closed connection must not wait for the deadline")
        proxy.resumeReplies()
        let refreshed = try await service.listDirectory(profile: profile, path: fixture.files + "/docs")
        XCTAssertTrue(refreshed.entries.contains { $0.name == "source.md" })
        let after = await service.metrics()
        XCTAssertEqual(after.connections, before.connections + 1, "The refresh opens a new SSH connection")
    }

    /// Unlike TreeService's fail-once error, every outcome here comes from the real adapter and
    /// OpenSSH. Hold replies before OPENDIR completes, stagger three peers behind the first listing,
    /// then release replies as that first deadline closes their shared channel. The peers still
    /// have time left on their own deadlines, so they must exercise connection-ended recovery.
    func testSubfolderSearchRecoversListingsInterruptedByAPeersDeadline() async throws {
        let (fixture, proxy, service, profile) = try await connectedThroughProxy(name: "Search timeout cascade")
        let files = FileManager.default, root = fixture.files + "/search-timeout-" + UUID().uuidString
        let folders = ["a-stalled", "b-peer", "c-peer", "d-peer", "z-later/deep"]
        for folder in folders {
            try files.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
            XCTAssertTrue(files.createFile(atPath: root + "/" + folder + "/needle.txt", contents: Data()))
        }
        XCTAssertTrue(files.createFile(atPath: root + "/needle-top.txt", contents: Data()))
        defer { proxy.resumeReplies(); try? files.removeItem(atPath: root) }
        let before = await service.metrics()
        let observed = StaggeredSearchListings(service: service, proxy: proxy, root: root)
        var found: [String] = [], final: RemoteFolderSearch.Update?
        for try await update in RemoteFolderSearch.names(matching: "needle", below: root, profile: profile,
                                                         service: observed, includeHidden: false) {
            found += update.matches.map { String($0.path.dropFirst(root.count + 1)) }
            if update.isFinished { final = update }
        }
        XCTAssertEqual(found, ["needle-top.txt", "b-peer/needle.txt", "c-peer/needle.txt", "d-peer/needle.txt", "z-later/deep/needle.txt"],
                       "Keep earlier matches, recover every interrupted peer, and continue to queued descendants in order")
        let result = try XCTUnwrap(final)
        XCTAssertEqual(result.foldersSearched, 6, "Root, three recovered peers, z-later and deep")
        XCTAssertEqual(result.unreadableFolders, 1, "Only the listing whose own deadline fired is skipped")
        XCTAssertNil(result.stop)
        let attempts = await observed.attempts, failures = await observed.failures, peak = await observed.peak
        XCTAssertEqual(peak, 4, "All four search listings overlap")
        XCTAssertEqual(attempts[root + "/a-stalled"], 1)
        XCTAssertEqual(failures[root + "/a-stalled"], ["timedOut"])
        for peer in ["b-peer", "c-peer", "d-peer"] {
            XCTAssertEqual(attempts[root + "/" + peer], 2, "Each interrupted peer is retried exactly once")
            XCTAssertEqual(failures[root + "/" + peer], ["connectionEnded"], "Exercise real mapped transport failures, not injected errors")
        }
        let after = await service.metrics()
        XCTAssertEqual(after.connections, before.connections, "Recovery keeps the authenticated SSH connection")
        XCTAssertGreaterThan(after.sftpChannels, before.sftpChannels, "Recovery replaces the retired SFTP channel")
        let refreshed = try await service.listDirectory(profile: profile, path: root + "/b-peer")
        XCTAssertEqual(refreshed.entries.map(\.name), ["needle.txt"], "Foreground browsing works after recovery")
    }

    /// A service already connected through a `ReplyStallingProxy`, with a deadline long enough for a
    /// loaded runner's handshake; only the stalled operations should reach it.
    private func connectedThroughProxy(name: String) async throws
        -> (Fixture, ReplyStallingProxy, SFTPRemoteFileService, ConnectionProfile) {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: name)
        try fixture.authorize(key.publicKey)
        let proxy = try await ReplyStallingProxy.start(target: fixture.port)
        addTeardownBlock { await proxy.stop() }
        var profile = try await stores.profile(identity: key)
        profile.port = proxy.port
        try await stores.trustFixtureHost(port: proxy.port)
        let service = stores.service(timeoutSeconds: 10)
        addTeardownBlock { await service.disconnect() }
        _ = try await service.listDirectory(profile: profile, path: fixture.files)
        return (fixture, proxy, service, profile)
    }

    #if os(macOS)
    func testSharedChannelReleasesHandlesRevalidatesAndRetiresAfterFailures() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Shared channel")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
        // Each listing must close its directory handle: a reused channel would otherwise hold them all.
        for _ in 0..<50 { _ = try await service.listDirectory(profile: profile, path: fixture.files + "/empty") }
        XCTAssertEqual(try Self.openDescriptors(on: fixture.files + "/empty"), 0)
        let large = try await service.readFile(profile: profile, path: fixture.files + "/large-report.md", limit: 2_097_152)
        XCTAssertEqual(large, try Data(contentsOf: URL(fileURLWithPath: fixture.files + "/large-report.md")))
        _ = try await service.resolveEntry(profile: profile, path: fixture.files + "/report-link.md")
        var metrics = await service.metrics()
        XCTAssertEqual(metrics.sftpChannels, 1, "Successful short operations must share one SFTP channel")

        let filename = fixture.files + "/versioned.md"
        try Data("first".utf8).write(to: URL(fileURLWithPath: filename))
        defer { try? FileManager.default.removeItem(atPath: filename) }
        guard case .contents(let first, let version?) = try await service.readFileIfChanged(
            profile: profile, path: filename, allowedRoot: nil, limit: 1024, since: nil) else { return XCTFail("First read must transfer a version") }
        XCTAssertEqual(first, Data("first".utf8))
        let before = await service.metrics().bytesReceived
        guard case .unchanged = try await service.readFileIfChanged(
            profile: profile, path: filename, allowedRoot: fixture.files, limit: 1024, since: version) else { return XCTFail("Unchanged file must not transfer") }
        let after = await service.metrics().bytesReceived
        XCTAssertEqual(after, before)
        try Data("second".utf8).write(to: URL(fileURLWithPath: filename))
        try FileManager.default.setAttributes([.modificationDate: version.modifiedAt.addingTimeInterval(5)], ofItemAtPath: filename)
        guard case .contents(let second, _) = try await service.readFileIfChanged(
            profile: profile, path: filename, allowedRoot: nil, limit: 1024, since: version) else { return XCTFail("Changed file must transfer") }
        XCTAssertEqual(second, Data("second".utf8))

        do {
            _ = try await service.readFile(profile: profile, path: fixture.files + "/removed.txt", limit: 1024)
            XCTFail("Missing remote file must fail")
        } catch RemoteFileError.notFound { }
        let cancelled = Task { try await service.readFile(profile: profile, path: fixture.files + "/large-report.md", limit: 2_097_152) }
        cancelled.cancel()
        _ = try? await cancelled.value
        let listing = try await service.listDirectory(profile: profile, path: fixture.files)
        XCTAssertTrue(listing.entries.contains { $0.name == "report.md" })
        metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1)
        XCTAssertLessThanOrEqual(metrics.sftpChannels, 3, "A failed or cancelled operation retires only its channel")
        XCTAssertGreaterThanOrEqual(metrics.sftpChannels, 2)
    }

    func testSubfolderSearchWalksTheTreeOnOneConnectionAndSkipsLockedHiddenAndLinkedFolders() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Subfolder search")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
        let files = FileManager.default, root = fixture.files + "/search-" + UUID().uuidString
        for folder in ["a/b/c", "a/Needle folder", ".cache", "locked"] {
            try files.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
        for file in ["needle-top.md", "a/other.txt", "a/b/c/needle-deep.txt", ".cache/needle-hidden.txt", "locked/needle-locked.txt"] {
            XCTAssertTrue(files.createFile(atPath: root + "/" + file, contents: Data()))
        }
        try files.createSymbolicLink(atPath: root + "/needle-link", withDestinationPath: "a")
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: root + "/locked")
        defer {
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root + "/locked")
            try? files.removeItem(atPath: root)
        }
        let canonical = try await service.listDirectory(profile: profile, path: root).path

        var found: [String] = [], final: RemoteFolderSearch.Update?
        for try await update in RemoteFolderSearch.names(matching: "NEEDLE", below: root, profile: profile,
                                                         service: service, includeHidden: false) {
            found += update.matches.map { String($0.path.dropFirst(canonical.count + 1)) }
            if update.isFinished { final = update }
        }
        XCTAssertEqual(Set(found), ["needle-top.md", "needle-link", "a/Needle folder", "a/b/c/needle-deep.txt"])
        XCTAssertEqual(found.count, 4, "The link to a is matched but not followed, so nothing is found twice")
        XCTAssertEqual(final?.foldersSearched, 5, "The folder, a, a/b, a/Needle folder and a/b/c")
        XCTAssertEqual(final?.unreadableFolders, 1, "The locked folder is counted and skipped")
        XCTAssertNil(final?.stop)
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1)
    }

    func testPipelinedListingIsCompleteInServerOrderAndAlwaysClosesItsHandle() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Pipelined listing")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
        let folder = fixture.files + "/thousand"
        // OpenSSH answers at most 100 names per READDIR, so this listing pipelines eleven reads.
        let expected = try Self.directoryOrder(folder)
        XCTAssertEqual(expected.count, 1000)
        for _ in 0..<5 {
            let listing = try await service.listDirectory(profile: profile, path: fixture.directory + "/root-alias/thousand")
            XCTAssertEqual(listing.path, folder, "Entries are reported under the canonical path")
            XCTAssertEqual(listing.entries.map(\.name), expected, "Every name once, in the server's readdir order")
            XCTAssertEqual(listing.entries.first?.path, folder + "/" + expected[0])
        }
        XCTAssertEqual(try Self.openDescriptors(on: folder), 0)

        let locked = fixture.files + "/locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0])
        defer { try? FileManager.default.removeItem(atPath: locked) }
        do {
            _ = try await service.listDirectory(profile: profile, path: locked)
            XCTFail("An unreadable folder must fail after its path resolves")
        } catch RemoteFileError.permissionDenied { }
        do {
            _ = try await service.listDirectory(profile: profile, path: fixture.files + "/missing-folder")
            XCTFail("A missing folder must fail")
        } catch RemoteFileError.notFound { }
        do {
            _ = try await service.listDirectory(profile: profile, path: fixture.files + "/report.md")
            XCTFail("A file cannot be listed")
        } catch { XCTAssertFalse(error is CancellationError) }
        let empty = try await service.listDirectory(profile: profile, path: fixture.files + "/empty")
        XCTAssertTrue(empty.entries.isEmpty)
        let again = try await service.listDirectory(profile: profile, path: folder)
        XCTAssertEqual(again.entries.map(\.name), expected)
        XCTAssertEqual(try Self.openDescriptors(on: folder), 0)
        XCTAssertEqual(try Self.openDescriptors(on: fixture.files + "/empty"), 0)
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1)
    }

    /// Names in local `readdir` order, the order OpenSSH's sftp-server reads the same folder in.
    private static func directoryOrder(_ path: String) throws -> [String] {
        guard let directory = opendir(path) else { throw POSIXError(.ENOENT) }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Descriptors any process holds on `path`; only the fixture's sftp-server opens this folder.
    private static func openDescriptors(on path: String) throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-Fn", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }.count
    }
    #endif

    #if os(macOS)
    func testListingResolvesLinkTargetsMarksBrokenLinksAndBoundsTheWork() async throws {
        let fixture = try Fixture()
        let stores = try Stores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Link resolution")
        try fixture.authorize(key.publicKey)
        let profile = try await stores.profile(identity: key)
        try await stores.trustFixtureHost()
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
        let fm = FileManager.default
        let folder = fixture.files + "/links-" + UUID().uuidString
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(atPath: folder) }
        try fm.createSymbolicLink(atPath: folder + "/report", withDestinationPath: "../report.md")
        try fm.createSymbolicLink(atPath: folder + "/docs", withDestinationPath: fixture.files + "/docs")
        try fm.createSymbolicLink(atPath: folder + "/missing", withDestinationPath: "nowhere.md")
        try fm.createSymbolicLink(atPath: folder + "/loop-a", withDestinationPath: "loop-b")
        try fm.createSymbolicLink(atPath: folder + "/loop-b", withDestinationPath: "loop-a")
        let listing = try await service.listDirectory(profile: profile, path: folder)
        func entry(_ name: String) throws -> RemoteEntry { try XCTUnwrap(listing.entries.first { $0.name == name }, name) }

        let report = try entry("report")
        XCTAssertEqual(report.kind, .symlink)
        XCTAssertEqual(report.effectiveKind, .file)
        XCTAssertEqual(report.linkTarget?.path, fixture.files + "/report.md")
        let reportSize = try fm.attributesOfItem(atPath: fixture.files + "/report.md")[.size] as? NSNumber
        XCTAssertEqual(report.linkTarget?.size, reportSize?.uint64Value)
        XCTAssertEqual(report.followingLink()?.exportFilename, "report", "Export keeps the link's own name")
        let docs = try entry("docs")
        XCTAssertEqual(docs.effectiveKind, .directory)
        XCTAssertEqual(docs.followingLink()?.path, fixture.files + "/docs")
        for broken in ["missing", "loop-a", "loop-b"] {
            XCTAssertEqual(try entry(broken).link, .broken, broken)
        }

        // Resolution is bounded: later links stay unresolved and still resolve when tapped.
        let many = folder + "/many"
        try fm.createDirectory(atPath: many, withIntermediateDirectories: false)
        for index in 0..<300 { try fm.createSymbolicLink(atPath: many + "/link-\(index)", withDestinationPath: "../../report.md") }
        let crowded = try await service.listDirectory(profile: profile, path: many)
        XCTAssertEqual(crowded.entries.count, 300)
        XCTAssertEqual(crowded.entries.filter { $0.linkTarget != nil }.count, SFTPRemoteFileService.linkResolutionLimit)
        let unresolved = try XCTUnwrap(crowded.entries.first { $0.link == nil })
        let tapped = try await service.resolveEntry(profile: profile, path: unresolved.path)
        XCTAssertEqual(tapped.path, fixture.files + "/report.md")
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1)
    }
    #endif

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
    /// Trusts the fixture's host key, at its own port or at a relay in front of it.
    func trustFixtureHost(port: Int? = nil) async throws {
        let publicKey = try String(contentsOfFile: fixture.directory + "/host.pub", encoding: .utf8)
        let details = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: publicKey))
        try await trust.trustUnknown(endpoint: HostEndpoint(host: "127.0.0.1", port: port ?? fixture.port), key: details)
    }
    /// Functional checks use the benchmark's 60-second budget rather than the 15-second interactive
    /// deadline. The fixture is macOS sshd, which resolves the owner and group of every listed entry
    /// through opendirectoryd; while a fresh CI simulator finishes booting, a passing run measured
    /// 15.9 s for the 1,000-entry folder although file reads stayed in milliseconds. Deadline
    /// behaviour keeps its own explicit short-timeout tests.
    ///
    /// Tests disconnect in an async teardown block. A disconnect started from `defer` closes the socket
    /// while a timed-out operation is still draining, and on iOS XCTest then reported that operation's
    /// `NIOSSHError.tcpShutdown` as the test's error instead of the `timedOut` it threw.
    func service(timeoutSeconds: UInt64 = 60) -> SFTPRemoteFileService {
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

/// Schedules real listings; it never manufactures a snapshot or transport failure. Only the first
/// wave is staggered. Releasing the relay after the first timeout lets retries use a fresh channel.
private actor StaggeredSearchListings: RemoteFileService {
    let service: SFTPRemoteFileService
    let proxy: ReplyStallingProxy
    let root: String
    private(set) var attempts: [String: Int] = [:]
    private(set) var failures: [String: [String]] = [:]
    private(set) var peak = 0
    private var running = 0

    init(service: SFTPRemoteFileService, proxy: ReplyStallingProxy, root: String) {
        self.service = service; self.proxy = proxy; self.root = root
    }

    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        attempts[path, default: 0] += 1
        if attempts[path] == 1, ["b-peer", "c-peer", "d-peer"].contains(RemotePath.name(of: path)) {
            try await proxy.waitForHeldReplies()
            // Leave a generous gap between the first deadline and its peers' deadlines, including
            // the time needed to drain the close and open a replacement channel on a loaded runner.
            try await Task.sleep(for: .seconds(2))
        }
        running += 1; peak = max(peak, running)
        defer { running -= 1 }
        do {
            let snapshot = try await service.listDirectory(profile: profile, path: path)
            if path == root { proxy.stallReplies() }
            return snapshot
        } catch {
            switch error {
            case RemoteFileError.timedOut: failures[path, default: []].append("timedOut")
            case RemoteFileError.connectionEnded: failures[path, default: []].append("connectionEnded")
            default: failures[path, default: []].append(String(describing: error))
            }
            if path == root + "/a-stalled" { proxy.resumeReplies() }
            throw error
        }
    }

    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        try await service.readFile(profile: profile, path: path, limit: limit)
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        try await service.resolveEntry(profile: profile, path: path)
    }
    func disconnect() async { await service.disconnect() }
}

/// Loopback relay in front of the OpenSSH fixture. After `stallReplies()` it keeps forwarding the
/// client's requests but holds every byte the server sends back, as a server that has stopped
/// answering would, while the TCP connection itself stays open. `resumeReplies()` delivers the held
/// bytes in order, as the same server answering again, and `dropConnections()` closes the relayed
/// connections, as the server process ending would.
private final class ReplyStallingProxy: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: Channel?
    private var stalled = false
    private var held = 0
    private var connections: [Channel] = []
    private var replies: [Relay] = []
    var port: Int { lock.withLock { listener?.localAddress?.port ?? 0 } }
    var heldReplyBytes: Int { lock.withLock { held } }

    static func start(target: Int) async throws -> ReplyStallingProxy {
        let proxy = ReplyStallingProxy()
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { $0.pipeline.addHandler(Connector(target: target, proxy: proxy)) }
            .bind(host: "127.0.0.1", port: 0).get()
        proxy.lock.withLock { proxy.listener = listener }
        return proxy
    }

    func stallReplies() { lock.withLock { stalled = true } }
    func resumeReplies() {
        let relays = lock.withLock { stalled = false; return replies }
        relays.forEach { $0.release() }
    }
    func dropConnections() {
        let dropped = lock.withLock {
            defer { connections = []; replies = [] }
            return connections
        }
        dropped.forEach { $0.close(promise: nil) }
    }
    func stop() async {
        dropConnections()
        try? await lock.withLock { listener }?.close()
    }

    /// Waits until the server has answered requests sent after `stallReplies()`.
    func waitForHeldReplies(timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while heldReplyBytes == 0 {
            guard ContinuousClock.now < deadline else { throw RemoteFileError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func hold(_ bytes: Int) -> Bool {
        lock.withLock {
            if stalled { held += bytes }
            return stalled
        }
    }

    private func track(_ connection: Channel, replies relay: Relay) {
        lock.withLock { connections.append(connection); replies.append(relay) }
    }

    /// Connects to the server once the client's socket is active, then relays both ways. The client
    /// is not read until then, and the server's banner can only arrive at an active client socket.
    private final class Connector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let target: Int
        private let proxy: ReplyStallingProxy
        init(target: Int, proxy: ReplyStallingProxy) { self.target = target; self.proxy = proxy }
        func channelActive(context: ChannelHandlerContext) {
            let inbound = context.channel, proxy = proxy
            let replies = Relay(partner: inbound) { proxy.hold($0) }
            proxy.track(inbound, replies: replies)
            ClientBootstrap(group: inbound.eventLoop)
                .channelInitializer { $0.pipeline.addHandler(replies) }
                .connect(host: "127.0.0.1", port: target)
                .flatMap { outbound in
                    inbound.pipeline.addHandler(Relay(partner: outbound) { _ in false }).flatMap {
                        inbound.setOption(ChannelOptions.autoRead, value: true)
                    }
                }
                .whenFailure { _ in inbound.close(promise: nil) }
            context.fireChannelActive()
        }
    }

    /// Forwards to `partner`, or queues while `holds` says so. Both channels share one event loop,
    /// which alone touches the queue, so released bytes always precede later ones.
    private final class Relay: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let partner: Channel
        private let holds: @Sendable (Int) -> Bool
        private var queued: [ByteBuffer] = []
        init(partner: Channel, holds: @escaping @Sendable (Int) -> Bool) { self.partner = partner; self.holds = holds }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            if holds(buffer.readableBytes) || !queued.isEmpty { queued.append(buffer) } else { partner.writeAndFlush(buffer, promise: nil) }
        }
        func release() {
            partner.eventLoop.execute { [self] in
                queued.forEach { partner.write($0, promise: nil) }
                queued = []
                partner.flush()
            }
        }
        func channelInactive(context: ChannelHandlerContext) {
            partner.close(promise: nil)
            context.fireChannelInactive()
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
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

    func testPipelinedReadKeepsRequestsInFlightAndDeliversBytesInOrder() async throws {
        let bytes = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let file = PipelinedPreviewFile(bytes)
        let result = try await BoundedPreviewReader.read(initialSize: nil, limit: 2_097_152) { offset, amount in
            await file.read(offset: offset, length: amount)
        }
        XCTAssertEqual(Array(result.0), bytes)
        let peak = await file.peak
        XCTAssertGreaterThan(peak, 1, "Reads must not wait for one round trip per chunk")
        XCTAssertLessThanOrEqual(peak, 8)
    }

    func testServerReadCapFillsGapsAndShrinksLaterRequests() async throws {
        let bytes = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let file = PipelinedPreviewFile(bytes, maximumRead: 10_000)
        let result = try await BoundedPreviewReader.read(initialSize: UInt64(bytes.count), limit: 2_097_152) { offset, amount in
            await file.read(offset: offset, length: amount)
        }
        XCTAssertEqual(Array(result.0), bytes)
        let lengths = await file.requests.map(\.1)
        XCTAssertGreaterThanOrEqual(lengths.filter { $0 == 10_000 }.count, 4, "Gaps must split at the server's observed read size")
        XCTAssertLessThan(lengths.count, 60, "Capped reads must not discard and repeat in-flight ranges")
    }

    func testSmallServerReadCapStaysWithinTheReadWindow() async throws {
        let bytes = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        for window in [8, 16] {
            let file = PipelinedPreviewFile(bytes, maximumRead: 4 * 1024)
            var received: [UInt8] = []
            _ = try await BoundedPreviewReader.stream(initialSize: nil, limit: 2_097_152, window: window, readChunk: { offset, amount in
                await file.read(offset: offset, length: amount)
            }) { received.append(contentsOf: $0.readableBytesView) }
            XCTAssertEqual(received, bytes)
            let peak = await file.peak
            XCTAssertLessThanOrEqual(peak, window, "Gap pieces must wait for free slots in the read window")
        }
    }

    func testPipelinedReadNeverRequestsPastProbeAndRejectsGrowth() async throws {
        let file = PipelinedPreviewFile(Array(repeating: 1, count: 500_000))
        do {
            _ = try await BoundedPreviewReader.read(initialSize: 100, limit: 300_000) { offset, amount in
                await file.read(offset: offset, length: amount)
            }
            XCTFail("A file beyond its limit must be rejected")
        } catch RemoteFileError.tooLarge(let limit) { XCTAssertEqual(limit, 300_000) }
        let requests = await file.requests
        XCTAssertTrue(requests.allSatisfy { $0.0 + UInt64($0.1) <= 300_001 })

        let exact = PipelinedPreviewFile(Array(repeating: 2, count: 300_000))
        let result = try await BoundedPreviewReader.read(initialSize: nil, limit: 300_000) { offset, amount in
            await exact.read(offset: offset, length: amount)
        }
        XCTAssertEqual(result.0.count, 300_000)
    }

    func testDetachedDeadlineReturnsOnCancellationWhileOperationDrains() async throws {
        let finished = ProgressFlag()
        let started = Date()
        let task = Task {
            try await SFTPRemoteFileService.detachedDeadline(seconds: 10, onTimeout: {}) {
                // Mirrors a transport request that ignores task cancellation.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { continuation.resume() }
                }
                await finished.set()
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled caller must not receive the result") } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
        let drainedEarly = await finished.value
        XCTAssertFalse(drainedEarly)
        try await Task.sleep(for: .milliseconds(600))
        let drained = await finished.value
        XCTAssertTrue(drained, "The operation still finishes and can release its channel")

        // The deadline outlives a cancelled caller, so an unanswered request still releases its channel.
        let released = ProgressFlag()
        let abandoned = Task {
            try await SFTPRemoteFileService.detachedDeadline(seconds: 1, onTimeout: { Task { await released.set() } }) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
                }
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        abandoned.cancel()
        do { _ = try await abandoned.value; XCTFail("Cancelled caller must not receive the result") } catch is CancellationError { }
        try await Task.sleep(for: .milliseconds(1_300))
        let releasedAfterCancel = await released.value
        XCTAssertTrue(releasedAfterCancel, "onTimeout must still run for work that ignores cancellation")

        let timedOut = ProgressFlag()
        do {
            _ = try await SFTPRemoteFileService.detachedDeadline(seconds: 1, onTimeout: { Task { await timedOut.set() } }) {
                try await Task.sleep(for: .seconds(5)); return 1
            }
            XCTFail("Deadline must fire")
        } catch RemoteFileError.timedOut { }
        try await Task.sleep(for: .milliseconds(50))
        let fired = await timedOut.value
        XCTAssertTrue(fired)
    }

    /// Another operation may already be queued when the deadline fires. Whatever `onTimeout` marks
    /// must be in place before the timeout is reported, and a failure caused by its close must not
    /// replace the timeout.
    func testDetachedDeadlineRunsOnTimeoutBeforeReportingTheTimeout() async throws {
        let marked = NSLock(), closed = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var isMarked = false
        do {
            _ = try await SFTPRemoteFileService.detachedDeadline(seconds: 1, onTimeout: {
                // A slow handler widens the window in which an early report would be observed.
                Thread.sleep(forTimeInterval: 0.2)
                marked.withLock { isMarked = true }
                closed.signal()
                // Lets the closed request fail before the deadline reports.
                Thread.sleep(forTimeInterval: 0.2)
            }) { () async throws -> Int in
                // Mirrors a request that fails once its channel closes, ignoring task cancellation.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { closed.wait(); continuation.resume() }
                }
                throw ChannelError.outputClosed
            }
            XCTFail("Deadline must fire")
        } catch RemoteFileError.timedOut { }
        XCTAssertTrue(marked.withLock { isMarked }, "onTimeout must finish before the caller sees the timeout")
    }
}

private actor ProgressFlag {
    private(set) var value = false
    func set() { value = true }
}

/// Serves bytes by offset and records concurrent requests, like a pipelined SFTP server.
private actor PipelinedPreviewFile {
    private let bytes: [UInt8]
    private let maximumRead: Int
    private var inFlight = 0
    private(set) var peak = 0
    private(set) var requests: [(UInt64, UInt32)] = []
    init(_ bytes: [UInt8], maximumRead: Int = .max) { self.bytes = bytes; self.maximumRead = maximumRead }
    func read(offset: UInt64, length: UInt32) async -> ByteBuffer {
        requests.append((offset, length))
        inFlight += 1; peak = max(peak, inFlight)
        try? await Task.sleep(for: .milliseconds(2))
        inFlight -= 1
        let start = min(Int(offset), bytes.count)
        let end = min(start + min(Int(length), maximumRead), bytes.count)
        return ByteBuffer(bytes: bytes[start..<end])
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

final class LinkResolutionSchedulingTests: XCTestCase {
    private func links(_ count: Int) -> [RemoteEntry] {
        (0..<count).map { RemoteEntry(name: "link-\($0)", path: "/p/link-\($0)", kind: .symlink) }
    }

    func testCancelledListingStopsSchedulingLookups() async throws {
        let lookups = LookupCounter()
        let task = Task {
            try await SFTPRemoteFileService.resolvingLinks(in: links(300)) { link in
                await lookups.started()
                // Like Citadel's requests, a sent lookup ignores task cancellation.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
                }
                return .target(RemoteEntry(name: "t", path: "/t/" + link.name, kind: .file))
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled listing must not return") } catch is CancellationError { }
        let started = await lookups.count
        XCTAssertEqual(started, SFTPRemoteFileService.linkResolutionWindow, "Only the first wave was sent before cancellation")
    }

    func testTimeBudgetLeavesLaterLinksUnresolvedWithoutFailingTheListing() async throws {
        let lookups = LookupCounter()
        let clock = ContinuousClock(), began = clock.now
        let entries = try await SFTPRemoteFileService.resolvingLinks(in: links(300), budget: .milliseconds(150)) { link in
            await lookups.started()
            try? await Task.sleep(for: .milliseconds(100))
            return .target(RemoteEntry(name: "t", path: "/t/" + link.name, kind: .file))
        }
        let started = await lookups.count
        let resolved = entries.filter { $0.link != nil }.count
        XCTAssertEqual(resolved, started, "Every lookup that was sent still completes")
        XCTAssertGreaterThanOrEqual(started, SFTPRemoteFileService.linkResolutionWindow)
        XCTAssertLessThan(started, 100, "No new lookups start after the budget")
        XCTAssertEqual(entries.count, 300)
        XCTAssertLessThan(clock.now - began, .seconds(1))
    }
}

private actor LookupCounter {
    private(set) var count = 0
    func started() { count += 1 }
}
