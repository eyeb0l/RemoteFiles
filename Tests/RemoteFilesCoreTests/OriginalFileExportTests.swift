import Foundation
import XCTest
@testable import RemoteFilesCore

final class OriginalFileExportTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Export fixture", host: "fixture.invalid", username: "reader", identityID: UUID())
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("original-export-tests-" + UUID().uuidString, isDirectory: true)
    }
    private func entry(_ name: String = "Notes — 東京.txt", kind: RemoteEntry.Kind = .file,
                       size: UInt64? = nil) -> RemoteEntry {
        .init(name: name, path: "/fixture/" + name, kind: kind, size: size)
    }
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for export state", file: file, line: line)
    }
    private func prepareAfterDrain(_ exporter: RemoteOriginalExporter, entry: RemoteEntry) async throws -> PreparedOriginalFile {
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            do { return try await exporter.prepare(profile: profile, entry: entry, allowedRoot: ".") }
            catch OriginalFileExportError.alreadyPreparing {
                guard ContinuousClock.now < deadline else { throw OriginalFileExportError.alreadyPreparing }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
    private func children(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    func testExactTextAndBinaryBytesUseOriginalNameAndExtension() async throws {
        let cases: [(String, Data)] = [
            ("Notes — 東京.txt", Data(" \tCafé 東京 ✨\r\nsecond line  \r\n\t".utf8)),
            ("Archive.zip", Data([0, 255, 13, 10, 0, 128, 1, 254]))
        ]
        for (name, bytes) in cases {
            let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let service = OriginalExportTransportMock(bytes: bytes, canonicalName: "different-name.bin")
            let exporter = RemoteOriginalExporter(service: service, directory: dir)
            let selected = entry(name, kind: .symlink)
            let result = try await exporter.prepare(profile: profile, entry: selected, allowedRoot: ".")
            XCTAssertEqual(result.filename, name)
            XCTAssertEqual(result.url.lastPathComponent, name)
            XCTAssertEqual(try Data(contentsOf: result.url), bytes, "Export must not decode text or downsample media")
            let requests = await service.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.path, selected.path)
            XCTAssertEqual(requests.first?.root, ".", "The transport must canonicalize the configured root")
            XCTAssertEqual(requests.first?.limit, RemoteOriginalExporter.maximumFileBytes)
            await exporter.release(result.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: result.url.path))
            XCTAssertTrue(children(dir).isEmpty)
        }
    }

    func testCanonicalReaderEntryRetainsTappedAliasFilenameForExport() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("original alias bytes\r\n".utf8)
        let exporter = RemoteOriginalExporter(service: OriginalExportTransportMock(bytes: bytes), directory: dir)
        let canonical = RemoteEntry(name: "canonical.txt", path: "/fixture/canonical.txt", kind: .file,
                                    exportFilename: "Selected — 東京.txt")
        let result = try await exporter.prepare(profile: profile, entry: canonical, allowedRoot: "/fixture")
        XCTAssertEqual(result.filename, "Selected — 東京.txt")
        XCTAssertEqual(result.url.lastPathComponent, "Selected — 東京.txt")
        XCTAssertEqual(try Data(contentsOf: result.url), bytes)
        await exporter.release(result.id)
    }

    func testEmptyFileWithoutSizeMetadataIsExported() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = OriginalExportTransportMock(bytes: Data())
        let exporter = RemoteOriginalExporter(service: service, directory: dir, fileLimit: 8)
        let result = try await exporter.prepare(profile: profile, entry: entry("Empty.bin"), allowedRoot: "/fixture")
        XCTAssertEqual(try Data(contentsOf: result.url), Data())
        await exporter.release(result.id)
        XCTAssertTrue(children(dir).isEmpty)
    }

    func testOversizedAdvertisedMetadataStartsNoDownload() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = OriginalExportTransportMock(bytes: Data([1]))
        let exporter = RemoteOriginalExporter(service: service, directory: dir, fileLimit: 8)
        do {
            _ = try await exporter.prepare(profile: profile, entry: entry(size: 9), allowedRoot: "/fixture")
            XCTFail("Oversized metadata must reject export")
        } catch OriginalFileExportError.tooLarge(let limit) { XCTAssertEqual(limit, 8) }
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testReceiveGrowthFailureAndOversizedFinalResultAreCleaned() async throws {
        for enforceLimit in [true, false] {
            let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let service = OriginalExportTransportMock(bytes: Data(repeating: 0x41, count: 9), enforceLimit: enforceLimit)
            let exporter = RemoteOriginalExporter(service: service, directory: dir, fileLimit: 8)
            do {
                _ = try await exporter.prepare(profile: profile, entry: entry(size: 1), allowedRoot: "/fixture")
                XCTFail("A file that grows past the bound must reject export")
            } catch OriginalFileExportError.tooLarge(let limit) { XCTAssertEqual(limit, 8) }
            let requests = await service.requests
            XCTAssertEqual(requests.first?.limit, 8)
            XCTAssertTrue(children(dir).isEmpty, "Partial and complete oversized results must be removed")
        }
    }

    func testNonRegularEntriesAndEscapingSymlinkCannotBeExported() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = OriginalExportTransportMock(bytes: Data([1]), resultKind: .directory)
        let exporter = RemoteOriginalExporter(service: service, directory: dir)
        for kind in [RemoteEntry.Kind.directory, .other] {
            do { _ = try await exporter.prepare(profile: profile, entry: entry(kind: kind), allowedRoot: "/fixture"); XCTFail() }
            catch OriginalFileExportError.notRegularFile { }
        }
        var requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
        do { _ = try await exporter.prepare(profile: profile, entry: entry(kind: .symlink), allowedRoot: "/fixture"); XCTFail() }
        catch OriginalFileExportError.notRegularFile { }
        XCTAssertTrue(children(dir).isEmpty)
        requests = await service.requests
        XCTAssertEqual(requests.count, 1)

        let rejected = OriginalExportTransportMock(bytes: Data([1]), failure: RemoteFileError.unsupportedFile)
        let nonRegularExporter = RemoteOriginalExporter(service: rejected, directory: dir)
        do { _ = try await nonRegularExporter.prepare(profile: profile, entry: entry(kind: .symlink), allowedRoot: "/fixture"); XCTFail() }
        catch OriginalFileExportError.notRegularFile { }
        XCTAssertTrue(children(dir).isEmpty)

        let escaping = OriginalExportTransportMock(bytes: Data([1]), failure: RemoteResourceError.outsideDocument)
        let confinedExporter = RemoteOriginalExporter(service: escaping, directory: dir)
        do { _ = try await confinedExporter.prepare(profile: profile, entry: entry(kind: .symlink), allowedRoot: "/fixture"); XCTFail() }
        catch OriginalFileExportError.outsideRoot { }
        XCTAssertTrue(children(dir).isEmpty)
    }

    func testUnsafeLocalFilenamesDoNotStartTransfers() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = OriginalExportTransportMock(bytes: Data([1]))
        let exporter = RemoteOriginalExporter(service: service, directory: dir)
        for name in ["", ".", "..", "../secret", "folder/file", "folder\\file", "A\0B", "A\nB"] {
            do { _ = try await exporter.prepare(profile: profile, entry: entry(name), allowedRoot: "/fixture"); XCTFail(name) }
            catch OriginalFileExportError.invalidFilename { }
        }
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testCancellationRejectsLatePublicationAndPreventsOverlappingTransfers() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = OriginalExportTransportMock(bytes: Data("original".utf8), holdFirstTransfer: true)
        let exporter = RemoteOriginalExporter(service: service, directory: dir)
        let selected = entry()
        let work = Task { try await exporter.prepare(profile: profile, entry: selected, allowedRoot: "/fixture") }
        try await waitUntil { await service.requests.count == 1 }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancellation must leave promptly, even when transport ignores it") }
        catch is CancellationError { }
        XCTAssertTrue(children(dir).isEmpty)
        do { _ = try await exporter.prepare(profile: profile, entry: selected, allowedRoot: "/fixture"); XCTFail("Cancelled work still draining must prevent another download") }
        catch OriginalFileExportError.alreadyPreparing { }
        await service.resume()
        let next = try await prepareAfterDrain(exporter, entry: entry("Next.txt"))
        let maximumConcurrent = await service.maximumConcurrent
        XCTAssertEqual(maximumConcurrent, 1)
        XCTAssertEqual(children(dir).count, 1, "The stale transfer must leave no temporary result")
        XCTAssertEqual(try Data(contentsOf: next.url), Data("original".utf8))
        await exporter.release(next.id)
        XCTAssertTrue(children(dir).isEmpty)
    }

    func testDisconnectCancellationAndReleaseOnlyDeleteTheOwnedOutput() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = OriginalExportTransportMock(bytes: Data([1]))
        let exporter = RemoteOriginalExporter(service: service, directory: dir)
        let first = try await exporter.prepare(profile: profile, entry: entry(), allowedRoot: "/fixture")
        await exporter.cancelAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        let next = try await exporter.prepare(profile: profile, entry: entry("Next.txt"), allowedRoot: "/fixture")
        await exporter.release(first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.url.path), "A stale dismissal must not remove a later export")
        await exporter.cancelAll()
        XCTAssertTrue(children(dir).isEmpty)
    }

    func testCancelAndDrainWaitsForTheActiveTransportBeforeReuse() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = OriginalExportTransportMock(bytes: Data([1]), holdFirstTransfer: true)
        let exporter = RemoteOriginalExporter(service: service, directory: dir)
        let selected = entry()
        let work = Task { try await exporter.prepare(profile: profile, entry: selected, allowedRoot: "/fixture") }
        try await waitUntil { await service.requests.count == 1 }
        let drainage = Task { await exporter.cancelAndDrain() }
        do { _ = try await work.value; XCTFail() } catch is CancellationError { }
        do { _ = try await exporter.prepare(profile: profile, entry: selected, allowedRoot: "/fixture"); XCTFail() }
        catch OriginalFileExportError.alreadyPreparing { }
        await service.resume(); await drainage.value
        XCTAssertTrue(children(dir).isEmpty)
        let result = try await exporter.prepare(profile: profile, entry: selected, allowedRoot: "/fixture")
        await exporter.release(result.id)
        let maximumConcurrent = await service.maximumConcurrent
        XCTAssertEqual(maximumConcurrent, 1)
    }

    func testExpiryAndAbandonedCleanupBoundTemporaryLifetime() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let abandoned = dir.appendingPathComponent("export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data([1]).write(to: abandoned.appendingPathComponent("old.bin"))
        let unrelated = dir.appendingPathComponent("unrelated.txt")
        try Data([2]).write(to: unrelated)
        let service = OriginalExportTransportMock(bytes: Data([3]))
        let exporter = RemoteOriginalExporter(service: service, directory: dir, retentionSeconds: 0.05)
        let result = try await exporter.prepare(profile: profile, entry: entry(), allowedRoot: "/fixture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        try await waitUntil { !FileManager.default.fileExists(atPath: result.url.path) }
        let next = try await exporter.prepare(profile: profile, entry: entry(), allowedRoot: "/fixture")
        await exporter.release(next.id)
        XCTAssertEqual(children(dir).map(\.lastPathComponent), [unrelated.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([2]))
    }

    func testTimeoutCancelsPromptlyAndCleansLateResult() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = OriginalExportTransportMock(bytes: Data([1]), holdFirstTransfer: true)
        let exporter = RemoteOriginalExporter(service: service, directory: dir, timeoutSeconds: 0.05)
        do { _ = try await exporter.prepare(profile: profile, entry: entry(), allowedRoot: "/fixture"); XCTFail() }
        catch OriginalFileExportError.timedOut { }
        XCTAssertTrue(children(dir).isEmpty)
        await service.resume()
        let result = try await prepareAfterDrain(exporter, entry: entry())
        await exporter.release(result.id)
        XCTAssertTrue(children(dir).isEmpty)
    }
}

/// Deliberately ignores cancellation when held, to model a late transfer completion.
/// The production service enforces the byte bound while streaming; the second growth
/// mode also proves the exporter's final disk-size validation if a service violates it.
private actor OriginalExportTransportMock: RemoteFileService {
    struct Request: Sendable { let path: String; let root: String; let limit: Int }
    private let bytes: Data
    private let canonicalName: String
    private let resultKind: RemoteEntry.Kind
    private let failure: Error?
    private let enforceLimit: Bool
    private let holdFirstTransfer: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var concurrent = 0
    private(set) var maximumConcurrent = 0
    private(set) var requests: [Request] = []
    init(bytes: Data, canonicalName: String = "canonical.bin", resultKind: RemoteEntry.Kind = .file,
         failure: Error? = nil, enforceLimit: Bool = true, holdFirstTransfer: Bool = false) {
        self.bytes = bytes; self.canonicalName = canonicalName; self.resultKind = resultKind
        self.failure = failure; self.enforceLimit = enforceLimit; self.holdFirstTransfer = holdFirstTransfer
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        requests.append(.init(path: path, root: allowedRoot, limit: limit))
        concurrent += 1; maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        try Data(bytes.prefix(1)).write(to: destination)
        if holdFirstTransfer && requests.count == 1 {
            await withCheckedContinuation { held = $0 }
            // A stale transport recreating a removed output must still be cleaned.
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if let failure { throw failure }
        if enforceLimit && bytes.count > limit {
            try Data(bytes.prefix(limit)).write(to: destination)
            throw RemoteFileError.tooLarge(limit)
        }
        try bytes.write(to: destination)
        return .init(name: canonicalName, path: "/fixture/" + canonicalName, kind: resultKind)
    }
    func resume() { let continuation = held; held = nil; continuation?.resume() }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() {}
}
