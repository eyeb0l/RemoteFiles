import XCTest
import Foundation
import Crypto
import NIOSSH
import Citadel
@testable import RemoteFilesCore

/// Opt-in physical-iPhone acceptance: cancellation, outages on the phone's own socket, and a one-channel server,
/// against disposable OpenSSH daemons reached over the phone's real network. Faults are applied on the server to the
/// fixture's port alone, through a key whose forced command allows nothing else. See README.md. Kept outside the
/// default target; it is copied into the hosted test target of a snapshot and configured with `TEST_RUNNER_` variables.
final class DeviceChannelAcceptanceTests: XCTestCase {
    private struct Environment {
        let host: String, port: Int, oneChannelPort: Int, controlPort: Int, user: String
        let root: String, searchRoot: String, clientKey: String, controlKey: String, hostKey: String, manifest: String
        static func load() throws -> Environment {
            let env = ProcessInfo.processInfo.environment
            func value(_ name: String) throws -> String { try XCTUnwrap(env["DEVICE_" + name], "Set TEST_RUNNER_DEVICE_\(name)") }
            return try Environment(host: value("HOST"), port: XCTUnwrap(Int(value("PORT"))), oneChannelPort: XCTUnwrap(Int(value("ONE_CHANNEL_PORT"))),
                                   controlPort: XCTUnwrap(Int(value("CONTROL_PORT"))), user: value("USER"), root: value("ROOT"),
                                   searchRoot: value("SEARCH_ROOT"), clientKey: value("CLIENT_KEY"), controlKey: value("CONTROL_KEY"),
                                   hostKey: value("HOST_KEY"), manifest: value("MANIFEST"))
        }
    }

    private var environment: Environment!
    private var state: URL!
    private var control: SSHClient?

    override func setUp() async throws {
        environment = try Environment.load()
        state = FileManager.default.temporaryDirectory.appendingPathComponent("device-acceptance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try await fault(environment.port, "clear")
        try await fault(environment.oneChannelPort, "clear")
        let state = state!
        addTeardownBlock { [self] in
            try? await fault(environment.port, "clear")
            try? await fault(environment.oneChannelPort, "clear")
            try? await control?.close()
            try? FileManager.default.removeItem(at: state)
        }
    }

    /// Cancelling a download, a folder save and a server search on the phone returns promptly, publishes nothing
    /// and leaves the authenticated connection browsing and searching.
    func testCancellationOnThePhone() async throws {
        try await fault(environment.port, "shape 0ms 0ms 0% 8mbit")
        let (service, profile) = try await connection(port: environment.port)
        _ = try await service.listDirectory(profile: profile, path: environment.root)

        let received = Counter()
        let download = Task { [environment, state] in
            try await service.downloadManagedFile(profile: profile, path: environment!.root + "/big.bin", allowedRoot: environment!.root,
                destination: state!.appendingPathComponent("cancelled.bin"), limit: 16 << 20, resumeVersion: nil,
                started: { _, _ in }, progress: { received.set($0.receivedBytes) })
        }
        try await waitUntil { received.value >= 1 << 20 }
        var cancelled = ContinuousClock.now
        download.cancel()
        let downloadResult = await download.result
        let downloadEnded = cancelled.duration(to: .now)
        XCTAssertTrue(Self.isCancellation(downloadResult), "\(downloadResult)")

        let store = try OfflineFileStore(directory: state.appendingPathComponent("offline"))
        addTeardownBlock { await store.cancelAndDrain() }
        let files = Counter()
        let save = Task { [environment] in
            try await store.pinFolder(profile: profile, path: environment!.root + "/tree", service: service, progress: { files.set(UInt64($0.files)) })
        }
        try await waitUntil { files.value >= 2 }
        cancelled = .now
        save.cancel()
        let saveResult = await save.result
        let saveEnded = cancelled.duration(to: .now)
        XCTAssertTrue(Self.isCancellation(saveResult), "\(saveResult)")
        await store.cancelAndDrain()
        let pins = await store.snapshot()
        XCTAssertTrue(pins.isEmpty, "A cancelled save publishes no partial copy")

        try await fault(environment.port, "clear")
        let search = Task { [environment] in
            for try await _ in RemoteFolderSearch.contents(matching: "needle", below: environment!.searchRoot + "/large", profile: profile,
                                                            service: service, includeHidden: false) { }
            try Task.checkCancellation()
        }
        while await service.metrics().serverSearchAttempts == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(150))
        cancelled = .now
        search.cancel()
        let searchResult = await search.result
        let searchEnded = cancelled.duration(to: .now)
        XCTAssertTrue(Self.isCancellation(searchResult), "\(searchResult)")

        let listing = try await service.listDirectory(profile: profile, path: environment.root + "/tree")
        XCTAssertEqual(listing.entries.count, 4)
        var names: [String] = []
        for try await update in RemoteFolderSearch.names(matching: "needle", below: environment.root, profile: profile, service: service, includeHidden: false) {
            names += update.matches.map(\.name)
        }
        XCTAssertEqual(names, ["needle.txt"])
        let metrics = await service.metrics()
        print("DEVICE_CANCEL download=\(downloadEnded) save=\(saveEnded) search=\(searchEnded) helper=\(metrics.serverSearchOperations) connections=\(metrics.connections)")
        for ended in [downloadEnded, saveEnded, searchEnded] { XCTAssertLessThan(ended, .seconds(3)) }
        XCTAssertGreaterThanOrEqual(metrics.serverSearchOperations, 1, "The helper still runs after a cancelled search")
        XCTAssertEqual(metrics.connections, 1)
    }

    /// The phone's own socket loses the server mid-download: the transfer ends at its idle limit, then resumes
    /// from the kept bytes; a short outage is ridden out; cancelling during an outage returns after the close grace.
    func testOutagesOnThePhonesSocket() async throws {
        try await fault(environment.port, "shape 0ms 0ms 0% 6mbit")
        let (service, profile) = try await connection(port: environment.port)
        await service.setTransferTimings(idle: .seconds(10), closeGrace: .seconds(5))
        let path = environment.root + "/big.bin", root = environment.root
        let destination = state.appendingPathComponent("resumable.bin")
        let received = Counter(), version = VersionBox()
        let first = Task {
            try await service.downloadManagedFile(profile: profile, path: path, allowedRoot: root, destination: destination, limit: 16 << 20,
                resumeVersion: nil, started: { found, _ in version.set(found) }, progress: { received.set($0.receivedBytes) })
        }
        try await waitUntil { received.value >= 2 << 20 }
        try await fault(environment.port, "blackhole")
        var outage = ContinuousClock.now
        let firstResult = await first.result
        let idleEnded = outage.duration(to: .now)
        guard case .failure(let error) = firstResult else { return XCTFail("The download finished during the outage") }
        XCTAssertTrue(Self.isTimeout(error) || Self.isConnectionEnded(error), "\(error)")
        XCTAssertLessThan(idleEnded, .seconds(10 + 5 + 15))
        try await fault(environment.port, "restore")
        let offset = Counter()
        _ = try await service.downloadManagedFile(profile: profile, path: path, allowedRoot: root, destination: destination, limit: 16 << 20,
            resumeVersion: version.value, started: { _, start in offset.set(start) }, progress: { _ in })
        XCTAssertGreaterThan(offset.value, 0, "The retry continues from the kept bytes")
        XCTAssertEqual(try sha(destination), try expected("big.bin"))

        // Production allowances from here: these must succeed or end by cancellation.
        await service.setTransferTimings(idle: .seconds(60), closeGrace: .seconds(5))
        received.set(0)
        let brief = Task {
            try await service.downloadManagedFile(profile: profile, path: path, allowedRoot: root, destination: self.state.appendingPathComponent("brief.bin"),
                limit: 16 << 20, resumeVersion: nil, started: { _, _ in }, progress: { received.set($0.receivedBytes) })
        }
        try await waitUntil { received.value >= 2 << 20 }
        try await fault(environment.port, "blackhole")
        try await Task.sleep(for: .seconds(5))
        try await fault(environment.port, "restore")
        _ = try await brief.value
        XCTAssertEqual(try sha(state.appendingPathComponent("brief.bin")), try expected("big.bin"))

        received.set(0)
        let stuck = Task {
            try await service.downloadManagedFile(profile: profile, path: path, allowedRoot: root, destination: self.state.appendingPathComponent("stuck.bin"),
                limit: 16 << 20, resumeVersion: nil, started: { _, _ in }, progress: { received.set($0.receivedBytes) })
        }
        try await waitUntil { received.value >= 2 << 20 }
        try await fault(environment.port, "blackhole")
        try await Task.sleep(for: .seconds(2))
        outage = .now
        stuck.cancel()
        let stuckResult = await stuck.result
        let cancelEnded = outage.duration(to: .now)
        XCTAssertTrue(Self.isCancellation(stuckResult), "\(stuckResult)")
        XCTAssertLessThan(cancelEnded, .seconds(5 + 5), "The close grace, with room for a loaded phone")
        try await fault(environment.port, "clear")
        let listing = try await service.listDirectory(profile: profile, path: environment.root + "/tree")
        XCTAssertEqual(listing.entries.count, 4)
        let metrics = await service.metrics()
        print("DEVICE_OUTAGE idle=\(idleEnded) resumedFrom=\(offset.value) cancelDuringOutage=\(cancelEnded) connections=\(metrics.connections)")
    }

    /// A server allowing one session channel: search before browsing, browsing during a folder save, a download, and
    /// cancelling a save that borrowed browsing's channel, all on one connection from the phone.
    func testOneChannelServerOnThePhone() async throws {
        try await fault(environment.oneChannelPort, "shape 0ms 0ms 0% 20mbit")
        let (service, profile) = try await connection(port: environment.oneChannelPort)
        var found: [String] = []
        for try await update in RemoteFolderSearch.names(matching: "file-11", below: environment.root + "/tree", profile: profile,
                                                         service: service, includeHidden: false) {
            found += update.matches.map(\.name)
        }
        XCTAssertEqual(found.count, 4)
        let tree = try await service.listDirectory(profile: profile, path: environment.root + "/tree").path
        _ = try await service.listDirectoryForWalk(profile: profile, path: tree)
        let store = try OfflineFileStore(directory: state.appendingPathComponent("one-channel"))
        addTeardownBlock { await store.cancelAndDrain() }
        let saving = Task { try await store.pinFolder(profile: profile, path: tree, service: service) }
        try await waitForLoan(service)
        let browsed = ContinuousClock.now
        let listing = try await service.listDirectory(profile: profile, path: tree + "/folder 3")
        let browseWaited = browsed.duration(to: .now)
        XCTAssertEqual(listing.entries.count, 12)
        let folder = try await saving.value
        let loans = await service.metrics().foregroundLoans
        XCTAssertGreaterThanOrEqual(loans, 2, "The save gave the channel back for browsing, then borrowed it again")
        XCTAssertEqual(folder.fileIDs.count, 48)
        for id in folder.fileIDs {
            let lease = try await store.lease(id)
            XCTAssertEqual(try sha(lease.url), try expected(String(lease.pin.path.dropFirst(environment.root.count + 1))))
        }
        _ = try await service.listDirectory(profile: profile, path: tree)
        let destination = state.appendingPathComponent("one-channel.bin")
        _ = try await service.downloadSnapshotFile(profile: profile, path: environment.root + "/big.bin", canonicalRoot: environment.root,
                                                   destination: destination, limit: 16 << 20, progress: { _ in })
        XCTAssertEqual(try sha(destination), try expected("big.bin"))

        let cancelStore = try OfflineFileStore(directory: state.appendingPathComponent("one-channel-cancelled"))
        addTeardownBlock { await cancelStore.cancelAndDrain() }
        let before = await service.metrics().foregroundLoans
        let cancelling = Task { try await cancelStore.pinFolder(profile: profile, path: tree, service: service) }
        let deadline = ContinuousClock.now + .seconds(60)
        while await service.metrics().foregroundLoans == before, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let cancelled = ContinuousClock.now
        cancelling.cancel()
        let result = await cancelling.result
        let cancelEnded = cancelled.duration(to: .now)
        XCTAssertTrue(Self.isCancellation(result), "\(result)")
        await cancelStore.cancelAndDrain()
        let pins = await cancelStore.snapshot()
        XCTAssertTrue(pins.isEmpty)
        let after = try await service.listDirectory(profile: profile, path: tree + "/folder 1")
        XCTAssertEqual(after.entries.count, 12)
        let metrics = await service.metrics()
        print("DEVICE_ONE_CHANNEL loans=\(metrics.foregroundLoans) browseWaited=\(browseWaited) cancel=\(cancelEnded) connections=\(metrics.connections)")
        XCTAssertLessThan(cancelEnded, .seconds(3))
        XCTAssertEqual(metrics.connections, 1)
    }

    // MARK: - Fixture

    private func connection(port: Int) async throws -> (SFTPRemoteFileService, ConnectionProfile) {
        let identities = IdentityStore(secretStore: DeviceSecrets())
        let identity = try await identities.importKey(name: "Device fixture", openSSH: environment.clientKey)
        let metadata = try MetadataStore(fileURL: state.appendingPathComponent("metadata-\(port).json"))
        let trust = try HostTrustStore(fileURL: state.appendingPathComponent("trust-\(port).json"))
        try await trust.trustUnknown(endpoint: .init(host: environment.host, port: port),
                                     key: HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: environment.hostKey)))
        let profile = ConnectionProfile(name: "Device fixture", host: environment.host, port: port, username: environment.user,
                                        identityID: identity.id, startingDirectory: environment.root)
        var saved = AppMetadata(); saved.identities = [identity]; saved.connections = [profile]
        try await metadata.save(saved)
        let service = SFTPRemoteFileService(identityStore: identities, trustStore: trust, metadataStore: metadata, timeoutSeconds: 15)
        addTeardownBlock { await service.disconnect() }
        return (service, profile)
    }

    /// The control daemon runs only a gate script that accepts these fault actions for the fixture ports.
    private func fault(_ port: Int, _ action: String) async throws {
        if control == nil || control?.isConnected != true {
            let identities = IdentityStore(secretStore: DeviceSecrets())
            let key = try await identities.unlock(try await identities.importKey(name: "Fault control", openSSH: environment.controlKey))
            let trust = try HostTrustStore(fileURL: state.appendingPathComponent("control-trust.json"))
            let endpoint = HostEndpoint(host: environment.host, port: environment.controlPort)
            try await trust.trustUnknown(endpoint: endpoint, key: HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: environment.hostKey)))
            control = try await SSHClient.connect(to: SSHClientSettings(host: environment.host, port: environment.controlPort,
                authenticationMethod: { key.authentication(username: self.environment.user) },
                hostKeyValidator: .custom(TrustValidator(store: trust, endpoint: endpoint))))
        }
        _ = try await SFTPRemoteFileService.executeSearchCommand(client: try XCTUnwrap(control), command: "\(port) \(action)", timeout: 20)
    }

    private func waitForLoan(_ service: SFTPRemoteFileService) async throws {
        try await waitUntilAsync { await service.metrics().foregroundLoans > 0 }
    }

    private func expected(_ relative: String) throws -> String {
        for line in environment.manifest.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == "./" + relative { return String(parts[0]) }
        }
        throw RemoteFileError.notFound
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        try await waitUntilAsync { condition() }
    }

    private func waitUntilAsync(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Condition not reached"); throw RemoteFileError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func isCancellation<T>(_ result: Result<T, Error>) -> Bool {
        if case .failure(let error) = result { return error is CancellationError }
        return false
    }

    private static func isTimeout(_ error: Error) -> Bool {
        if case RemoteFileError.timedOut = error { return true }
        return false
    }

    private static func isConnectionEnded(_ error: Error) -> Bool {
        if case RemoteFileError.connectionEnded = error { return true }
        return false
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

private final class DeviceSecrets: IdentitySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func save(_ data: Data, reference: String) throws { lock.withLock { values[reference] = data } }
    func load(reference: String) throws -> Data {
        try lock.withLock { guard let data = values[reference] else { throw IdentityError.missingSecret }; return data }
    }
    func delete(reference: String) throws { lock.withLock { _ = values.removeValue(forKey: reference) } }
}
