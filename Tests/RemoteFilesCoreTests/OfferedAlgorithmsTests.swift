import XCTest
import Foundation
import NIOCore
import NIOPosix
@testable import RemoteFilesCore

/// What the app offers a server before any key is agreed, read from its first key-exchange packet.
///
/// Neither vendored SSH package implements strict key exchange, the countermeasure to the Terrapin
/// prefix-truncation attack. That is safe only while every offered cipher is AES-GCM, which the attack
/// does not reach. Offering ChaCha20-Poly1305, or a CBC or CTR cipher with an encrypt-then-MAC code,
/// would reopen it, so these lists are pinned: changing them has to be a decision, made here.
final class OfferedAlgorithmsTests: XCTestCase {
    private static let ciphers = ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com"]

    func testBrowsingOffersOnlyAESGCM() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offered-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let identities = IdentityStore(secretStore: OfferSecrets())
        let metadata = try MetadataStore(fileURL: folder.appendingPathComponent("metadata.json"))
        let trust = try HostTrustStore(fileURL: folder.appendingPathComponent("trust.json"))
        let identity = try await identities.generate(name: "Offer")
        let service = SFTPRemoteFileService(identityStore: identities, trustStore: trust, metadataStore: metadata, timeoutSeconds: 60)
        addTeardownBlock { await service.disconnect() }
        let offer = try await capture { port in
            let profile = ConnectionProfile(name: "Offer", host: "127.0.0.1", port: port, username: "offer",
                                            identityID: identity.id, startingDirectory: "/")
            var saved = AppMetadata(); saved.identities = [identity]; saved.connections = [profile]
            try await metadata.save(saved)
            _ = try? await service.listDirectory(profile: profile, path: "/")
        }
        assertPinned(offer)
    }

    func testPublicKeyInstallationOffersOnlyAESGCM() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offered-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let trust = try HostTrustStore(fileURL: folder.appendingPathComponent("trust.json"))
        let identity = try await IdentityStore(secretStore: OfferSecrets()).generate(name: "Offer")
        let installer = SSHPublicKeyInstaller(trust: trust, timeoutSeconds: 60)
        let offer = try await capture { port in
            let request = try PublicKeyInstallationRequest(host: "127.0.0.1", port: port, username: "offer", identity: identity)
            _ = try? await installer.install(request, password: "offer")
        }
        assertPinned(offer)
    }

    private func assertPinned(_ offer: KeyExchangeOffer, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(offer.ciphersToServer, Self.ciphers, file: file, line: line)
        XCTAssertEqual(offer.ciphersToClient, Self.ciphers, file: file, line: line)
        XCTAssertEqual(offer.keyExchange, [
            "ecdh-sha2-nistp384", "ecdh-sha2-nistp256", "ecdh-sha2-nistp521",
            "curve25519-sha256", "curve25519-sha256@libssh.org",
        ], "No strict key exchange is offered, which is why the ciphers are pinned", file: file, line: line)
        XCTAssertEqual(offer.hostKeys, ["ssh-ed25519", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp521"],
                       "No SHA-1 RSA host keys", file: file, line: line)
    }

    /// Runs `connect` against a listener that greets like an SSH server, reads the client's first
    /// packet and hangs up. The client's connection fails; what it offered first is the result.
    private func capture(_ connect: (Int) async throws -> Void) async throws -> KeyExchangeOffer {
        let captured = CapturedOffer()
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(OfferReader(captured)) }
            }.bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock { try? await listener.close() }
        try await connect(try XCTUnwrap(listener.localAddress?.port))
        // The client has failed by now, but its packet may still be on its way through the listener.
        let deadline = ContinuousClock.now + .seconds(60)
        while captured.offer == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return try XCTUnwrap(captured.offer, "The client sent no key-exchange packet")
    }
}

private struct KeyExchangeOffer: Equatable {
    var keyExchange: [String]
    var hostKeys: [String]
    var ciphersToServer: [String]
    var ciphersToClient: [String]

    /// The identification line, then one unencrypted packet: length, padding length, message 20
    /// (`SSH_MSG_KEXINIT`), a 16-byte cookie and ten comma-separated name lists (RFC 4253, section 7.1).
    init?(reading bytes: ByteBuffer) {
        var bytes = bytes
        guard let lineEnd = bytes.readableBytesView.firstIndex(of: 0x0A) else { return nil }
        bytes.moveReaderIndex(to: lineEnd + 1)
        guard let length = bytes.readInteger(as: UInt32.self), length < 1 << 20,
              var packet = bytes.readSlice(length: Int(length)),
              packet.readInteger(as: UInt8.self) != nil, packet.readInteger(as: UInt8.self) == 20,
              packet.readSlice(length: 16) != nil else { return nil }
        var lists: [[String]] = []
        for _ in 0..<10 {
            guard let count = packet.readInteger(as: UInt32.self), let names = packet.readString(length: Int(count)) else { return nil }
            lists.append(names.split(separator: ",").map(String.init))
        }
        keyExchange = lists[0]; hostKeys = lists[1]; ciphersToServer = lists[2]; ciphersToClient = lists[3]
    }
}

private final class CapturedOffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: KeyExchangeOffer?
    var offer: KeyExchangeOffer? { lock.lock(); defer { lock.unlock() }; return stored }
    func keep(_ offer: KeyExchangeOffer) { lock.lock(); if stored == nil { stored = offer }; lock.unlock() }
}

private final class OfferReader: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let captured: CapturedOffer
    private var received = ByteBuffer()

    init(_ captured: CapturedOffer) { self.captured = captured }

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(NIOAny(ByteBuffer(string: "SSH-2.0-OfferReader\r\n")), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        received.writeBuffer(&bytes)
        guard let offer = KeyExchangeOffer(reading: received) else { return }
        captured.keep(offer)
        context.close(promise: nil)
    }
}

private final class OfferSecrets: IdentitySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func save(_ value: Data, reference: String) throws { lock.lock(); defer { lock.unlock() }; data[reference] = value }
    func load(reference: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = data[reference] else { throw IdentityError.missingSecret }
        return value
    }
    func delete(reference: String) throws { lock.lock(); defer { lock.unlock() }; data.removeValue(forKey: reference) }
}
