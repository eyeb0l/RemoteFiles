import XCTest
import Foundation
import NIOSSH
import Citadel
@testable import RemoteFilesCore

final class LinuxServerSearchAcceptanceTests: XCTestCase {
    private func connection(restricted: Bool = false) async throws -> (SFTPRemoteFileService, ConnectionProfile, String) {
        let env = ProcessInfo.processInfo.environment
        let local = try XCTUnwrap(env["LINUX_SEARCH_LOCAL"])
        let root = try XCTUnwrap(env["LINUX_SEARCH_ROOT"])
        let port = try XCTUnwrap(Int(env["LINUX_SEARCH_PORT"] ?? ""))
        let user = try XCTUnwrap(env["LINUX_SEARCH_USER"])
        let directory = URL(fileURLWithPath: local).appendingPathComponent(UUID().uuidString)
        let identities = IdentityStore(secretStore: LinuxSearchSecrets())
        let identity = try await identities.importKey(name: "Linux fixture", openSSH: String(contentsOfFile: local + (restricted ? "/restricted" : "/client"), encoding: .utf8))
        let metadata = try MetadataStore(fileURL: directory.appendingPathComponent("metadata.json"))
        let trust = try HostTrustStore(fileURL: directory.appendingPathComponent("trust.json"))
        let key = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: String(contentsOfFile: local + "/host.pub", encoding: .utf8)))
        try await trust.trustUnknown(endpoint: .init(host: "127.0.0.1", port: port), key: key)
        let profile = ConnectionProfile(name: "Linux fixture", host: "127.0.0.1", port: port, username: user,
                                        identityID: identity.id, startingDirectory: root)
        var saved = AppMetadata(); saved.identities = [identity]; saved.connections = [profile]
        try await metadata.save(saved)
        let service = SFTPRemoteFileService(identityStore: identities, trustStore: trust, metadataStore: metadata, timeoutSeconds: 15)
        addTeardownBlock { await service.disconnect() }
        return (service, profile, root)
    }

    func testProductionAdapterUsesLinuxServerForNamesAndContents() async throws {
        let (service, profile, root) = try await connection()
        var names: [String] = []
        for try await update in RemoteFolderSearch.names(matching: "needle", below: root, profile: profile, service: service, includeHidden: false) {
            names += update.matches.map(\.name)
        }
        XCTAssertEqual(Set(names), ["needle-2.txt", "needle-10.txt", "needle-link.txt"])
        var found: [RemoteFolderSearch.ContentMatch] = []
        for try await update in RemoteFolderSearch.contents(matching: "[x].*", below: root, profile: profile, service: service, includeHidden: false) {
            found += update.contentMatches
        }
        XCTAssertEqual(found.map(\.entry.name), ["needle-2.txt"])
        XCTAssertEqual(found.first?.line, 2)
        XCTAssertEqual(found.first?.snippet, "Needle café [x].*")
        var hidden: [String] = []
        for try await update in RemoteFolderSearch.names(matching: "needle", below: root, profile: profile, service: service, includeHidden: true) {
            hidden += update.matches.map(\.name)
        }
        XCTAssertEqual(hidden.count, 4)
        let metrics = await service.metrics()
        print("LINUX_SUPPORTED attempts=\(metrics.serverSearchAttempts) completed=\(metrics.serverSearchOperations) sftpReads=\(metrics.fileOperations) connections=\(metrics.connections)")
        XCTAssertEqual(metrics.serverSearchAttempts, 3)
        XCTAssertEqual(metrics.serverSearchOperations, 3, "Silent SFTP fallback is not an end-to-end pass")
        XCTAssertEqual(metrics.fileOperations, 0)
        XCTAssertEqual(metrics.connections, 1)
        let listing = try await service.listDirectory(profile: profile, path: root + "/sub")
        XCTAssertTrue(listing.entries.contains { $0.name == "source.md" })
    }

    func testSFTPOnlyLinuxAccountFallsBackAndKeepsBrowsingConnected() async throws {
        let (service, profile, root) = try await connection(restricted: true)
        for _ in 0..<2 {
            var contents: [String] = []
            for try await update in RemoteFolderSearch.contents(matching: "needle", below: root + "/sub", profile: profile, service: service, includeHidden: false) {
                contents += update.contentMatches.map(\.entry.name)
            }
            XCTAssertEqual(contents, ["source.md"])
        }
        let metrics = await service.metrics()
        print("LINUX_FALLBACK attempts=\(metrics.serverSearchAttempts) completed=\(metrics.serverSearchOperations) sftpReads=\(metrics.fileOperations) connections=\(metrics.connections)")
        XCTAssertEqual(metrics.serverSearchAttempts, 1)
        XCTAssertEqual(metrics.serverSearchOperations, 0)
        XCTAssertEqual(metrics.fileOperations, 2)
        XCTAssertEqual(metrics.connections, 1)
        _ = try await service.listDirectory(profile: profile, path: root)
    }

    func testLinuxServerRespectsLimitsAndNeverReadsEscapeLinks() async throws {
        let (service, profile, root) = try await connection()
        var limited: RemoteFolderSearch.Update?
        for try await update in RemoteFolderSearch.contents(matching: "needle", below: root + "/large", profile: profile, service: service, includeHidden: false, contentLimits: .init(maxFiles: 1)) { limited = update }
        XCTAssertEqual(limited?.stop, .fileLimit)
        XCTAssertEqual(limited?.filesSearched, 1)
        XCTAssertEqual(limited?.contentMatches.count, 1)
        var escapeMatches = 0
        for try await update in RemoteFolderSearch.contents(matching: "outside secret", below: root, profile: profile, service: service, includeHidden: false, limits: .init(maxDepth: 0)) { escapeMatches += update.contentMatches.count }
        XCTAssertEqual(escapeMatches, 0)
        var timed: RemoteFolderSearch.Update?
        for try await update in RemoteFolderSearch.names(matching: "needle", below: root, profile: profile, service: service, includeHidden: false, limits: .init(timeLimit: .nanoseconds(1))) { timed = update }
        XCTAssertEqual(timed?.stop, .timeLimit)
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.serverSearchOperations, 3, "All limits must be enforced by the real helper")
        XCTAssertEqual(metrics.fileOperations, 0)
    }

    func testLinuxHelperRejectsDifferentKernelIdentitiesBeforeReadingData() async throws {
        let env = ProcessInfo.processInfo.environment
        let local = try XCTUnwrap(env["LINUX_SEARCH_LOCAL"])
        let root = try XCTUnwrap(env["LINUX_SEARCH_ROOT"])
        let port = try XCTUnwrap(Int(env["LINUX_SEARCH_PORT"] ?? ""))
        let user = try XCTUnwrap(env["LINUX_SEARCH_USER"])
        let identities = IdentityStore(secretStore: LinuxSearchSecrets())
        let identity = try await identities.importKey(name: "Linux identity rejection", openSSH: String(contentsOfFile: local + "/client", encoding: .utf8))
        let key = try await identities.unlock(identity)
        let trust = try HostTrustStore(fileURL: URL(fileURLWithPath: local).appendingPathComponent(UUID().uuidString + ".json"))
        let hostKey = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: String(contentsOfFile: local + "/host.pub", encoding: .utf8)))
        let endpoint = HostEndpoint(host: "127.0.0.1", port: port)
        try await trust.trustUnknown(endpoint: endpoint, key: hostKey)
        let client = try await SSHClient.connect(to: SSHClientSettings(host: endpoint.host, port: port,
            authenticationMethod: { key.authentication(username: user) },
            hostKeyValidator: .custom(TrustValidator(store: trust, endpoint: endpoint))))
        addTeardownBlock { try? await client.close() }
        let probe = "import os,json,sys; fd=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY); print(json.dumps(dict(info=open('/proc/self/fdinfo/'+str(fd)).read(),namespace=os.readlink('/proc/self/ns/mnt'))))"
        let output = try await SFTPRemoteFileService.executeSearchCommand(client: client,
            command: "python3 -I -S -B -c " + ServerFolderSearch.quote(probe) + " " + ServerFolderSearch.quote(root), timeout: 5)
        let fields = try JSONDecoder().decode([String: String].self, from: Data(output.readableBytesView))
        let valid = try ServerFolderSearch.RootIdentity(fdinfo: XCTUnwrap(fields["info"]), namespace: XCTUnwrap(fields["namespace"]))
        let cases = [
            (root, valid.inode + 1, valid.mountID, valid.namespace),
            (root, valid.inode, valid.mountID + 1, valid.namespace),
            (root, valid.inode, valid.mountID, "mnt:[0]"),
            (root + "/sub", valid.inode, valid.mountID, valid.namespace)
        ]
        for (path, inode, mountID, namespace) in cases {
            let mismatched = try ServerFolderSearch.RootIdentity(fdinfo: "ino: \(inode)\nmnt_id: \(mountID)", namespace: namespace)
            let command = try ServerFolderSearch.command(query: "needle", root: path, includeHidden: true,
                limits: .init(), content: .init(), identity: mismatched)
            let response = try await SFTPRemoteFileService.executeSearchCommand(client: client, command: command, timeout: 5)
            let value = try JSONDecoder().decode(ServerFolderSearch.Response.self, from: Data(response.readableBytesView))
            XCTAssertEqual(value.error, "unsupported")
            XCTAssertEqual(value.folders, 0)
            XCTAssertEqual(value.files, 0)
            XCTAssertEqual(value.bytes, 0)
            XCTAssertTrue(value.candidates.isEmpty)
        }
    }

    func testCancellingLinuxSearchKeepsTheConnectionUsable() async throws {
        let (service, profile, root) = try await connection()
        _ = try await service.listDirectory(profile: profile, path: root)
        let task = Task {
            for try await _ in RemoteFolderSearch.contents(matching: "needle", below: root + "/large", profile: profile, service: service, includeHidden: false) { }
            try Task.checkCancellation()
        }
        while await service.metrics().serverSearchAttempts == 0 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        task.cancel()
        do { try await task.value; XCTFail("Search must be cancelled") } catch is CancellationError { }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        _ = try await service.listDirectory(profile: profile, path: root + "/sub")
        var names: [String] = []
        for try await update in RemoteFolderSearch.names(matching: "source", below: root + "/sub", profile: profile, service: service, includeHidden: false) { names += update.matches.map(\.name) }
        XCTAssertEqual(names, ["source.md"])
        let metrics = await service.metrics()
        XCTAssertGreaterThanOrEqual(metrics.serverSearchOperations, 1)
        XCTAssertEqual(metrics.connections, 1)
    }
}

private final class LinuxSearchSecrets: IdentitySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func save(_ data: Data, reference: String) throws { lock.lock(); defer { lock.unlock() }; values[reference] = data }
    func load(reference: String) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let data = values[reference] else { throw IdentityError.missingSecret }; return data }
    func delete(reference: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: reference) }
}
