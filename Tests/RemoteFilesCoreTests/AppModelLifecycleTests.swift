#if os(iOS)
import XCTest
import Foundation
import RemoteFilesCore
@testable import RemoteFilesUI

private actor BackgroundExportService: RemoteFileService {
    private var blocked: CheckedContinuation<Void, Error>?
    private(set) var destination: URL?
    private(set) var disconnects = 0
    private var bytes = Data("old server bytes".utf8)
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        .init(path: path, entries: [])
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .file)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { bytes }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String,
                      destination: URL, limit: Int) async throws -> RemoteEntry {
        self.destination = destination
        try bytes.write(to: destination)
        if disconnects == 0 {
            // Intentionally ignore task cancellation; only transport teardown retires it.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in blocked = continuation }
        }
        return .init(name: RemotePath.name(of: path), path: path, kind: .file, size: UInt64(bytes.count))
    }
    func disconnect() {
        disconnects += 1
        bytes = Data("changed server bytes\r\n東京  ".utf8)
        blocked?.resume(throwing: CancellationError()); blocked = nil
    }
    func waiting() -> Bool { blocked != nil }
}

@MainActor final class AppModelLifecycleTests: XCTestCase {
    func testProductionBackgroundCancelsAndDrainsExportClearsCacheAndNewExporterReadsChangedBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService()
        let model = try AppModel(directory: directory, fileService: service)
        let profile = ConnectionProfile(name: "Lifecycle", host: "fixture.invalid", username: "fixture",
                                        identityID: UUID(), startingDirectory: "/fixture")
        let entry = RemoteEntry(name: "original.txt", path: "/fixture/original.txt", kind: .file)
        model.cache(Data("stale preview".utf8), id: profile.id, path: entry.path)
        let oldExporter = model.originalExporter
        let pending = Task { try await oldExporter.prepare(profile: profile, entry: entry, allowedRoot: "/fixture") }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await service.waiting()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await service.waiting()
        guard waiting else { pending.cancel(); await service.disconnect(); XCTFail("Export never reached transport"); return }
        let destination = await service.destination
        let partial = try XCTUnwrap(destination)
        model.isForeground = false
        await model.background()
        do { _ = try await pending.value; XCTFail("Background export must be cancelled") }
        catch is CancellationError { }
        XCTAssertNil(model.cachedDocument(profile.id, path: entry.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "Partial export must be removed")
        let disconnects = await service.disconnects
        XCTAssertEqual(disconnects, 1)
        model.isForeground = true; model.sessionRevision += 1
        let newExporter = model.originalExporter
        XCTAssertFalse(oldExporter === newExporter, "Reconnect must use an exporter after the old transfer drained")
        let fresh = try await newExporter.prepare(profile: profile, entry: entry, allowedRoot: "/fixture")
        XCTAssertEqual(try Data(contentsOf: fresh.url), Data("changed server bytes\r\n東京  ".utf8))
        await newExporter.release(fresh.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.url.path))
    }
}
#endif
