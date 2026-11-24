import XCTest
import NIOSSH
import NIOCore
import NIOPosix
@testable import RemoteFilesCore

/// Uploads and copies between connections against the isolated OpenSSH fixture
/// (`scripts/test-openssh.sh swift test --filter SFTPUploadIntegrationTests`).
final class SFTPUploadIntegrationTests: XCTestCase {
    func testUploadWritesExactBytesUnderItsNameAndLeavesNoPartialCopy() async throws {
        let server = try await connected(name: "Upload exact bytes")
        let bytes = Self.pattern(3 * 1024 * 1024 + 4_321)
        let local = try stage(bytes, modified: Date(timeIntervalSince1970: 1_790_000_000))
        let id = UUID()
        let offsets = Offsets()
        let before = await server.service.metrics()
        let entry = try await server.service.uploadFile(profile: server.profile,
            request: .init(directory: server.folder, name: "Quarterly résumé.bin", conflict: .fail,
                           partialName: UploadRequest.partialName(for: id), limit: 64 * 1024 * 1024),
            source: LocalFileTransferSource(url: local), started: { await offsets.record($1) }, progress: { _ in })
        let after = await server.service.metrics()
        XCTAssertEqual(entry.name, "Quarterly résumé.bin")
        XCTAssertEqual(entry.path, server.folder + "/Quarterly résumé.bin")
        XCTAssertEqual(entry.size, UInt64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: entry.path)), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: server.folder), ["Quarterly résumé.bin"], "No partial copy is left")
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: entry.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, 1_790_000_000, accuracy: 1, "The source's modification time goes with it")
        XCTAssertEqual(after.bytesSent - before.bytesSent, bytes.count)
        let recorded = await offsets.values
        XCTAssertEqual(recorded, [0])
        // An empty file is a file too.
        let empty = try stage(Data(), modified: .now)
        let none = try await server.service.uploadFile(profile: server.profile,
            request: .init(directory: server.folder, name: "empty.txt", conflict: .fail, partialName: UploadRequest.partialName(for: UUID()), limit: 1024),
            source: LocalFileTransferSource(url: empty), started: { _, _ in }, progress: { _ in })
        XCTAssertEqual(none.size, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: none.path)), Data())
    }

    func testATakenNameIsRefusedBeforeSendingAndKeptBesideOrReplacedOnlyWhenAsked() async throws {
        let server = try await connected(name: "Upload conflicts")
        let existing = Data("already here\n".utf8), replacement = Self.pattern(200_000)
        try existing.write(to: URL(fileURLWithPath: server.folder + "/notes.txt"))
        try FileManager.default.createDirectory(atPath: server.folder + "/folder.txt", withIntermediateDirectories: false)
        let local = try stage(replacement, modified: .now)
        func upload(_ name: String, _ conflict: UploadConflictPolicy, id: UUID = UUID(), resume: TransferSourceVersion? = nil,
                    started: @escaping UploadStartHandler = { _, _ in }) async throws -> RemoteEntry {
            try await server.service.uploadFile(profile: server.profile,
                request: .init(directory: server.folder, name: name, conflict: conflict, partialName: UploadRequest.partialName(for: id),
                               resumeVersion: resume, limit: 1024 * 1024),
                source: LocalFileTransferSource(url: local), started: started, progress: { _ in })
        }
        let before = await server.service.metrics()
        do {
            _ = try await upload("notes.txt", .fail)
            XCTFail("A taken name must not be written over")
        } catch RemoteUploadError.destinationExists(let name) { XCTAssertEqual(name, "notes.txt") }
        let refused = await server.service.metrics()
        XCTAssertEqual(refused.bytesSent, before.bytesSent, "Refused before any file byte was sent")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.folder + "/notes.txt")), existing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: server.folder).sorted(), ["folder.txt", "notes.txt"])

        let beside = try await upload("notes.txt", .keepBoth)
        XCTAssertEqual(beside.name, "notes 2.txt")
        let third = try await upload("notes.txt", .keepBoth)
        XCTAssertEqual(third.name, "notes 3.txt")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.folder + "/notes.txt")), existing)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: beside.path)), replacement)

        let replaced = try await upload("notes.txt", .replace)
        XCTAssertEqual(replaced.name, "notes.txt")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.folder + "/notes.txt")), replacement)

        do {
            _ = try await upload("folder.txt", .replace)
            XCTFail("A file must not replace a folder")
        } catch RemoteUploadError.destinationIsFolder {}
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.folder + "/folder.txt", isDirectory: &isDirectory) && isDirectory.boolValue)

        // A link is replaced as a link, whatever it leads to: here the folder, which is left as it was.
        try FileManager.default.createSymbolicLink(atPath: server.folder + "/shortcut.txt", withDestinationPath: server.folder + "/folder.txt")
        let overLink = try await upload("shortcut.txt", .replace)
        XCTAssertEqual(overLink.name, "shortcut.txt")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: server.folder + "/shortcut.txt")[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.folder + "/shortcut.txt")), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: server.folder + "/folder.txt"), [])
        try FileManager.default.removeItem(atPath: server.folder + "/shortcut.txt")

        // A name taken while the bytes were on their way keeps them on the server, and the answer then
        // needs no second transfer.
        let id = UUID(), offsets = Offsets(), versions = Versions()
        let racing = Task {
            try await upload("late.txt", .fail, id: id, started: { version, offset in
                await versions.record(version); await offsets.record(offset)
                try? Data("someone else\n".utf8).write(to: URL(fileURLWithPath: server.folder + "/late.txt"))
            })
        }
        do {
            _ = try await racing.value
            XCTFail("The name was taken before the upload finished")
        } catch RemoteUploadError.destinationExists {}
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.folder + "/late.txt")), Data("someone else\n".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.folder + "/" + UploadRequest.partialName(for: id)))
        let version = await versions.values.last
        let sentBefore = await server.service.metrics().bytesSent
        let settled = try await upload("late.txt", .keepBoth, id: id, resume: version, started: { await offsets.record($1) })
        XCTAssertEqual(settled.name, "late 2.txt")
        let sentAfter = await server.service.metrics().bytesSent
        XCTAssertEqual(sentAfter, sentBefore, "The complete partial copy is named without sending it again")
        let last = await offsets.values.last
        XCTAssertEqual(last, UInt64(replacement.count))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: settled.path)), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.folder + "/" + UploadRequest.partialName(for: id)))
    }

    /// A queue's uploads share one SFTP channel. A file that is refused closes only its own handle, so the
    /// files after it still go over the same channel.
    func testAQueueOfUploadsSharesOneChannelAndARefusedFileLeavesItUsable() async throws {
        let server = try await connected(name: "Upload queue channel")
        try Data("taken".utf8).write(to: URL(fileURLWithPath: server.folder + "/b.bin"))
        let batch = SnapshotTransferBatch()
        func upload(_ name: String, _ bytes: Data) async throws -> RemoteEntry {
            try await server.service.uploadFile(profile: server.profile,
                request: .init(directory: server.folder, name: name, conflict: .fail, partialName: UploadRequest.partialName(for: UUID()), limit: 8 * 1024 * 1024),
                source: LocalFileTransferSource(url: try stage(bytes, modified: .now)), batch: batch, started: { _, _ in }, progress: { _ in })
        }
        let before = await server.service.metrics()
        let first = Self.pattern(1_500_000), third = Self.pattern(70_000)
        _ = try await upload("a.bin", first)
        do {
            _ = try await upload("b.bin", Self.pattern(10))
            XCTFail("A taken name must be refused")
        } catch RemoteUploadError.destinationExists {}
        _ = try await upload("c.bin", third)
        await server.service.endSnapshotBatch(batch)
        let after = await server.service.metrics()
        XCTAssertEqual(after.sftpChannels - before.sftpChannels, 1, "Three files, one channel")
        XCTAssertEqual(after.connections, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.folder + "/a.bin")), first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.folder + "/b.bin")), Data("taken".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.folder + "/c.bin")), third)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: server.folder).sorted(), ["a.bin", "b.bin", "c.bin"])
        // Once the batch has ended nothing more starts on it; browsing's own channel is unaffected.
        do {
            _ = try await upload("d.bin", third)
            XCTFail("An ended batch must not open another channel")
        } catch is CancellationError {}
        let listing = try await server.service.listDirectory(profile: server.profile, path: server.folder)
        XCTAssertEqual(listing.entries.count, 3)
    }

    /// Without Replace a file takes its name by a hard link, which the server refuses in one step if the
    /// name exists, whatever its RENAME would do with a taken name. A server or file system without hard
    /// links falls back to looking and renaming, and still refuses a name that is taken.
    func testAFileTakesAFreeNameByHardLinkAndWithoutOneByLookingAndRenaming() async throws {
        let server = try await connected(name: "Upload publish")
        let bytes = Self.pattern(40_000)
        let local = try stage(bytes, modified: .now)
        for links in [true, false] {
            await server.service.setPublishesWithHardLinks(links)
            let before = await server.service.metrics().linkedPublishes
            let folder = server.folder + "/" + (links ? "linked" : "renamed")
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            func send(_ name: String, _ conflict: UploadConflictPolicy) async throws -> RemoteEntry {
                try await server.service.uploadFile(profile: server.profile,
                    request: .init(directory: folder, name: name, conflict: conflict, partialName: UploadRequest.partialName(for: UUID()), limit: 1024 * 1024),
                    source: LocalFileTransferSource(url: local), started: { _, _ in }, progress: { _ in })
            }
            let first = try await send("a.bin", .fail)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.path)), bytes)
            let beside = try await send("a.bin", .keepBoth)
            XCTAssertEqual(beside.name, "a 2.bin")
            // A link that leads nowhere still has the name: stat says nothing is there, and the name is still refused.
            try FileManager.default.createSymbolicLink(atPath: folder + "/dangling.bin", withDestinationPath: folder + "/nowhere")
            let kept = try await send("dangling.bin", .keepBoth)
            XCTAssertEqual(kept.name, "dangling 2.bin")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder + "/dangling.bin"), folder + "/nowhere")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder).sorted(), ["a 2.bin", "a.bin", "dangling 2.bin", "dangling.bin"],
                           "Each file has one name: its partial name went when it was linked")
            let after = await server.service.metrics().linkedPublishes
            XCTAssertEqual(after - before, links ? 3 : 0)
        }
    }

    #if os(macOS)
    /// A copy within one server reads over the channel it writes on, so a server that allows one channel can
    /// still copy a file from one of its folders to another, and continue one that was interrupted.
    func testACopyWithinAServerThatAllowsOneChannelNeedsNoSecond() async throws {
        let original = try UploadFixture()
        let reservation = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(reservation.localAddress?.port)
        try await reservation.close()
        let logURL = URL(fileURLWithPath: original.directory + "/one-channel-copy-\(port).log")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        server.arguments = ["-D", "-e", "-f", original.directory + "/sshd_config", "-p", String(port),
                            "-o", "MaxSessions=1", "-o", "PidFile=" + original.directory + "/one-channel-copy-\(port).pid"]
        server.environment = ProcessInfo.processInfo.environment.merging(["TZ": ""]) { _, new in new }
        server.standardOutput = log; server.standardError = log
        try server.run()
        addTeardownBlock {
            // Not `waitUntilExit()`, which can poll forever on the main thread after sshd has gone.
            if server.isRunning { server.terminate() }
            let deadline = ContinuousClock.now + .seconds(60)
            while server.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            if server.isRunning { kill(server.processIdentifier, SIGKILL) }
            try? log.close()
        }
        try await waitUntil("the one-channel server listens") {
            guard let probe = try? await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.seconds(1)).connect(host: "127.0.0.1", port: port).get() else { return false }
            try? await probe.close()
            return true
        }
        let fixture = try UploadFixture(port: port), stores = try UploadStores(fixture: fixture)
        let key = try await stores.identity.generate(name: "One-channel copy")
        try fixture.authorize(key.publicKey)
        try await stores.trustFixtureHost()
        let profile = try await stores.profile(identity: key)
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
        let folder = try uploadFolder(in: fixture)
        let bytes = Self.pattern(5 * 1024 * 1024 + 3)
        let path = fixture.files + "/one-channel-source-" + UUID().uuidString + ".bin"
        try bytes.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000)], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        // Browsing holds the only channel when the copy starts, as it does in the app.
        _ = try await service.listDirectory(profile: profile, path: folder)
        var source = RemoteFileTransferSource(service: service, profile: profile, path: path, canonicalRoot: fixture.files)
        source.sameConnection = true
        let offsets = Offsets()
        func copy(_ name: String, id: UUID, resume: TransferSourceVersion? = nil, batch: SnapshotTransferBatch) async throws -> RemoteEntry {
            try await service.uploadFile(profile: profile,
                request: .init(directory: folder, name: name, conflict: .fail, partialName: UploadRequest.partialName(for: id),
                               resumeVersion: resume, limit: 64 * 1024 * 1024),
                source: source, batch: batch, started: { await offsets.record($1) }, progress: { _ in })
        }
        let batch = SnapshotTransferBatch()
        let fresh = try await copy("fresh.bin", id: UUID(), batch: batch)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fresh.path)), bytes)
        // An interrupted copy continues: the comparison with the source is read over the same channel too.
        let id = UUID(), prefix = bytes.prefix(1024 * 1024 + 9)
        try prefix.write(to: URL(fileURLWithPath: folder + "/" + UploadRequest.partialName(for: id)))
        let version = try await service.transferVersion(profile: profile, path: path, canonicalRoot: fixture.files)
        let resumed = try await copy("resumed.bin", id: id, resume: version, batch: batch)
        await service.endSnapshotBatch(batch)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: resumed.path)), bytes)
        let starts = await offsets.values
        XCTAssertEqual(starts, [0, UInt64(prefix.count)])
        // Browsing has its channel back afterwards, and everything went over one connection.
        let listing = try await service.listDirectory(profile: profile, path: folder)
        XCTAssertEqual(listing.entries.map(\.name).sorted(), ["fresh.bin", "resumed.bin"])
        let metrics = await service.metrics()
        XCTAssertEqual(metrics.connections, 1)
        XCTAssertGreaterThanOrEqual(metrics.foregroundLoans, 1, "The copy borrowed browsing's channel: the server allows one")
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains("no more sessions"), "The fixture must actually refuse a second channel")
    }
    #endif

    /// A server without `posix-rename@openssh.com` replaces by moving the old file aside first, so that no
    /// failure part-way leaves the folder without either file.
    func testReplacingWithoutPosixRenameMovesTheOldFileAsideAndLeavesNothingBehind() async throws {
        let server = try await connected(name: "Upload replace fallback")
        await server.service.setReplacesWithPosixRename(false)
        let existing = Data("old contents\n".utf8), replacement = Self.pattern(150_000)
        let path = server.folder + "/report.bin"
        try existing.write(to: URL(fileURLWithPath: path))
        let local = try stage(replacement, modified: .now)
        func replace(id: UUID) async throws -> RemoteEntry {
            try await server.service.uploadFile(profile: server.profile,
                request: .init(directory: server.folder, name: "report.bin", conflict: .replace, partialName: UploadRequest.partialName(for: id), limit: 1024 * 1024),
                source: LocalFileTransferSource(url: local), started: { _, _ in }, progress: { _ in })
        }
        let entry = try await replace(id: UUID())
        XCTAssertEqual(entry.name, "report.bin")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: server.folder), ["report.bin"], "Neither the partial copy nor the old file is left")

        // An earlier attempt that moved the old file aside and stopped there: the new file takes the free
        // name, and what was moved aside is removed.
        let id = UUID()
        let aside = server.folder + "/" + String(UploadRequest.partialName(for: id).dropLast(".part".count)) + ".old"
        try FileManager.default.moveItem(atPath: path, toPath: aside)
        _ = try await replace(id: id)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: server.folder), ["report.bin"])

        // The same, and someone has since put another file under the name. The file already moved aside is
        // not moved over: the newcomer goes aside under a name of its own, and both go once the new file is named.
        let again = UUID()
        let stem = server.folder + "/" + String(UploadRequest.partialName(for: again).dropLast(".part".count))
        try FileManager.default.removeItem(atPath: path)
        try existing.write(to: URL(fileURLWithPath: stem + ".old"))
        try Data("put there since".utf8).write(to: URL(fileURLWithPath: path))
        _ = try await replace(id: again)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: server.folder), ["report.bin"])

        // Giving up on a Replace that stopped after moving the old file aside puts that file back.
        let abandoned = UUID()
        let moved = server.folder + "/" + String(UploadRequest.partialName(for: abandoned).dropLast(".part".count)) + ".old"
        try FileManager.default.removeItem(atPath: path)
        try existing.write(to: URL(fileURLWithPath: moved))
        try Data("partial".utf8).write(to: URL(fileURLWithPath: server.folder + "/" + UploadRequest.partialName(for: abandoned)))
        try await server.service.removePartialUpload(profile: server.profile, directory: server.folder,
                                                     partialName: UploadRequest.partialName(for: abandoned), restoring: "report.bin")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), existing, "The old file has its name again")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: server.folder), ["report.bin"])
        // With its name taken meanwhile, it stays where it was moved to: nothing is written over to put it back.
        try FileManager.default.moveItem(atPath: path, toPath: moved)
        try Data("put there since".utf8).write(to: URL(fileURLWithPath: path))
        try await server.service.removePartialUpload(profile: server.profile, directory: server.folder,
                                                     partialName: UploadRequest.partialName(for: abandoned), restoring: "report.bin")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("put there since".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: moved)), existing)
        try FileManager.default.removeItem(atPath: moved)

        // A link is replaced itself; what it led to is untouched.
        let target = server.folder + "/target.bin"
        try existing.write(to: URL(fileURLWithPath: target))
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        _ = try await replace(id: UUID())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), existing)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replacement)
    }

    func testAnInterruptedUploadContinuesOnlyWhileItsSourceAndPartialCopyStillMatch() async throws {
        let server = try await connected(name: "Upload resume")
        let bytes = Self.pattern(24 * 1024 * 1024)
        let local = try stage(bytes, modified: Date(timeIntervalSince1970: 1_790_000_000))
        let id = UUID(), partial = server.folder + "/" + UploadRequest.partialName(for: id)
        let offsets = Offsets(), versions = Versions()
        func upload(resuming version: TransferSourceVersion?, source: (any TransferSource)? = nil) async throws -> RemoteEntry {
            try await server.service.uploadFile(profile: server.profile,
                request: .init(directory: server.folder, name: "archive.bin", conflict: .fail, partialName: UploadRequest.partialName(for: id),
                               resumeVersion: version, limit: 64 * 1024 * 1024),
                source: source ?? LocalFileTransferSource(url: local),
                started: { await versions.record($0); await offsets.record($1) }, progress: { _ in })
        }
        // The source's bytes stop arriving a third of the way through, and the transfer is then cancelled.
        let stalled = StallingSource(base: LocalFileTransferSource(url: local), limit: 8 * 1024 * 1024)
        let first = Task { try await upload(resuming: nil, source: stalled) }
        try await waitUntil("some of the file is on the server") {
            ((try? FileManager.default.attributesOfItem(atPath: partial)[.size] as? NSNumber)?.intValue ?? 0) >= 4 * 1024 * 1024
        }
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("A cancelled upload must not finish")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.folder + "/archive.bin"), "Nothing appears under the real name until it is whole")
        let kept = try Data(contentsOf: URL(fileURLWithPath: partial))
        XCTAssertGreaterThan(kept.count, 0)
        XCTAssertLessThan(kept.count, bytes.count)
        XCTAssertEqual(kept, bytes.prefix(kept.count), "The partial copy is a prefix of the source")
        let recordedVersions = await versions.values
        let version = try XCTUnwrap(recordedVersions.first)

        // Unchanged source and matching partial copy: only the missing bytes are sent.
        let before = await server.service.metrics()
        let entry = try await upload(resuming: version)
        let after = await server.service.metrics()
        var last = await offsets.values.last
        XCTAssertEqual(last, UInt64(kept.count))
        XCTAssertEqual(after.bytesSent - before.bytesSent, bytes.count - kept.count)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: entry.path)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial))

        // Altered final bytes are not trusted: the copy starts again.
        try FileManager.default.removeItem(atPath: entry.path)
        var altered = kept; altered[altered.count - 1] ^= 0xFF
        try altered.write(to: URL(fileURLWithPath: partial))
        _ = try await upload(resuming: version)
        last = await offsets.values.last
        XCTAssertEqual(last, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: entry.path)), bytes)

        // A partial copy longer than the source is never continued.
        try FileManager.default.removeItem(atPath: entry.path)
        try (bytes + Data([1])).write(to: URL(fileURLWithPath: partial))
        _ = try await upload(resuming: version)
        last = await offsets.values.last
        XCTAssertEqual(last, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: entry.path)), bytes)

        // A source with another modification time is another file, even at the same size.
        try FileManager.default.removeItem(atPath: entry.path)
        let prefix = bytes.prefix(6 * 1024 * 1024 + 17)
        try prefix.write(to: URL(fileURLWithPath: partial))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_003_600)], ofItemAtPath: local.path)
        _ = try await upload(resuming: version)
        last = await offsets.values.last
        XCTAssertEqual(last, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.folder + "/archive.bin")), bytes)

        // A link planted under the partial name is removed, never written through.
        try FileManager.default.removeItem(atPath: entry.path)
        let victim = server.folder + "/victim.bin"
        try prefix.write(to: URL(fileURLWithPath: victim))
        try FileManager.default.createSymbolicLink(atPath: partial, withDestinationPath: victim)
        let current = try LocalFileTransferSource.version(of: local)
        _ = try await upload(resuming: current)
        last = await offsets.values.last
        XCTAssertEqual(last, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: victim)), prefix, "The link's target is untouched")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.folder + "/archive.bin")), bytes)
    }

    /// A source that supplies bytes slowly leaves the write window unfilled, and its confirmations must still
    /// count: the transfer shows progress and is not taken for one that has stopped.
    func testASlowSourceKeepsItsTransferAliveAndReportsWhatTheServerConfirmed() async throws {
        let server = try await connected(name: "Upload slow source")
        await server.service.setTransferTimings(idle: .milliseconds(1_200), closeGrace: .seconds(1))
        await server.service.setProgressInterval(.zero)
        let bytes = Self.pattern(12 * 16 * 1024)
        let local = try stage(bytes, modified: .now)
        // Twelve chunks, far fewer than the window, over about twice the idle limit.
        let slow = PacedSource(base: LocalFileTransferSource(url: local), chunk: 16 * 1024, pause: .milliseconds(200))
        let reports = Offsets()
        let entry = try await server.service.uploadFile(profile: server.profile,
            request: .init(directory: server.folder, name: "trickle.bin", conflict: .fail, partialName: UploadRequest.partialName(for: UUID()), limit: 1024 * 1024),
            source: slow, started: { _, _ in }, progress: { await reports.record($0.receivedBytes) })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: entry.path)), bytes)
        let seen = await reports.values
        XCTAssertGreaterThan(Set(seen).count, 4, "Progress follows the confirmations as they arrive: \(seen)")
        XCTAssertEqual(seen, seen.sorted())
    }

    /// A copy's source is read on a channel of its own, with its own deadline. A destination slower than the
    /// source leaves reads already answered waiting to be taken on; that wait is the destination's, and the
    /// source must not be taken for one that has stopped.
    func testACopyToASlowDestinationDoesNotTimeOutItsSource() async throws {
        let server = try await connected(name: "Copy slow destination")
        await server.service.setTransferTimings(idle: .seconds(2), closeGrace: .seconds(1))
        let bytes = Self.pattern(30 * 64 * 1024)
        let path = server.fixture + "/files/slow-destination-" + UUID().uuidString + ".bin"
        try bytes.write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let root = server.fixture + "/files"
        let version = try await server.service.transferVersion(profile: server.profile, path: path, canonicalRoot: root)
        let taken = Collected()
        // Every read is answered at once; taking the bytes on lasts more than twice the idle limit.
        try await server.service.streamFile(profile: server.profile, path: path, canonicalRoot: root, from: 0, expecting: version) { chunk in
            try await Task.sleep(for: .milliseconds(150))
            await taken.append(chunk)
        }
        let received = await taken.data
        XCTAssertEqual(received, bytes)
    }

    /// When the source does give up with the destination still taking a chunk on, the destination is stopped
    /// with it and says only that it was stopped. The copy must end as timed out, which keeps its bytes for
    /// Retry, and not as cancelled, which removes them. A copy that is cancelled still ends as cancelled.
    func testACopyWhoseSourceGivesUpIsTimedOutAndNotCancelled() async throws {
        let server = try await connected(name: "Copy source gives up")
        let path = server.fixture + "/files/source-gives-up-" + UUID().uuidString + ".bin"
        try Self.pattern(4 * 64 * 1024).write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let root = server.fixture + "/files"
        let version = try await server.service.transferVersion(profile: server.profile, path: path, canonicalRoot: root)
        // A destination that holds its first chunk until it is stopped.
        let copy: @Sendable (Collected) async throws -> Void = { held in
            try await server.service.streamFile(profile: server.profile, path: path, canonicalRoot: root, from: 0, expecting: version) { chunk in
                await held.append(chunk)
                try await Task.sleep(for: .seconds(300))
            }
        }

        await server.service.setTransferTimings(idle: .seconds(3), closeGrace: .seconds(1))
        let heldAtTheLimit = Collected()
        do {
            try await copy(heldAtTheLimit)
            XCTFail("The copy finished")
        } catch {
            if case RemoteFileError.timedOut = error {} else { XCTFail("A source that gave up reported \(error)") }
        }
        let reached = await heldAtTheLimit.data
        XCTAssertFalse(reached.isEmpty, "The destination was holding a chunk when the source gave up")

        await server.service.setTransferTimings(idle: .seconds(60), closeGrace: .seconds(1))
        let heldWhenCancelled = Collected()
        let cancelled = Task { try await copy(heldWhenCancelled) }
        try await waitUntil("the destination holds a chunk") { await !heldWhenCancelled.data.isEmpty }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("The copy finished")
        } catch {
            XCTAssertTrue(error is CancellationError, "A cancelled copy reported \(error)")
        }
    }

    /// Disconnect closes a connection without cancelling what is using it. A transfer on it must end with an
    /// error, as one whose network has gone does: one left waiting would hold the queue's only slot for good.
    func testATransferWhoseConnectionIsClosedUnderItFailsAndDoesNotWait() async throws {
        let server = try await connected(name: "Upload closed under it")
        await server.service.setProgressInterval(.zero)
        let local = try stage(Self.pattern(96 * 16 * 1024), modified: .now)
        let big = server.fixture + "/files/closed-under-it-" + UUID().uuidString + ".bin"
        XCTAssertTrue(FileManager.default.createFile(atPath: big, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: big))
        try handle.truncate(atOffset: 1024 * 1024 * 1024); try handle.close()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: big) }
        var copied = RemoteFileTransferSource(service: server.service, profile: server.profile, path: big, canonicalRoot: server.fixture + "/files")
        copied.sameConnection = true
        let sources: [(String, any TransferSource, Bool, Int)] = [
            ("a slow upload", PacedSource(base: LocalFileTransferSource(url: local), chunk: 16 * 1024, pause: .milliseconds(50)), false, 64 * 1024),
            ("a slow upload on a queue's channel", PacedSource(base: LocalFileTransferSource(url: local), chunk: 16 * 1024, pause: .milliseconds(50)), true, 64 * 1024),
            ("a copy within the server", copied, true, 8 * 1024 * 1024),
        ]
        for (what, source, batched, enough) in sources {
            let id = UUID(), partial = server.folder + "/" + UploadRequest.partialName(for: id)
            let request = UploadRequest(directory: server.folder, name: "closed-\(id).bin", conflict: .fail, partialName: UploadRequest.partialName(for: id),
                                        limit: 2 * 1024 * 1024 * 1024)
            let batch = SnapshotTransferBatch()
            let transfer = Task {
                if batched {
                    return try await server.service.uploadFile(profile: server.profile, request: request, source: source, batch: batch,
                                                               started: { _, _ in }, progress: { _ in })
                }
                return try await server.service.uploadFile(profile: server.profile, request: request, source: source, started: { _, _ in }, progress: { _ in })
            }
            try await waitUntil("part of \(what) is on the server") {
                ((try? FileManager.default.attributesOfItem(atPath: partial)[.size] as? NSNumber)?.intValue ?? 0) >= enough
            }
            await server.service.disconnect()
            // Only the watchdog cancels it, so a cancellation means it was still waiting. Nothing here waits
            // for the network: the bound is for a loaded machine.
            let watchdog = Task { try await Task.sleep(for: .seconds(60)); transfer.cancel() }
            do {
                _ = try await transfer.value
                XCTFail("\(what) finished over a closed connection")
            } catch {
                XCTAssertFalse(transfer.isCancelled, "\(what) was still waiting a minute after its connection closed")
                if case RemoteFileError.connectionEnded = error {} else { XCTFail("\(what): \(error)") }
            }
            watchdog.cancel()
            await server.service.endSnapshotBatch(batch)
        }
    }

    private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting until " + what)
    }

    func testAFolderThatLeadsElsewhereIsRefusedAndOnlyItsOwnPartialNamesAreRemoved() async throws {
        let server = try await connected(name: "Upload boundary")
        let local = try stage(Self.pattern(10_000), modified: .now)
        let alias = server.fixture + "/upload-alias-" + UUID().uuidString
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: server.folder)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: alias) }
        func upload(to directory: String, name: String = "report.bin") async throws {
            _ = try await server.service.uploadFile(profile: server.profile,
                request: .init(directory: directory, name: name, conflict: .fail, partialName: UploadRequest.partialName(for: UUID()), limit: 1024 * 1024),
                source: LocalFileTransferSource(url: local), started: { _, _ in }, progress: { _ in })
        }
        do {
            try await upload(to: alias)
            XCTFail("A folder that is a link must be refused")
        } catch RemoteUploadError.destinationMoved {}
        do {
            try await upload(to: server.folder + "/missing")
            XCTFail("A missing folder must be refused")
        } catch RemoteFileError.notFound {}
        for name in ["../escape.bin", "a/b.bin", "..", "", ".rf-upload-anything", "bad\u{0}name"] {
            do {
                try await upload(to: server.folder, name: name)
                XCTFail("\(name.debugDescription) is not one name")
            } catch RemoteUploadError.invalidName {}
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: server.folder), [])

        // A folder moved away while the bytes were on their way, with a link left in its place, still takes
        // them: the file was opened in it. It is asked about again once they are there, and nothing is named.
        let moving = server.fixture + "/files/upload-moving-" + UUID().uuidString, moved = moving + "-moved"
        try FileManager.default.createDirectory(atPath: moving, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: moving); try? FileManager.default.removeItem(atPath: moved) }
        do {
            _ = try await server.service.uploadFile(profile: server.profile,
                request: .init(directory: moving, name: "report.bin", conflict: .fail, partialName: UploadRequest.partialName(for: UUID()), limit: 1024 * 1024),
                source: LocalFileTransferSource(url: local), started: { _, _ in
                    // Long enough for an answer asked for before this to have come back.
                    try? await Task.sleep(for: .milliseconds(300))
                    try? FileManager.default.moveItem(atPath: moving, toPath: moved)
                    try? FileManager.default.createSymbolicLink(atPath: moving, withDestinationPath: moved)
                }, progress: { _ in })
            XCTFail("A folder that was moved during the transfer must be refused")
        } catch RemoteUploadError.destinationMoved {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved + "/report.bin"))

        // Removal takes only a name this app makes, in a folder that is still where it was.
        let id = UUID(), partial = server.folder + "/" + UploadRequest.partialName(for: id)
        try Data("partial".utf8).write(to: URL(fileURLWithPath: partial))
        try Data("keep".utf8).write(to: URL(fileURLWithPath: server.folder + "/keep.txt"))
        do {
            try await server.service.removePartialUpload(profile: server.profile, directory: server.folder, partialName: "keep.txt", restoring: nil)
            XCTFail("Only a partial name may be removed")
        } catch RemoteUploadError.invalidName {}
        do {
            try await server.service.removePartialUpload(profile: server.profile, directory: alias, partialName: UploadRequest.partialName(for: id), restoring: nil)
            XCTFail("A redirected folder must be refused")
        } catch RemoteUploadError.destinationMoved {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial))
        try await server.service.removePartialUpload(profile: server.profile, directory: server.folder, partialName: UploadRequest.partialName(for: id), restoring: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial))
        // Already gone is not an error, and browsing's channel is still usable afterwards.
        try await server.service.removePartialUpload(profile: server.profile, directory: server.folder, partialName: UploadRequest.partialName(for: id), restoring: nil)
        let listing = try await server.service.listDirectory(profile: server.profile, path: server.folder)
        XCTAssertEqual(listing.entries.map(\.name), ["keep.txt"])
    }

    func testACopyBetweenTwoConnectionsStreamsExactBytesWhileBothStayConnected() async throws {
        let fixture = try UploadFixture()
        let stores = try UploadStores(fixture: fixture)
        let key = try await stores.identity.generate(name: "Copy between connections")
        try fixture.authorize(key.publicKey)
        try await stores.trustFixtureHost()
        // Two connections to the fixture stand for two servers: each has its own session.
        let source = ConnectionProfile(name: "Source", host: "127.0.0.1", port: fixture.port, username: fixture.username,
                                       identityID: key.id, startingDirectory: fixture.files)
        let destination = ConnectionProfile(name: "Destination", host: "127.0.0.1", port: fixture.port, username: fixture.username,
                                            identityID: key.id, startingDirectory: fixture.files)
        var library = AppMetadata()
        library.identities = [key]; library.connections = [source, destination]
        try await stores.metadata.save(library)
        let pool = MultiHostFileService { stores.service() }
        addTeardownBlock { await pool.disconnect() }
        let folder = try uploadFolder(in: fixture)
        let bytes = Self.pattern(9 * 1024 * 1024 + 99)
        let original = fixture.files + "/copy-source-" + UUID().uuidString + ".bin"
        try bytes.write(to: URL(fileURLWithPath: original))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000)], ofItemAtPath: original)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: original) }

        let listed = try await pool.listDirectory(profile: source, path: fixture.files)
        let entry = try XCTUnwrap(listed.entries.first { $0.path == original }).selectedForTransfer
        let remote = RemoteFileTransferSource(service: pool, profile: source, path: entry.path, canonicalRoot: entry.selectionRoot)
        let copied = try await pool.uploadFile(profile: destination,
            request: .init(directory: folder, name: "copied.bin", conflict: .fail, partialName: UploadRequest.partialName(for: UUID()), limit: 64 * 1024 * 1024),
            source: remote, started: { _, _ in }, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copied.path)), bytes)
        XCTAssertEqual(pool.connectionIDs, [source.id, destination.id])
        let sourceMetrics = await pool.host(source).metrics(), destinationMetrics = await pool.host(destination).metrics()
        XCTAssertEqual(sourceMetrics.connections, 1)
        XCTAssertEqual(destinationMetrics.connections, 1)
        XCTAssertEqual(destinationMetrics.bytesSent, bytes.count)
        XCTAssertGreaterThanOrEqual(sourceMetrics.bytesReceived, bytes.count)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: copied.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, 1_790_000_000, accuracy: 1)

        // A partial copy of an unchanged source continues: its end is compared with the source's bytes.
        let id = UUID(), prefix = bytes.prefix(2 * 1024 * 1024 + 5)
        try prefix.write(to: URL(fileURLWithPath: folder + "/" + UploadRequest.partialName(for: id)))
        let version = try await remote.describe()
        let offsets = Offsets()
        let resumed = try await pool.uploadFile(profile: destination,
            request: .init(directory: folder, name: "resumed.bin", conflict: .fail, partialName: UploadRequest.partialName(for: id),
                           resumeVersion: version, limit: 64 * 1024 * 1024),
            source: remote, started: { await offsets.record($1) }, progress: { _ in })
        let resumedAt = await offsets.values
        XCTAssertEqual(resumedAt, [UInt64(prefix.count)])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: resumed.path)), bytes)

        // A source rewritten while it was read, at the same length, is not the file that was described.
        let rewritten = RewrittenSource(base: remote, path: original, bytes: Data(bytes.reversed()))
        do {
            _ = try await pool.uploadFile(profile: destination,
                request: .init(directory: folder, name: "rewritten.bin", conflict: .fail, partialName: UploadRequest.partialName(for: UUID()), limit: 64 * 1024 * 1024),
                source: rewritten, started: { _, _ in }, progress: { _ in })
            XCTFail("A copy of a source that changed under it must not be named")
        } catch RemoteUploadError.sourceChanged {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/rewritten.bin"))
        try bytes.write(to: URL(fileURLWithPath: original))

        // The source is bounded by the folder it was chosen from: a link out of it is refused.
        let outside = RemoteFileTransferSource(service: pool, profile: source, path: fixture.files + "/outside-export.txt", canonicalRoot: fixture.files)
        do {
            _ = try await pool.uploadFile(profile: destination,
                request: .init(directory: folder, name: "outside.txt", conflict: .fail, partialName: UploadRequest.partialName(for: UUID()), limit: 1024),
                source: outside, started: { _, _ in }, progress: { _ in })
            XCTFail("A source that leads outside its folder must be refused")
        } catch RemoteDocumentLinkError.outsideConnection {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/outside.txt"))

        // Closing one connection leaves the other open.
        await pool.closeSession(of: source.id)
        XCTAssertEqual(pool.connectionIDs, [destination.id])
        let still = try await pool.listDirectoryInBackground(profile: destination, path: folder)
        XCTAssertNotNil(still, "The destination's session is still there to list over")
        let closed = try await pool.listDirectoryInBackground(profile: source, path: fixture.files)
        XCTAssertNil(closed, "A closed connection is never reopened for background work")
    }

    // MARK: Fixture

    private struct Connected {
        let service: SFTPRemoteFileService
        let profile: ConnectionProfile
        let fixture: String
        /// An empty folder of this test's own, by its canonical path.
        let folder: String
    }

    private func connected(name: String) async throws -> Connected {
        let fixture = try UploadFixture()
        let stores = try UploadStores(fixture: fixture)
        let key = try await stores.identity.generate(name: name)
        try fixture.authorize(key.publicKey)
        try await stores.trustFixtureHost()
        let profile = try await stores.profile(identity: key)
        let service = stores.service()
        addTeardownBlock { await service.disconnect() }
        let folder = try uploadFolder(in: fixture)
        return Connected(service: service, profile: profile, fixture: fixture.directory, folder: folder)
    }

    private func uploadFolder(in fixture: UploadFixture) throws -> String {
        let folder = fixture.files + "/uploads-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        return folder
    }

    private func stage(_ bytes: Data, modified: Date) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-source-" + UUID().uuidString)
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Bytes that differ at every offset a chunk boundary could fall on.
    static func pattern(_ count: Int) -> Data {
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { buffer in
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in 0..<buffer.count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                buffer[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return bytes
    }
}

private actor Offsets {
    private(set) var values: [UInt64] = []
    func record(_ offset: UInt64) { values.append(offset) }
}

private actor Versions {
    private(set) var values: [TransferSourceVersion] = []
    func record(_ version: TransferSourceVersion) { values.append(version) }
}

/// Hands on the first `limit` bytes of a file and then nothing more until it is cancelled, as a source
/// whose bytes have stopped arriving.
private struct StallingSource: TransferSource {
    let base: LocalFileTransferSource
    let limit: Int
    private struct Stalled: Error {}
    func describe() async throws -> TransferSourceVersion { try await base.describe() }
    func read(at offset: UInt64, count: Int) async throws -> Data { try await base.read(at: offset, count: count) }
    func send(from offset: UInt64, expecting version: TransferSourceVersion,
              to sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        let handed = ByteCount()
        do {
            try await base.send(from: offset, expecting: version) { chunk in
                guard handed.add(chunk.count) <= limit else { throw Stalled() }
                try await sink(chunk)
            }
        } catch is Stalled {
            try await Task.sleep(for: .seconds(3_600))
        }
    }
}

/// Hands on a file a small chunk at a time with a pause before each, as a slow server would.
/// A remote source whose file is written over, at the same length and with a later date, once its first
/// bytes have been handed on.
private struct RewrittenSource: TransferSource {
    let base: RemoteFileTransferSource
    let path: String
    let bytes: Data
    func describe() async throws -> TransferSourceVersion { try await base.describe() }
    func read(at offset: UInt64, count: Int) async throws -> Data { try await base.read(at: offset, count: count) }
    func send(from offset: UInt64, expecting version: TransferSourceVersion,
              to sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        let once = OnceFlag()
        try await base.send(from: offset, expecting: version) { chunk in
            if once.take() {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try handle.write(contentsOf: bytes); try handle.close()
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_600)], ofItemAtPath: path)
            }
            try await sink(chunk)
        }
    }
}
private actor Collected {
    private(set) var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
}
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool { lock.withLock { if taken { return false }; taken = true; return true } }
}

private struct PacedSource: TransferSource {
    let base: LocalFileTransferSource
    let chunk: Int
    let pause: Duration
    func describe() async throws -> TransferSourceVersion { try await base.describe() }
    func read(at offset: UInt64, count: Int) async throws -> Data { try await base.read(at: offset, count: count) }
    func send(from offset: UInt64, expecting version: TransferSourceVersion,
              to sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        try await base.send(from: offset, expecting: version) { bytes in
            for start in stride(from: 0, to: bytes.count, by: chunk) {
                try await Task.sleep(for: pause)
                try await sink(bytes.subdata(in: bytes.startIndex + start..<bytes.startIndex + min(bytes.count, start + chunk)))
            }
        }
    }
}

private final class ByteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ count: Int) -> Int { lock.withLock { total += count; return total } }
}

private struct UploadFixture {
    let directory: String
    let port: Int
    let username: String
    var files: String { directory + "/files" }
    init(port overridePort: Int? = nil) throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["REMOTEFILES_SFTP_FIXTURE"],
              let port = Int(env["REMOTEFILES_SFTP_PORT"] ?? ""),
              let username = env["REMOTEFILES_SFTP_USER"] else {
            throw XCTSkip("Run scripts/test-openssh.sh to create an isolated real OpenSSH fixture.")
        }
        self.directory = directory; self.port = overridePort ?? port; self.username = username
    }
    func authorize(_ publicKey: String) throws {
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: directory + "/authorized_keys"))
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data((publicKey + "\n").utf8))
    }
}

private struct UploadStores {
    let fixture: UploadFixture
    let identity: IdentityStore
    let metadata: MetadataStore
    let trust: HostTrustStore
    init(fixture: UploadFixture) throws {
        self.fixture = fixture
        let folder = URL(fileURLWithPath: fixture.directory).appendingPathComponent(UUID().uuidString)
        identity = IdentityStore(secretStore: UploadSecrets())
        metadata = try MetadataStore(fileURL: folder.appendingPathComponent("metadata.json"))
        trust = try HostTrustStore(fileURL: folder.appendingPathComponent("trust.json"))
    }
    func profile(identity: IdentityMetadata) async throws -> ConnectionProfile {
        let profile = ConnectionProfile(name: "OpenSSH fixture", host: "127.0.0.1", port: fixture.port,
                                        username: fixture.username, identityID: identity.id, startingDirectory: fixture.files)
        var value = AppMetadata()
        value.identities = [identity]; value.connections = [profile]
        try await metadata.save(value)
        return profile
    }
    func trustFixtureHost() async throws {
        let publicKey = try String(contentsOfFile: fixture.directory + "/host.pub", encoding: .utf8)
        let details = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: publicKey))
        try await trust.trustUnknown(endpoint: HostEndpoint(host: "127.0.0.1", port: fixture.port), key: details)
    }
    /// The benchmark's 60-second budget, as the other functional fixture tests use.
    func service() -> SFTPRemoteFileService {
        SFTPRemoteFileService(identityStore: identity, trustStore: trust, metadataStore: metadata, timeoutSeconds: 60)
    }
}

private final class UploadSecrets: IdentitySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func save(_ value: Data, reference: String) throws { lock.withLock { data[reference] = value } }
    func load(reference: String) throws -> Data {
        try lock.withLock {
            guard let value = data[reference] else { throw IdentityError.missingSecret }
            return value
        }
    }
    func delete(reference: String) throws { lock.withLock { _ = data.removeValue(forKey: reference) } }
}
