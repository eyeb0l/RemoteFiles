import XCTest
import Foundation
import Crypto
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Citadel
import Logging

/// Pipelined READDIR against an in-process SSH server whose SFTP subsystem is a scripted fake.
/// The fake can hold requests to measure how many are in flight, answer them out of order,
/// rewind or fail after EOF, and fail or misanswer a chosen READDIR.
final class SFTPDirectoryReadTests: XCTestCase {
    private let thousand = (0..<1000).map { "entry-\($0).txt" }

    func testPipelinedListingIsCompleteAndOrderedAndBounded() async throws {
        let recorder = try await list(FakeDirectory(entries: thousand, batch: 7, holdMilliseconds: 20), concurrentReads: 8) { names in
            XCTAssertEqual(names, self.thousand)
        }
        XCTAssertEqual(recorder.maxHeld, 8, "The first window fills the bound and never exceeds it")
        XCTAssertLessThanOrEqual(recorder.readdirs, 143 + 8, "143 batches, one EOF, and at most seven surplus reads")
        XCTAssertEqual(recorder.requests.filter { $0 == "close" }.count, 1)
        XCTAssertEqual(recorder.requests.last, "close")
    }

    func testSmallFolderNeedsOneReadRoundTripAndClosesBehindSurplusReads() async throws {
        let recorder = try await list(FakeDirectory(entries: [".", "..", "a"], holdMilliseconds: 20), concurrentReads: 8) { names in
            XCTAssertEqual(names, [".", "..", "a"])
        }
        // The first batch refills the window once before its successor's EOF is read.
        XCTAssertEqual(recorder.requests, ["opendir"] + Array(repeating: "readdir", count: 9) + ["close"])
        XCTAssertEqual(recorder.rounds, 2, "One round answers the window; the refill and CLOSE share the next")
    }

    func testSequentialReadingKeepsOneRequestInFlight() async throws {
        let recorder = try await list(FakeDirectory(entries: thousand, batch: 100, holdMilliseconds: 5), concurrentReads: 1) { names in
            XCTAssertEqual(names, self.thousand)
        }
        XCTAssertEqual(recorder.maxHeld, 1)
        XCTAssertEqual(recorder.readdirs, 11, "Ten batches and one EOF, as upstream")
        XCTAssertEqual(recorder.requests, ["opendir"] + Array(repeating: "readdir", count: 11) + ["close"])
    }

    func testServerAnsweringEachRequestInTurnListsSmallAndEmptyFolders() async throws {
        for entries in [[], [".", "..", "a"], thousand] {
            let recorder = try await list(FakeDirectory(entries: entries), concurrentReads: 8) { names in
                XCTAssertEqual(names, entries)
            }
            XCTAssertEqual(recorder.requests.last, "close")
            XCTAssertEqual(recorder.requests.filter { $0 == "close" }.count, 1)
        }
    }

    func testOutOfOrderServerLosesAndRepeatsNothing() async throws {
        // Held requests are answered last-first, so later READDIRs take earlier batches and some
        // names arrive after an earlier request's EOF unless the batch count divides evenly by the window.
        for batch in [7, 11, 13] {
            try await list(FakeDirectory(entries: thousand, batch: batch, holdMilliseconds: 20, reverseHeld: true), concurrentReads: 8) { names in
                XCTAssertEqual(names.count, 1000)
                XCTAssertEqual(Set(names), Set(self.thousand))
            }
        }
    }

    func testRewindingOrRejectingReadsAfterEOFDoesNotRepeatOrFail() async throws {
        for entries in [[".", "..", "a"], thousand] {
            try await list(FakeDirectory(entries: entries, batch: 100, rewindAfterEOF: true), concurrentReads: 8) { names in
                XCTAssertEqual(names, entries)
            }
            try await list(FakeDirectory(entries: entries, batch: 100, statusAfterEOF: 4), concurrentReads: 8) { names in
                XCTAssertEqual(names, entries)
            }
        }
    }

    func testReadErrorFailsListingAfterDrainingAndClosing() async throws {
        let recorder = try await list(FakeDirectory(entries: thousand, batch: 50, holdMilliseconds: 10, failingReaddir: 4, failureCode: 3),
                                      concurrentReads: 8) { _ in XCTFail("A failed READDIR must fail the listing") } failure: { error in
            XCTAssertEqual((error as? SFTPMessage.Status)?.errorCode, .permissionDenied)
        }
        XCTAssertEqual(recorder.requests.filter { $0 == "close" }.count, 1)
        XCTAssertEqual(recorder.requests.last, "close", "Every READDIR is answered before CLOSE is sent")
        XCTAssertLessThan(recorder.readdirs, 20, "No new READDIR is issued after the failure")
    }

    func testUnexpectedReadResponseFailsListingAndCloses() async throws {
        let recorder = try await list(FakeDirectory(entries: thousand, batch: 100, invalidReaddir: 2), concurrentReads: 8) { _ in
            XCTFail("A HANDLE answer to READDIR must fail the listing")
        } failure: { error in
            guard case SFTPError.invalidResponse = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(recorder.requests.last, "close")
    }

    func testCloseFailureFailsListing() async throws {
        try await list(FakeDirectory(entries: ["a"], closeStatus: 4), concurrentReads: 8) { _ in
            XCTFail("A failed CLOSE must fail the listing so the caller retires the channel")
        } failure: { error in
            XCTAssertEqual((error as? SFTPMessage.Status)?.errorCode, .failure)
        }
    }

    func testCancellationStopsReadingAndCloses() async throws {
        let server = try await FakeSFTPServer.start(FakeDirectory(entries: thousand, batch: 10, holdMilliseconds: 500))
        let client = try await server.connect()
        let sftp = try await client.openSFTP(logger: FakeSFTPServer.quietLogger)
        let task = Task { try await sftp.listDirectory(atPath: "/fake", resolvingPath: false, concurrentReads: 8) }
        // Cancel while the first window is held, before any batch has been answered.
        while server.recorder.readdirs < 8 { try await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled listing must not succeed") }
        catch { XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)") }
        XCTAssertEqual(server.recorder.requests.last, "close")
        XCTAssertEqual(server.recorder.readdirs, 8, "Only the first window was issued")
        try await client.close()
        try await server.stop()
    }

    @discardableResult
    private func list(_ directory: FakeDirectory, concurrentReads: Int,
                      success: ([String]) -> Void,
                      failure: ((Error) -> Void)? = nil) async throws -> FakeRecorder {
        let server = try await FakeSFTPServer.start(directory)
        let client = try await server.connect()
        let sftp = try await client.openSFTP(logger: FakeSFTPServer.quietLogger)
        do {
            let groups = try await sftp.listDirectory(atPath: "/fake", resolvingPath: false, concurrentReads: concurrentReads)
            success(groups.flatMap(\.components).map(\.filename))
            if failure != nil { XCTFail("Listing unexpectedly succeeded") }
        } catch {
            guard let failure else { throw error }
            failure(error)
        }
        try await client.close()
        try await server.stop()
        return server.recorder
    }
}

private struct FakeDirectory: Sendable {
    var entries: [String]
    var batch = 100
    /// Zero answers each READDIR on arrival; otherwise requests are held this long, then answered together.
    var holdMilliseconds: Int64 = 0
    var reverseHeld = false
    var rewindAfterEOF = false
    var statusAfterEOF: UInt32?
    var failingReaddir: Int?
    var failureCode: UInt32 = 4
    var invalidReaddir: Int?
    var closeStatus: UInt32 = 0
}

private final class FakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _maxHeld = 0
    private var _rounds = 0
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    /// Most READDIRs held together, i.e. in flight from the client at once.
    var maxHeld: Int { lock.lock(); defer { lock.unlock() }; return _maxHeld }
    /// Times held requests were answered: each is one client round trip.
    var rounds: Int { lock.lock(); defer { lock.unlock() }; return _rounds }
    var readdirs: Int { requests.filter { $0 == "readdir" }.count }
    func record(_ request: String) { lock.lock(); _requests.append(request); lock.unlock() }
    func held(_ count: Int) { lock.lock(); _maxHeld = max(_maxHeld, count); lock.unlock() }
    func answeredRound() { lock.lock(); _rounds += 1; lock.unlock() }
}

private final class FakeSFTPServer: @unchecked Sendable {
    let recorder: FakeRecorder
    private let listener: Channel

    private init(listener: Channel, recorder: FakeRecorder) { self.listener = listener; self.recorder = recorder }

    static func start(_ directory: FakeDirectory) async throws -> FakeSFTPServer {
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let recorder = FakeRecorder()
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: AcceptAnyPassword())),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, _ in
                            child.eventLoop.makeCompletedFuture {
                                try child.pipeline.syncOperations.addHandler(FakeSFTPHandler(directory: directory, recorder: recorder))
                            }
                        }))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        return FakeSFTPServer(listener: listener, recorder: recorder)
    }

    var port: Int { listener.localAddress?.port ?? 0 }

    /// The fake's socket closing at the end of a test is expected, not worth an error line.
    static var quietLogger: Logger {
        var logger = Logger(label: "RemoteFilesTests.FakeSFTP")
        logger.logLevel = .critical
        return logger
    }

    func connect() async throws -> SSHClient {
        try await SSHClient.connect(host: "127.0.0.1", port: port,
                                    authenticationMethod: .passwordBased(username: "fake", password: "fake"),
                                    hostKeyValidator: .acceptAnything(), reconnect: .never)
    }

    func stop() async throws { try await listener.close() }
}

private final class AcceptAnyPassword: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        responsePromise.succeed(.success)
    }
}

/// Minimal SFTP v3 server for one directory, driven entirely on its channel's event loop.
private final class FakeSFTPHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private enum Held { case readdir(UInt32, Int), close(UInt32) }

    private let directory: FakeDirectory
    private let recorder: FakeRecorder
    private var buffer = ByteBuffer()
    private var cursor = 0
    private var exhausted = false
    private var closed = false
    private var readdirCount = 0
    private var held: [Held] = []

    init(directory: FakeDirectory, recorder: FakeRecorder) {
        self.directory = directory
        self.recorder = recorder
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let request = event as? SSHChannelRequestEvent.SubsystemRequest, request.wantReply {
            context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(var bytes) = message.data else { return }
        buffer.writeBuffer(&bytes)
        while let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self),
              buffer.readableBytes >= 4 + Int(length) {
            buffer.moveReaderIndex(forwardBy: 4)
            var packet = buffer.readSlice(length: Int(length))!
            handle(&packet, context: context)
        }
    }

    private func handle(_ packet: inout ByteBuffer, context: ChannelHandlerContext) {
        guard let type: UInt8 = packet.readInteger() else { return }
        if type == 1 { // INIT -> VERSION 3
            return send(context) { $0.writeInteger(UInt8(2)); $0.writeInteger(UInt32(3)) }
        }
        guard let id: UInt32 = packet.readInteger() else { return }
        switch type {
        case 11: // OPENDIR
            recorder.record("opendir")
            send(context) { $0.writeInteger(UInt8(102)); $0.writeInteger(id); $0.writeFakeString("dir") }
        case 12: // READDIR
            recorder.record("readdir")
            readdirCount += 1
            hold(.readdir(id, readdirCount - 1), context: context)
        case 4: // CLOSE
            recorder.record("close")
            hold(.close(id), context: context)
        default:
            status(id, code: 8, context: context)
        }
    }

    private func hold(_ request: Held, context: ChannelHandlerContext) {
        guard directory.holdMilliseconds > 0 else { return answer(request, context: context) }
        held.append(request)
        if case .readdir = request { recorder.held(held.filter { if case .readdir = $0 { true } else { false } }.count) }
        guard held.count == 1 else { return }
        context.eventLoop.assumeIsolated().scheduleTask(in: .milliseconds(directory.holdMilliseconds)) {
            let batch = self.directory.reverseHeld ? self.held.reversed() : self.held
            self.held = []
            self.recorder.answeredRound()
            for request in batch { self.answer(request, context: context) }
        }
    }

    private func answer(_ request: Held, context: ChannelHandlerContext) {
        switch request {
        case .close(let id):
            closed = true
            status(id, code: directory.closeStatus, context: context)
        case .readdir(let id, let index):
            if closed || index == directory.failingReaddir {
                return status(id, code: closed ? 4 : directory.failureCode, context: context)
            }
            if index == directory.invalidReaddir {
                return send(context) { $0.writeInteger(UInt8(102)); $0.writeInteger(id); $0.writeFakeString("dir") }
            }
            if cursor >= directory.entries.count {
                if exhausted, directory.rewindAfterEOF {
                    cursor = 0
                } else {
                    let code = exhausted ? (directory.statusAfterEOF ?? 1) : 1
                    exhausted = true
                    return status(id, code: code, context: context)
                }
            }
            let names = directory.entries[cursor..<min(cursor + directory.batch, directory.entries.count)]
            cursor += names.count
            send(context) { buffer in
                buffer.writeInteger(UInt8(104)); buffer.writeInteger(id); buffer.writeInteger(UInt32(names.count))
                for name in names {
                    buffer.writeFakeString(name); buffer.writeFakeString(name); buffer.writeInteger(UInt32(0))
                }
            }
        }
    }

    private func status(_ id: UInt32, code: UInt32, context: ChannelHandlerContext) {
        send(context) {
            $0.writeInteger(UInt8(101)); $0.writeInteger(id); $0.writeInteger(code)
            $0.writeFakeString(""); $0.writeFakeString("")
        }
    }

    private func send(_ context: ChannelHandlerContext, _ body: (inout ByteBuffer) -> Void) {
        var payload = context.channel.allocator.buffer(capacity: 64)
        body(&payload)
        var packet = context.channel.allocator.buffer(capacity: payload.readableBytes + 4)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeBuffer(&payload)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(packet))), promise: nil)
    }
}

private extension ByteBuffer {
    mutating func writeFakeString(_ value: String) {
        writeInteger(UInt32(value.utf8.count))
        writeString(value)
    }
}
