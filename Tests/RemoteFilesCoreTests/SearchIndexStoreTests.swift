import XCTest
import Foundation
@testable import RemoteFilesCore

final class SearchIndexStoreTests: XCTestCase {
    private var directory: URL!
    private let profile = ConnectionProfile(name: "Search", host: "example.invalid", username: "reader", identityID: UUID())

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchIndexTests-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func document(_ path: String, text: String = "needle", page: Int? = nil) -> SearchIndexDocument {
        .init(entry: .init(name: RemotePath.name(of: path), path: path, kind: .file, size: UInt64(text.utf8.count),
                          modifiedAt: Date(timeIntervalSince1970: 100)), segments: [.init(text: text, page: page)])
    }
    private func snapshot(_ documents: [SearchIndexDocument], hidden: Bool = false, partial: Bool = false) -> SearchIndexSnapshot {
        .init(createdAt: Date(timeIntervalSince1970: 123), documents: documents, includeHidden: hidden,
              extraction: .init(includePDF: true, includeOCR: true), isPartial: partial)
    }
    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }

    func testReloadPreservesTextPagesMetadataAndPartialCoverage() async throws {
        let store = SearchIndexStore(directory: directory)
        let original = snapshot([document("/r/report.pdf", text: "Saved searchable text", page: 3)], partial: true)
        try await store.save(original, profile: profile, root: "/r")
        let reloaded = try await SearchIndexStore(directory: directory).load(profile: profile, root: "/r")
        let saved = try XCTUnwrap(reloaded)
        XCTAssertEqual(saved.createdAt, original.createdAt)
        XCTAssertEqual(saved.documents.map(\.entry), original.documents.map(\.entry))
        XCTAssertEqual(saved.documents.first?.segments, original.documents.first?.segments)
        XCTAssertTrue(saved.extraction.includePDF); XCTAssertTrue(saved.extraction.includeOCR)
        XCTAssertTrue(saved.isPartial); XCTAssertFalse(saved.includeHidden)
        let file = try XCTUnwrap(files().first)
        XCTAssertEqual(file.deletingPathExtension().lastPathComponent.count, 64)
        XCTAssertFalse(file.lastPathComponent.contains("report"))
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        #if os(iOS)
        let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            // Simulator has no device data-protection layer and may omit this attribute.
            XCTAssertTrue(protection.map { $0 == .complete } ?? true)
        } else {
            XCTAssertEqual(protection, .complete)
        }
        #endif
    }

    func testExactProfileAndRootIsolation() async throws {
        let store = SearchIndexStore(directory: directory)
        try await store.save(snapshot([document("/r/a.txt")]), profile: profile, root: "/r")
        let otherRoot = try await store.load(profile: profile, root: "/r/child")
        XCTAssertNil(otherRoot)
        var variants: [ConnectionProfile] = []
        var other = profile; other.id = UUID(); variants.append(other)
        other = profile; other.host = "different.invalid"; variants.append(other)
        other = profile; other.port = 2222; variants.append(other)
        other = profile; other.username = "another"; variants.append(other)
        other = profile; other.identityID = UUID(); variants.append(other)
        other = profile; other.startingDirectory = "/different"; variants.append(other)
        other = profile; other.jumpHost = .init(host: "jump.invalid", port: 22, username: "hop", identityID: UUID()); variants.append(other)
        for candidate in variants {
            let loaded = try await store.load(profile: candidate, root: "/r")
            XCTAssertNil(loaded)
        }
        let existing = try await store.load(profile: profile, root: "/r")
        XCTAssertNotNil(existing)
    }

    func testRebuildReplacesRemovedDocumentsAndRemovalIsScoped() async throws {
        let store = SearchIndexStore(directory: directory)
        try await store.save(snapshot([document("/r/old.txt"), document("/r/keep.txt")]), profile: profile, root: "/r")
        try await store.save(snapshot([document("/r/keep.txt", text: "changed")]), profile: profile, root: "/r")
        try await store.save(snapshot([document("/s/other.txt")]), profile: profile, root: "/s")
        let updated = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(updated?.documents.map(\.entry.path), ["/r/keep.txt"])
        XCTAssertEqual(updated?.documents.first?.segments.first?.text, "changed")
        XCTAssertEqual(try files().count, 2)
        try await store.remove(profile: profile, root: "/r")
        let removed = try await store.load(profile: profile, root: "/r")
        XCTAssertNil(removed)
        let retained = try await store.load(profile: profile, root: "/s")
        XCTAssertNotNil(retained)
        var another = profile; another.id = UUID()
        try await store.save(snapshot([document("/r/other.txt")]), profile: another, root: "/r")
        try await store.remove(connectionID: profile.id)
        let forgotten = try await store.load(profile: profile, root: "/s")
        XCTAssertNil(forgotten)
        let unrelated = try await store.load(profile: another, root: "/r")
        XCTAssertNotNil(unrelated)
    }

    func testRejectsEscapesLinksHiddenAndDuplicatePathsWithoutReplacingPreviousCopy() async throws {
        let store = SearchIndexStore(directory: directory)
        try await store.save(snapshot([document("/r/valid.txt")]), profile: profile, root: "/r")
        let invalid = [
            snapshot([document("/outside/secret.txt")]), snapshot([document("/r/../secret.txt")]),
            snapshot([document("/r//secret.txt")]), snapshot([document("/r/.hidden/secret.txt")]),
            snapshot([document("/r/a.txt"), document("/r/a.txt")]),
            snapshot([.init(entry: .init(name: "alias.txt", path: "/r/alias.txt", kind: .symlink), segments: [])]),
            snapshot([.init(entry: .init(name: "different.txt", path: "/r/a.txt", kind: .file), segments: [])])
        ]
        for candidate in invalid {
            do { try await store.save(candidate, profile: profile, root: "/r"); XCTFail("Invalid snapshot accepted") }
            catch SearchIndexError.invalidSnapshot {} catch { XCTFail("Unexpected error: \(error)") }
        }
        let preserved = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(preserved?.documents.map(\.entry.path), ["/r/valid.txt"])
        try await store.save(snapshot([document("/r/.hidden/secret.txt")], hidden: true), profile: profile, root: "/r")
        let hidden = try await store.load(profile: profile, root: "/r")
        XCTAssertTrue(hidden?.includeHidden == true)
    }

    func testCorruptionUnknownVersionAndOversizedDataAreRejected() async throws {
        let store = SearchIndexStore(directory: directory)
        let valid = snapshot([document("/r/a.txt")])
        try await store.save(valid, profile: profile, root: "/r")
        let file = try XCTUnwrap(files().first)
        try Data("not json".utf8).write(to: file)
        do { _ = try await store.load(profile: profile, root: "/r"); XCTFail("Corruption accepted") }
        catch SearchIndexError.damaged {}
        try await store.save(valid, profile: profile, root: "/r")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["version"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        do { _ = try await store.load(profile: profile, root: "/r"); XCTFail("Unknown version accepted") }
        catch SearchIndexError.damaged {}
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(SearchIndexStore.maximumEncodedBytes + 1))
        try handle.close()
        do { _ = try await store.load(profile: profile, root: "/r"); XCTFail("Oversized file accepted") }
        catch SearchIndexError.damaged {}
    }

    func testDocumentAndTextBudgetsPreserveThePreviousIndex() async throws {
        let store = SearchIndexStore(directory: directory)
        try await store.save(snapshot([document("/r/valid.txt")]), profile: profile, root: "/r")
        let tooMany = snapshot((0...SearchIndexStore.maximumDocuments).map { document("/r/\($0).txt") })
        do { try await store.save(tooMany, profile: profile, root: "/r"); XCTFail("Document budget ignored") }
        catch SearchIndexError.tooLarge {}
        let tooMuch = snapshot([document("/r/large.txt", text: String(repeating: "x", count: SearchIndexStore.maximumTextBytes + 1))])
        do { try await store.save(tooMuch, profile: profile, root: "/r"); XCTFail("Text budget ignored") }
        catch SearchIndexError.tooLarge {}
        let previous = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(previous?.documents.map(\.entry.path), ["/r/valid.txt"])
    }

    func testOldestIndexIsEvictedAtTheGlobalCountLimit() async throws {
        let store = SearchIndexStore(directory: directory)
        for number in 0..<SearchIndexStore.maximumIndexes {
            try await store.save(snapshot([document("/r\(number)/file.txt")]), profile: profile, root: "/r\(number)")
        }
        // Make write order deterministic even on filesystems with coarse timestamp resolution.
        for file in try files() {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let root = try XCTUnwrap(json["root"] as? String)
            let number = try XCTUnwrap(Int(root.dropFirst(2)))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(number))], ofItemAtPath: file.path)
        }
        try await store.save(snapshot([document("/new/file.txt")]), profile: profile, root: "/new")
        XCTAssertEqual(try files().count, SearchIndexStore.maximumIndexes)
        let oldest = try await store.load(profile: profile, root: "/r0")
        XCTAssertNil(oldest)
        let second = try await store.load(profile: profile, root: "/r1")
        XCTAssertNotNil(second)
        let newest = try await store.load(profile: profile, root: "/new")
        XCTAssertNotNil(newest)
    }

    func testCancelledSaveDoesNotCreateAnIndex() async throws {
        let store = SearchIndexStore(directory: directory)
        let ready = expectation(description: "Task is cancelled before save")
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            ready.fulfill()
            try await store.save(self.snapshot([self.document("/r/a.txt")]), profile: self.profile, root: "/r")
        }
        task.cancel()
        await fulfillment(of: [ready], timeout: 2)
        do { try await task.value; XCTFail("Cancelled save succeeded") } catch is CancellationError {}
        let loaded = try await store.load(profile: profile, root: "/r")
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSharedStoreUsesStandardizedDirectoryIdentity() async throws {
        let first = await SearchIndexStore.shared(directory: directory)
        let second = await SearchIndexStore.shared(directory: directory.appendingPathComponent("child/..", isDirectory: true))
        XCTAssertTrue(first === second)
        try await first.save(snapshot([document("/r/a.txt")]), profile: profile, root: "/r")
        let third = await SearchIndexStore.shared(directory: URL(fileURLWithPath: directory.path))
        XCTAssertTrue(first === third)
    }

    func testSharedStoreKeepsOneOwnerAcrossSymlinkedParentsBeforeAndAfterCreation() async throws {
        let realParent = directory.appendingPathComponent("real", isDirectory: true)
        let aliasParent = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: realParent)
        let aliased = aliasParent.appendingPathComponent("missing/index", isDirectory: true)
        let canonical = realParent.appendingPathComponent("missing/index", isDirectory: true)
        let first = await SearchIndexStore.shared(directory: aliased)
        let second = await SearchIndexStore.shared(directory: canonical)
        XCTAssertTrue(first === second, "A missing index below an aliased parent still has one owner")
        try await first.save(snapshot([document("/r/a.txt")]), profile: profile, root: "/r")
        let reopened = await SearchIndexStore.shared(directory: URL(fileURLWithPath: aliased.path))
        XCTAssertTrue(first === reopened, "Creating the directory cannot change its owning actor")
        let generation = try await first.beginBuild(profile: profile, root: "/r")
        try await second.remove(profile: profile, root: "/r")
        do {
            try await first.save(snapshot([document("/r/stale.txt")]), profile: profile, root: "/r", generation: generation)
            XCTFail("Deletion through another path spelling must invalidate an in-flight build")
        } catch SearchIndexError.superseded {}
    }

    func testNewestBuildSupersedesOlderBuildAndConsumedTokenCannotSaveAgain() async throws {
        let store = SearchIndexStore(directory: directory)
        let older = try await store.beginBuild(profile: profile, root: "/r")
        let newer = try await store.beginBuild(profile: profile, root: "/r")
        let newest = snapshot([document("/r/new.txt")])
        try await store.save(newest, profile: profile, root: "/r", generation: newer)
        do {
            try await store.save(snapshot([document("/r/old.txt")]), profile: profile, root: "/r", generation: older)
            XCTFail("An older build replaced the newer index")
        } catch SearchIndexError.superseded {}
        do {
            try await store.save(newest, profile: profile, root: "/r", generation: newer)
            XCTFail("A consumed token saved a second time")
        } catch SearchIndexError.superseded {}
        let saved = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(saved?.documents.map(\.entry.path), ["/r/new.txt"])
    }

    func testDeletionInvalidatesPendingBuildBeforeAnyIndexExists() async throws {
        let store = SearchIndexStore(directory: directory)
        let generation = try await store.beginBuild(profile: profile, root: "/r")
        try await store.remove(profile: profile, root: "/r")
        do {
            try await store.save(snapshot([document("/r/a.txt")]), profile: profile, root: "/r", generation: generation)
            XCTFail("A deleted index was resurrected by a pending build")
        } catch SearchIndexError.superseded {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let replacement = try await store.beginBuild(profile: profile, root: "/r")
        try await store.save(snapshot([document("/r/new.txt")]), profile: profile, root: "/r", generation: replacement)
        let saved = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(saved?.documents.map(\.entry.path), ["/r/new.txt"])
    }

    func testConnectionRemovalInvalidatesAllPendingRootsButPreservesOtherConnections() async throws {
        let store = SearchIndexStore(directory: directory)
        let first = try await store.beginBuild(profile: profile, root: "/r")
        var edited = profile; edited.username = "changed"
        let second = try await store.beginBuild(profile: edited, root: "/s")
        var other = profile; other.id = UUID()
        let third = try await store.beginBuild(profile: other, root: "/r")
        try await store.remove(connectionID: profile.id)
        do {
            try await store.save(snapshot([document("/r/a.txt")]), profile: profile, root: "/r", generation: first)
            XCTFail("Removed connection's pending build saved")
        } catch SearchIndexError.superseded {}
        do {
            try await store.save(snapshot([document("/s/a.txt")]), profile: edited, root: "/s", generation: second)
            XCTFail("Removed connection's edited profile still saved")
        } catch SearchIndexError.superseded {}
        try await store.save(snapshot([document("/r/other.txt")]), profile: other, root: "/r", generation: third)
        let retained = try await store.load(profile: other, root: "/r")
        XCTAssertNotNil(retained)
    }
}
