import XCTest
import Foundation
import Crypto
import NIOSSH
@testable import RemoteFilesCore

/// Opt-in acceptance over a real network path to a disposable server, with delay, loss, rate limits and outages
/// applied on the server to the fixture's port alone. See README.md for the fixture and the fault script.
/// Kept outside the default target: it needs a provisioned host, and missing configuration fails rather than skips.
final class NetworkFaultAcceptanceTests: XCTestCase {
    private struct Environment {
        let local: String, host: String, port: Int, user: String, root: String, control: String
        static func load() throws -> Environment {
            let env = ProcessInfo.processInfo.environment
            return try Environment(local: XCTUnwrap(env["NETWORK_FAULT_LOCAL"]), host: XCTUnwrap(env["NETWORK_FAULT_HOST"]),
                                   port: XCTUnwrap(Int(env["NETWORK_FAULT_PORT"] ?? "")), user: XCTUnwrap(env["NETWORK_FAULT_USER"]),
                                   root: XCTUnwrap(env["NETWORK_FAULT_ROOT"]), control: XCTUnwrap(env["NETWORK_FAULT_CONTROL"]))
        }
    }

    private var environment: Environment!
    private var state: URL!

    override func setUp() async throws {
        environment = try Environment.load()
        state = URL(fileURLWithPath: environment.local).appendingPathComponent("state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try fault("clear")
        let state = state!
        addTeardownBlock { [environment] in
            if let environment { try? Self.run(environment.control + " clear") }
            try? FileManager.default.removeItem(at: state)
        }
    }

    /// Delay, jitter and loss on every reply, as on a distant or poor link. Every byte must still arrive intact.
    func testLatencyAndLossKeepEveryByte() async throws {
        try fault("shape 150ms 30ms 2% none")
        let (service, profile) = try await connection()
        var clock = ContinuousClock.now
        let listing = try await service.listDirectory(profile: profile, path: environment.root)
        XCTAssertTrue(listing.entries.contains { $0.name == "big.bin" })
        let listed = clock.duration(to: .now)
        clock = .now
        var found: [String] = []
        for try await update in RemoteFolderSearch.contents(matching: "network needle", below: environment.root, profile: profile,
                                                            service: service, includeHidden: false) {
            found += update.contentMatches.map(\.entry.name)
        }
        XCTAssertEqual(found, ["needle.txt"])
        let searched = clock.duration(to: .now)
        clock = .now
        let destination = state.appendingPathComponent("big.bin")
        _ = try await service.downloadManagedFile(profile: profile, path: environment.root + "/big.bin", allowedRoot: environment.root,
                                                  destination: destination, limit: 16 << 20, resumeVersion: nil, started: { _, _ in }, progress: { _ in })
        XCTAssertEqual(try sha(destination), try expected("big.bin"))
        let downloaded = clock.duration(to: .now)
        clock = .now
        let folder = try await saveTree(service: service, profile: profile)
        let saved = clock.duration(to: .now)
        XCTAssertEqual(folder, 48)
        let metrics = await service.metrics()
        print("NETWORK_LOSSY list=\(listed) search=\(searched) download8MiB=\(downloaded) save48=\(saved) helper=\(metrics.serverSearchOperations) connections=\(metrics.connections)")
        XCTAssertEqual(metrics.connections, 1)
    }

    /// The network disappears mid-download. The transfer must end at its idle deadline rather than hang, publish
    /// nothing complete, and resume from what it kept once the network returns, on a fresh connection.
    func testOutageDuringDownloadEndsAtItsIdleDeadlineAndResumes() async throws {
        try fault("shape 0ms 0ms 0% 6mbit")
        let (service, profile) = try await connection()
        // A test of the deadline itself, so it may be shorter than production's 60 seconds.
        await service.setTransferTimings(idle: .seconds(10), closeGrace: .seconds(5))
        let destination = state.appendingPathComponent("resumable.bin")
        let received = Counter(), version = VersionBox()
        let path = environment.root + "/big.bin", root = environment.root
        let transfer = Task {
            try await service.downloadManagedFile(profile: profile, path: path, allowedRoot: root, destination: destination, limit: 16 << 20,
                                                  resumeVersion: nil, started: { found, _ in version.set(found) },
                                                  progress: { received.set($0.receivedBytes) })
        }
        try await waitUntil { received.value >= 2 << 20 }
        try fault("blackhole")
        let outage = ContinuousClock.now
        let result = await transfer.result
        let ended = outage.duration(to: .now)
        print("NETWORK_OUTAGE_DOWNLOAD ended=\(ended) result=\(result)")
        guard case .failure(let error) = result else { return XCTFail("The download finished during the outage") }
        XCTAssertTrue(Self.isTimeout(error) || Self.isConnectionEnded(error), "\(error)")
        XCTAssertLessThan(ended, .seconds(10 + 5 + 10), "Idle deadline plus close grace, with room for a loaded host")
        let partial = try XCTUnwrap(try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int)
        XCTAssertGreaterThan(partial, 0)
        XCTAssertLessThan(partial, 8 << 20)
        try fault("restore")
        let listing = try await service.listDirectory(profile: profile, path: environment.root)
        XCTAssertFalse(listing.entries.isEmpty)
        let offset = Counter()
        _ = try await service.downloadManagedFile(profile: profile, path: path, allowedRoot: root, destination: destination, limit: 16 << 20,
                                                  resumeVersion: version.value, started: { _, start in offset.set(start) }, progress: { _ in })
        print("NETWORK_OUTAGE_RESUME partial=\(partial) resumedFrom=\(offset.value)")
        XCTAssertGreaterThan(offset.value, 0, "The second attempt continues from the bytes kept")
        XCTAssertEqual(try sha(destination), try expected("big.bin"))
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 2, "The dead connection is replaced once")
    }

    /// A few seconds without network, as when walking between access points: TCP retransmits and the transfer
    /// finishes on the same connection.
    func testBriefOutageRecoversOnTheSameConnection() async throws {
        try fault("shape 0ms 0ms 0% 6mbit")
        let (service, profile) = try await connection()
        let destination = state.appendingPathComponent("brief.bin")
        let received = Counter()
        let path = environment.root + "/big.bin", root = environment.root
        let started = ContinuousClock.now
        let transfer = Task {
            try await service.downloadManagedFile(profile: profile, path: path, allowedRoot: root, destination: destination, limit: 16 << 20,
                                                  resumeVersion: nil, started: { _, _ in }, progress: { received.set($0.receivedBytes) })
        }
        try await waitUntil { received.value >= 2 << 20 }
        try fault("blackhole")
        try await Task.sleep(for: .seconds(5))
        try fault("restore")
        _ = try await transfer.value
        print("NETWORK_BRIEF_OUTAGE total=\(started.duration(to: .now))")
        XCTAssertEqual(try sha(destination), try expected("big.bin"))
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1)
    }

    /// Browsing during an outage reports a timeout at the production deadline. TCP outlives an outage this short,
    /// so only the stalled channel is replaced: browsing continues on the same authenticated connection.
    func testBrowsingDuringAnOutageTimesOutThenContinues() async throws {
        let (service, profile) = try await connection()
        _ = try await service.listDirectory(profile: profile, path: environment.root)
        try fault("blackhole")
        let outage = ContinuousClock.now
        do {
            _ = try await service.listDirectory(profile: profile, path: environment.root + "/tree")
            XCTFail("Listing succeeded without a network")
        } catch {
            XCTAssertTrue(Self.isTimeout(error), "\(error)")
        }
        let ended = outage.duration(to: .now)
        print("NETWORK_OUTAGE_BROWSE ended=\(ended)")
        XCTAssertGreaterThanOrEqual(ended, .seconds(14))
        XCTAssertLessThan(ended, .seconds(15 + 10))
        try fault("restore")
        let listing = try await service.listDirectory(profile: profile, path: environment.root + "/tree")
        XCTAssertEqual(listing.entries.count, 4)
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1)
    }

    /// Cancelling a folder save stalled by an outage returns promptly and publishes nothing; the save succeeds
    /// once the network is back.
    func testCancellingASaveStalledByAnOutagePublishesNothing() async throws {
        try fault("shape 0ms 0ms 0% 4mbit")
        let (service, profile) = try await connection()
        let store = try OfflineFileStore(directory: state.appendingPathComponent("offline"))
        addTeardownBlock { await store.cancelAndDrain() }
        let files = Counter()
        let root = environment.root
        let saving = Task {
            try await store.pinFolder(profile: profile, path: root + "/tree", service: service, progress: { files.set(UInt64($0.files)) })
        }
        try await waitUntil { files.value >= 2 }
        try fault("blackhole")
        try await Task.sleep(for: .seconds(3))
        let cancelled = ContinuousClock.now
        saving.cancel()
        let result = await saving.result
        let ended = cancelled.duration(to: .now)
        print("NETWORK_OUTAGE_SAVE_CANCEL ended=\(ended) result=\(result)")
        guard case .failure(let error) = result else { return XCTFail("The save finished during the outage") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertLessThan(ended, .seconds(5 + 10), "The close grace, with room for a loaded host")
        await store.cancelAndDrain()
        let pins = await store.snapshot()
        XCTAssertTrue(pins.isEmpty, "A cancelled save publishes no partial copy")
        try fault("clear")
        let again = try await saveTree(service: service, profile: profile, store: store)
        XCTAssertEqual(again, 48)
    }

    /// An outage that outlasts a folder save's own deadline fails the save, publishing nothing.
    func testOutageDuringAFolderSaveFailsAtItsDeadline() async throws {
        try fault("shape 0ms 0ms 0% 4mbit")
        let (service, profile) = try await connection()
        let store = try OfflineFileStore(directory: state.appendingPathComponent("offline"))
        addTeardownBlock { await store.cancelAndDrain() }
        let files = Counter()
        let root = environment.root
        let saving = Task {
            try await store.pinFolder(profile: profile, path: root + "/tree", service: service, progress: { files.set(UInt64($0.files)) })
        }
        try await waitUntil { files.value >= 2 }
        try fault("blackhole")
        let outage = ContinuousClock.now
        let result = await saving.result
        let ended = outage.duration(to: .now)
        print("NETWORK_OUTAGE_SAVE ended=\(ended) result=\(result)")
        guard case .failure = result else { return XCTFail("The save finished during the outage") }
        XCTAssertLessThan(ended, .seconds(180 + 5 + 20), "A file's deadline plus the close grace")
        // The store keeps the failed save's slot until its transfers have drained ("busy" until then).
        let draining = ContinuousClock.now
        await store.cancelAndDrain()
        print("NETWORK_OUTAGE_SAVE_DRAIN drained=\(draining.duration(to: .now))")
        let pins = await store.snapshot()
        XCTAssertTrue(pins.isEmpty, "A failed save publishes no partial copy")
        try fault("clear")
        let again = try await saveTree(service: service, profile: profile, store: store)
        XCTAssertEqual(again, 48)
    }

    private static func isTimeout(_ error: Error) -> Bool {
        if case RemoteFileError.timedOut = error { return true }
        return false
    }

    private static func isConnectionEnded(_ error: Error) -> Bool {
        if case RemoteFileError.connectionEnded = error { return true }
        return false
    }

    // MARK: - Fixture

    private func connection() async throws -> (SFTPRemoteFileService, ConnectionProfile) {
        let identities = IdentityStore(secretStore: NetworkFaultSecrets())
        let identity = try await identities.importKey(name: "Network fixture",
            openSSH: String(contentsOfFile: environment.local + "/client", encoding: .utf8))
        let metadata = try MetadataStore(fileURL: state.appendingPathComponent("metadata.json"))
        let trust = try HostTrustStore(fileURL: state.appendingPathComponent("trust.json"))
        let key = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: String(contentsOfFile: environment.local + "/host.pub", encoding: .utf8)))
        try await trust.trustUnknown(endpoint: .init(host: environment.host, port: environment.port), key: key)
        let profile = ConnectionProfile(name: "Network fixture", host: environment.host, port: environment.port, username: environment.user,
                                        identityID: identity.id, startingDirectory: environment.root)
        var saved = AppMetadata(); saved.identities = [identity]; saved.connections = [profile]
        try await metadata.save(saved)
        let service = SFTPRemoteFileService(identityStore: identities, trustStore: trust, metadataStore: metadata, timeoutSeconds: 15)
        addTeardownBlock { await service.disconnect() }
        return (service, profile)
    }

    private func saveTree(service: SFTPRemoteFileService, profile: ConnectionProfile, store existing: OfflineFileStore? = nil) async throws -> Int {
        let store = try existing ?? OfflineFileStore(directory: state.appendingPathComponent("offline-" + UUID().uuidString))
        let folder = try await store.pinFolder(profile: profile, path: environment.root + "/tree", service: service)
        for id in folder.fileIDs {
            let lease = try await store.lease(id)
            let relative = String(lease.pin.path.dropFirst(environment.root.count + 1))
            XCTAssertEqual(try sha(lease.url), try expected(relative), relative)
        }
        return folder.fileIDs.count
    }

    private func fault(_ arguments: String) throws {
        try Self.run(environment.control + " " + arguments)
    }

    private static func run(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RemoteFileError.unavailable("Fault command failed: \(command)") }
    }

    private func expected(_ relative: String) throws -> String {
        let manifest = try String(contentsOfFile: environment.local + "/manifest.sha256", encoding: .utf8)
        for line in manifest.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == "./" + relative { return String(parts[0]) }
        }
        throw RemoteFileError.notFound
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RemoteFileError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var stored: UInt64 = 0
    var value: UInt64 { lock.withLock { stored } }
    func set(_ value: UInt64) { lock.withLock { stored = value } }
}

private final class VersionBox: @unchecked Sendable {
    private let lock = NSLock(); private var stored: RemoteFileVersion?
    var value: RemoteFileVersion? { lock.withLock { stored } }
    func set(_ value: RemoteFileVersion?) { lock.withLock { stored = value } }
}

private final class NetworkFaultSecrets: IdentitySecretStore, @unchecked Sendable {
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
