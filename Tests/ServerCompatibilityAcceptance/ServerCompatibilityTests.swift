import Foundation
import XCTest
import NIOSSH
@testable import RemoteFilesCore

/// Opt-in real-server acceptance. The launcher supplies an isolated tree, identity and pinned host key.
/// Kept outside the default target: unavailable external server packages must not become passing skips.
final class ServerCompatibilityTests: XCTestCase {
    fileprivate struct Fixture: Decodable {
        let name: String
        let directory: String
        let root: String
        let port: Int
        let username: String
        let channels: Int
    }

    private func connection() async throws -> (SFTPRemoteFileService, ConnectionProfile, Fixture, URL) {
        try await Self.connection(for: self)
    }

    fileprivate static func connection(for test: XCTestCase) async throws -> (SFTPRemoteFileService, ConnectionProfile, Fixture, URL) {
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["REMOTEFILES_COMPATIBILITY_CONFIG"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: config)))
        let directory = URL(fileURLWithPath: fixture.directory)
        let state = directory.appendingPathComponent("state-" + UUID().uuidString)
        let identities = IdentityStore(secretStore: CompatibilitySecrets())
        let key = try await identities.importKey(name: "Compatibility fixture",
            openSSH: String(contentsOf: directory.appendingPathComponent("client"), encoding: .utf8))
        let metadata = try MetadataStore(fileURL: state.appendingPathComponent("metadata.json"))
        let trust = try HostTrustStore(fileURL: state.appendingPathComponent("trust.json"))
        let host = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey:
            String(contentsOf: directory.appendingPathComponent("host.pub"), encoding: .utf8)))
        try await trust.trustUnknown(endpoint: .init(host: "127.0.0.1", port: fixture.port), key: host)
        let profile = ConnectionProfile(name: fixture.name, host: "127.0.0.1", port: fixture.port,
            username: fixture.username, identityID: key.id, startingDirectory: fixture.root)
        var saved = AppMetadata(); saved.identities = [key]; saved.connections = [profile]
        try await metadata.save(saved)
        let service = SFTPRemoteFileService(identityStore: identities, trustStore: trust, metadataStore: metadata, timeoutSeconds: 60)
        test.addTeardownBlock {
            await service.disconnect()
            try? FileManager.default.removeItem(at: state)
        }
        print("COMPATIBILITY server=\(fixture.name) channels=\(fixture.channels)")
        return (service, profile, fixture, state)
    }

    func testListingWalkFallbackAndShortReadsKeepOneConnection() async throws {
        let (service, profile, fixture, _) = try await connection()
        let listing = try await service.listDirectory(profile: profile, path: fixture.root)
        XCTAssertTrue(listing.entries.contains { $0.name == "Unicode café 東京.txt" })
        for _ in 0..<2 {
            let walked = try await service.listDirectoryForWalk(profile: profile, path: listing.path)
            XCTAssertTrue(walked.entries.contains { $0.name == "folder-0" })
            let bytes = try await service.readFile(profile: profile, path: listing.path + "/large.txt", limit: 300_000)
            XCTAssertEqual(bytes, try Data(contentsOf: URL(fileURLWithPath: fixture.directory + "/files/large.txt")))
        }
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1)
        XCTAssertEqual(metrics.sftpChannels, 2, "The walk channel is reused, or its refusal is remembered")
    }

    func testContentSearchFallbackHonoursLimitsAndExcludesLinks() async throws {
        let (service, profile, fixture, _) = try await connection()
        _ = try await service.listDirectory(profile: profile, path: fixture.root)
        for _ in 0..<2 {
            var found: [String] = []
            for try await update in RemoteFolderSearch.contents(matching: "needle", below: fixture.root,
                profile: profile, service: service, includeHidden: false) {
                found += update.contentMatches.map(\.entry.name)
            }
            XCTAssertEqual(found.count, 12)
            XCTAssertEqual(Set(found).count, 12)
            XCTAssertFalse(found.contains("escape.txt"))
        }
        var count = 0
        var stopped: RemoteFolderSearch.Stop?
        for try await update in RemoteFolderSearch.contents(matching: "needle", below: fixture.root,
            profile: profile, service: service, includeHidden: false, contentLimits: .init(maxFiles: 1)) {
            count += update.contentMatches.count
            if update.isFinished { stopped = update.stop }
        }
        XCTAssertLessThanOrEqual(count, 1)
        XCTAssertEqual(stopped, .fileLimit)
        _ = try await service.listDirectory(profile: profile, path: fixture.root)
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.serverSearchAttempts, 1, "Unsupported helper capability is remembered")
        XCTAssertEqual(metrics.serverSearchOperations, 0, "These fixtures have no Linux helper")
        XCTAssertEqual(metrics.connections, 1)
    }

    func testOfflineFolderAfterBrowsingAndWalkingPreservesEveryByte() async throws {
        let (service, profile, fixture, state) = try await connection()
        let root = try await service.listDirectory(profile: profile, path: fixture.root).path
        // This is also the state left by prefetch or a completed search before Keep Folder Offline.
        _ = try await service.listDirectoryForWalk(profile: profile, path: root)
        let store = try OfflineFileStore(directory: state.appendingPathComponent("offline"))
        addTeardownBlock { await store.cancelAndDrain() }
        // A one-channel server lends browsing's channel to the save; none shares it.
        let folder = try await store.pinFolder(profile: profile, path: root, service: service)
        XCTAssertEqual(folder.fileIDs.count, 14)
        XCTAssertEqual(folder.skippedLinks, 1)
        for id in folder.fileIDs {
            let lease = try await store.lease(id)
            let relative = String(lease.pin.path.dropFirst(root.count))
            XCTAssertEqual(try Data(contentsOf: lease.url),
                try Data(contentsOf: URL(fileURLWithPath: fixture.directory + "/files" + relative)), relative)
        }
        _ = try await service.listDirectory(profile: profile, path: root)
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1, "Channel refusal must not discard a healthy SSH connection")
        if fixture.channels == 1 { XCTAssertGreaterThanOrEqual(metrics.foregroundLoans, 1, "The fixture must exercise lending") }
        else { XCTAssertEqual(metrics.foregroundLoans, 0, "Servers with room for a transfer never lend browsing's channel") }
    }

    func testSnapshotRejectsRedirectWithoutPublishingBytes() async throws {
        let (service, profile, fixture, state) = try await connection()
        let destination = state.appendingPathComponent("must-not-publish")
        do {
            _ = try await service.downloadSnapshotFile(profile: profile, path: fixture.root + "/escape.txt",
                canonicalRoot: fixture.root, destination: destination, limit: 100_000, progress: { _ in })
            XCTFail("Snapshot paths must not follow a symlink")
        } catch {
            XCTAssertTrue(error is RemoteDocumentLinkError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        _ = try await service.listDirectory(profile: profile, path: fixture.root)
    }

    func testReadAndTransferLimitsLeaveBrowsingUsable() async throws {
        let (service, profile, fixture, state) = try await connection()
        do {
            _ = try await service.readFile(profile: profile, path: fixture.root + "/large.txt", limit: 1000)
            XCTFail("Oversized previews must fail")
        } catch RemoteFileError.tooLarge { }
        let destination = state.appendingPathComponent("bounded-transfer")
        do {
            _ = try await service.downloadSnapshotFile(profile: profile, path: fixture.root + "/large.txt",
                canonicalRoot: fixture.root, destination: destination, limit: 1000, progress: { _ in })
            XCTFail("Oversized originals must fail")
        } catch {
            guard case RemoteFileError.tooLarge = error else { return XCTFail("\(error)") }
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertLessThanOrEqual(size, 1000)
        _ = try await service.listDirectory(profile: profile, path: fixture.root)
    }
}

/// The Paramiko fixture exposes a file gate around an actual READDIR, rather than a timing-based delay.
/// The launcher runs these only against its two-channel Paramiko server.
final class ChannelDrainCompatibilityTests: XCTestCase {
    func testActiveWalkDrainsBeforeTransferTakesItsChannel() async throws {
        try await exercise(cancel: false)
    }

    func testCancellationWhileReclaimingAChannelDrainsWithoutPublishing() async throws {
        try await exercise(cancel: true)
    }

    private func exercise(cancel: Bool) async throws {
        let (service, profile, fixture, state) = try await ServerCompatibilityTests.connection(for: self)
        XCTAssertEqual(fixture.name, "paramiko-2")
        let control = URL(fileURLWithPath: fixture.directory + "/control")
        let gate = control.appendingPathComponent("hold-listing")
        let started = control.appendingPathComponent("listing-started")
        let refused = control.appendingPathComponent("channel-refused")
        for file in [started, refused] { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: gate)
        _ = try await service.listDirectory(profile: profile, path: fixture.root)
        let walk = Task { try await service.listDirectoryForWalk(profile: profile, path: fixture.root + "/held") }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: gate)
            _ = await walk.result
        }
        try await waitForFile(started)
        let destination = state.appendingPathComponent("transfer")
        let transfer = Task {
            try await service.downloadSnapshotFile(profile: profile, path: fixture.root + "/large.txt",
                canonicalRoot: fixture.root, destination: destination, limit: 300_000, progress: { _ in })
        }
        addTeardownBlock { transfer.cancel(); _ = await transfer.result }
        try await waitForFile(refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        // A foreground listing still completes while the walk is deliberately held.
        _ = try await service.listDirectory(profile: profile, path: fixture.root)
        if cancel { transfer.cancel() }
        try FileManager.default.removeItem(at: gate)
        if cancel {
            _ = await walk.result // Cancellation before a transfer channel opens may close SSH.
            do { _ = try await transfer.value; XCTFail("Cancelled transfer succeeded") }
            catch is CancellationError { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } else {
            _ = try await walk.value
            _ = try await transfer.value
            XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: URL(fileURLWithPath: fixture.directory + "/files/large.txt")))
            let metrics = await service.metrics()
            XCTAssertEqual(metrics.connections, 1)
        }
        _ = try await service.listDirectory(profile: profile, path: fixture.root)
    }

    private func waitForFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(65)
        while !FileManager.default.fileExists(atPath: url.path) {
            if ContinuousClock.now >= deadline { XCTFail("Fixture gate did not arrive: \(url.lastPathComponent)"); throw RemoteFileError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class CompatibilitySecrets: IdentitySecretStore, @unchecked Sendable {
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
