import XCTest
import Foundation
import Crypto
import NIOSSH
@testable import RemoteFilesCore

/// A private address means whatever the jump host's network says it means. Trust for a server
/// behind a jump host therefore belongs to that route, not to the address alone.
final class HostTrustRouteTests: XCTestCase {
    private let bastionA = HostEndpoint(host: "bastion-a.example", port: 22)
    private let bastionB = HostEndpoint(host: "bastion-b.example", port: 2222)

    private func newKey() throws -> (NIOSSHPublicKey, HostKeyDetails) {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        return (key, try HostKeyDetails(publicKey: key))
    }

    private func trustFile() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trust-routes-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("trusted-hosts.json")
    }

    private func connection(_ name: String, host: String = "10.0.0.5", through jump: HostEndpoint? = nil) -> ConnectionProfile {
        var profile = ConnectionProfile(name: name, host: host, username: "reader", identityID: UUID(), startingDirectory: "/")
        if let jump { profile.jumpHost = JumpHost(host: jump.host, port: jump.port, username: "hop", identityID: UUID()) }
        return profile
    }

    private func assertUnknown(_ store: HostTrustStore, _ endpoint: HostEndpoint, _ key: NIOSSHPublicKey,
                               _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await store.validate(endpoint: endpoint, publicKey: key); XCTFail(message, file: file, line: line) }
        catch HostTrustError.unknown(let asked, _) { XCTAssertEqual(asked, endpoint, file: file, line: line) }
        catch { XCTFail("\(message): \(error)", file: file, line: line) }
    }

    /// What a build from before routes wrote: an endpoint is a host and a port, nothing else.
    private struct EarlierDocument: Codable {
        struct Endpoint: Codable { let host: String; let port: Int }
        struct Record: Codable { let endpoint: Endpoint; let key: HostKeyDetails }
        let version: Int
        let records: [Record]
    }

    private func writeEarlierFile(_ records: [(HostEndpoint, HostKeyDetails)], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = EarlierDocument(version: 1, records: records.map { .init(endpoint: .init(host: $0.0.host, port: $0.0.port), key: $0.1) })
        try JSONEncoder().encode(document).write(to: url)
    }

    func testTheSameAddressBehindTwoJumpHostsHasTwoTrustedKeys() async throws {
        let store = try HostTrustStore(fileURL: trustFile())
        let throughA = HostEndpoint(host: "10.0.0.5", port: 22, via: bastionA), throughB = HostEndpoint(host: "10.0.0.5", port: 22, via: bastionB)
        let (keyA, detailsA) = try newKey(), (keyB, detailsB) = try newKey()
        try await store.trustUnknown(endpoint: throughA, key: detailsA)
        await assertUnknown(store, throughB, keyB, "The other route's server is new, not a changed one")
        try await store.trustUnknown(endpoint: throughB, key: detailsB)
        try await store.validate(endpoint: throughA, publicKey: keyA)
        try await store.validate(endpoint: throughB, publicKey: keyB)
        do { try await store.validate(endpoint: throughB, publicKey: keyA); XCTFail("Each route keeps its own key") }
        catch HostTrustError.changed(let endpoint, let previous, _) { XCTAssertEqual(endpoint, throughB); XCTAssertEqual(previous, detailsB) }

        try await store.reset(endpoint: throughA)
        await assertUnknown(store, throughA, keyA, "The reset route asks again")
        try await store.validate(endpoint: throughB, publicKey: keyB)
    }

    func testAnAddressReachedDirectlyIsNotTheSameAddressBehindAJumpHost() async throws {
        let url = trustFile()
        let store = try HostTrustStore(fileURL: url)
        let direct = HostEndpoint(host: "10.0.0.5", port: 22), routed = HostEndpoint(host: "10.0.0.5", port: 22, via: bastionA)
        let (key, details) = try newKey()
        try await store.trustUnknown(endpoint: direct, key: details)
        await assertUnknown(store, routed, key, "Trust for the direct server says nothing about the one behind the jump host")
        try await store.trustUnknown(endpoint: routed, key: details)
        try await store.reset(endpoint: direct)
        try await HostTrustStore(fileURL: url).validate(endpoint: routed, publicKey: key)
        XCTAssertEqual(routed.displayName, "10.0.0.5:22 through bastion-a.example:22")
        XCTAssertEqual(direct.displayName, "10.0.0.5:22")
    }

    func testTheKeysTrustedForAConnectionAreItsRoutes() async throws {
        let store = try HostTrustStore(fileURL: trustFile())
        let profile = connection("Behind A", through: bastionA)
        let (_, server) = try newKey(), (_, hop) = try newKey()
        try await store.trustUnknown(endpoint: HostEndpoint(host: "10.0.0.5", port: 22), key: server)
        try await store.trustUnknown(endpoint: bastionA, key: hop)
        let before = await store.trustedKeys(for: profile)
        XCTAssertNil(before, "The address reached directly is another server")
        try await store.trustUnknown(endpoint: .destination(of: profile), key: server)
        let after = await store.trustedKeys(for: profile)
        XCTAssertEqual(after, ServerHostKeys(destination: server, jumpHost: hop))
        XCTAssertEqual(HostEndpoint.all(of: profile), [HostEndpoint(host: "10.0.0.5", port: 22, via: bastionA), bastionA])
    }

    /// Nobody is asked to verify again a key they already trusted through a jump host.
    func testAnEarlierFilesRecordGoesToTheConnectionsThatReachItThroughAJumpHost() async throws {
        let url = trustFile()
        let (serverKey, server) = try newKey(), (hopKey, hop) = try newKey(), (otherKey, other) = try newKey()
        let address = HostEndpoint(host: "10.0.0.5", port: 22), elsewhere = HostEndpoint(host: "files.example", port: 22)
        try writeEarlierFile([(address, server), (bastionA, hop), (elsewhere, other)], to: url)
        let store = try HostTrustStore(fileURL: url)
        let behindA = connection("Behind A", through: bastionA), behindB = connection("Behind B", through: bastionB)
        try await store.adoptJumpRoutes(of: [behindA, behindB, connection("Elsewhere", host: "files.example")])

        try await store.validate(endpoint: .destination(of: behindA), publicKey: serverKey)
        try await store.validate(endpoint: .destination(of: behindB), publicKey: serverKey)
        await assertUnknown(store, address, serverKey, "No saved connection reaches that address directly")
        try await store.validate(endpoint: bastionA, publicKey: hopKey)
        try await store.validate(endpoint: elsewhere, publicKey: otherKey)
        // And it is what was saved, not only what is in memory.
        let reloaded = try HostTrustStore(fileURL: url)
        try await reloaded.validate(endpoint: .destination(of: behindB), publicKey: serverKey)
        await assertUnknown(reloaded, address, serverKey, "Saved without the direct record")
    }

    func testTheDirectRecordStaysWhileAConnectionReachesThatAddressDirectlyOrJumpsThroughIt() async throws {
        let url = trustFile()
        let (serverKey, server) = try newKey(), (hopKey, hop) = try newKey()
        let address = HostEndpoint(host: "10.0.0.5", port: 22)
        try writeEarlierFile([(address, server), (bastionA, hop)], to: url)
        let store = try HostTrustStore(fileURL: url)
        let behindA = connection("Behind A", through: bastionA)
        // The second connection reaches a server behind the first one's bastion, and that bastion is its own destination too.
        let nested = connection("Behind the bastion", host: "10.0.0.9", through: bastionA)
        try await store.adoptJumpRoutes(of: [behindA, connection("Direct"), nested, connection("The bastion itself", host: bastionA.host)])
        try await store.validate(endpoint: .destination(of: behindA), publicKey: serverKey)
        try await store.validate(endpoint: address, publicKey: serverKey)
        try await store.validate(endpoint: bastionA, publicKey: hopKey)
    }

    /// A connection added later must verify its server: taking over a record is for what was
    /// trusted before routes existed, not a standing rule.
    func testRecordsAreTakenOverOnce() async throws {
        let url = trustFile()
        let (serverKey, server) = try newKey()
        let address = HostEndpoint(host: "10.0.0.5", port: 22)
        try writeEarlierFile([(address, server)], to: url)
        let store = try HostTrustStore(fileURL: url)
        let direct = connection("Direct"), behindA = connection("Behind A", through: bastionA), behindB = connection("Behind B", through: bastionB)
        try await store.adoptJumpRoutes(of: [direct, behindA])
        try await store.adoptJumpRoutes(of: [direct, behindA, behindB])
        await assertUnknown(store, .destination(of: behindB), serverKey, "Added after the takeover")
        let reloaded = try HostTrustStore(fileURL: url)
        try await reloaded.adoptJumpRoutes(of: [direct, behindA, behindB])
        await assertUnknown(reloaded, .destination(of: behindB), serverKey, "The file remembers the takeover happened")
        try await reloaded.validate(endpoint: .destination(of: behindA), publicKey: serverKey)
    }

    func testAStoreThatStartsEmptyTakesNothingOver() async throws {
        let store = try HostTrustStore(fileURL: trustFile())
        let (serverKey, server) = try newKey()
        try await store.trustUnknown(endpoint: HostEndpoint(host: "10.0.0.5", port: 22), key: server)
        let behindA = connection("Behind A", through: bastionA)
        try await store.adoptJumpRoutes(of: [behindA])
        await assertUnknown(store, .destination(of: behindA), serverKey, "Nothing here predates routes")
    }

    /// An earlier build must still read the file: the version is unchanged, a server reached
    /// directly is written as before, and what is new is in fields that build ignores.
    func testAnEarlierBuildStillReadsWhatIsWritten() async throws {
        let url = trustFile()
        let store = try HostTrustStore(fileURL: url)
        let (_, server) = try newKey(), (_, behind) = try newKey()
        try await store.trustUnknown(endpoint: HostEndpoint(host: "files.example", port: 22), key: server)
        try await store.trustUnknown(endpoint: HostEndpoint(host: "10.0.0.5", port: 22, via: bastionA), key: behind)
        let earlier = try JSONDecoder().decode(EarlierDocument.self, from: Data(contentsOf: url))
        XCTAssertEqual(earlier.version, 1)
        XCTAssertEqual(Set(earlier.records.map(\.endpoint.host)), ["files.example", "10.0.0.5"])
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let records = try XCTUnwrap(written["records"] as? [[String: Any]])
        let direct = try XCTUnwrap(records.first { ($0["endpoint"] as? [String: Any])?["host"] as? String == "files.example" })
        XCTAssertEqual(Set(try XCTUnwrap(direct["endpoint"] as? [String: Any]).keys), ["host", "port"])
    }
}
