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

    /// Writes what an older version would have saved, which `save` no longer writes.
    private func saveAsOlderVersion(_ text: String, path: String, store: SearchIndexStore) async throws {
        let stand = "STAND-IN-FOR-OLD-TEXT"
        try await store.save(snapshot([document(path, text: stand)], hidden: true), profile: profile, root: "/r")
        let file = try XCTUnwrap(files().first)
        let encoded = String(decoding: try JSONEncoder().encode(text), as: UTF8.self).dropFirst().dropLast()
        let json = String(decoding: try Data(contentsOf: file), as: UTF8.self).replacingOccurrences(of: stand, with: encoded)
        try Data(json.utf8).write(to: file)
        XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(encoded.prefix(80)))
    }

    func testAKeyAnOlderVersionSavedIsGoneFromDiskOnceTheIndexIsRead() async throws {
        let store = SearchIndexStore(directory: directory)
        let key = SyntheticKey.pem(), fragments = SyntheticKey.fragments(of: key)
        let text = "first\n\n" + key + "\nneedle\n"
        for (saved, path) in [(text, "/r/notes.txt"), (key, "/r/id_rsa")] {
            try await saveAsOlderVersion(saved, path: path, store: store)
            let loaded = try await store.load(profile: profile, root: "/r")
            let snapshot = try XCTUnwrap(loaded)
            let held = snapshot.documents.flatMap(\.segments).map(\.text).joined()
            for fragment in fragments { XCTAssertFalse(held.contains(fragment)) }
            let onDisk = String(decoding: try Data(contentsOf: try XCTUnwrap(files().first)), as: UTF8.self)
            for fragment in fragments {
                XCTAssertFalse(onDisk.contains(fragment.replacingOccurrences(of: "/", with: "\\/")), "Rewritten as soon as it was read")
            }
            XCTAssertEqual(snapshot.createdAt, Date(timeIntervalSince1970: 123), "Still the same index")
            XCTAssertEqual(snapshot.documents.first?.entry.path, path)
            if path == "/r/id_rsa" { XCTAssertEqual(snapshot.documents.first?.segments, []) }
        }
    }

    /// A key file doesn't change, so an update would reuse its old text for as long as it's there.
    func testUpdatingAnOlderIndexDoesNotCarryAKeyForward() async throws {
        let store = SearchIndexStore(directory: directory)
        let key = SyntheticKey.pem()
        try await saveAsOlderVersion("first\n" + key, path: "/r/notes.txt", store: store)
        let loaded = try await store.load(profile: profile, root: "/r")
        let previous = try XCTUnwrap(loaded)
        let entry = try XCTUnwrap(previous.documents.first?.entry)
        let service = NoReadsService(entry: entry)
        let updated = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service, includeHidden: true,
                                                              extraction: previous.extraction, reusing: previous)
        XCTAssertEqual(updated.documents.count, 1, "The unchanged file was kept, not read again")
        for fragment in SyntheticKey.fragments(of: key) {
            XCTAssertFalse(updated.documents.flatMap(\.segments).map(\.text).joined().contains(fragment))
        }
    }

    func testCleaningAnOlderIndexKeepsItsSettingAndABuildUnderWay() async throws {
        let store = SearchIndexStore(directory: directory)
        try await saveAsOlderVersion("first\n" + SyntheticKey.pem(), path: "/r/notes.txt", store: store)
        try await store.setUpdatesAutomatically(true, profile: profile, root: "/r")
        let generation = try await store.beginBuild(profile: profile, root: "/r")
        _ = try await store.load(profile: profile, root: "/r")
        let automatic = try await store.updatesAutomatically(profile: profile, root: "/r")
        XCTAssertTrue(automatic)
        try await store.save(snapshot([document("/r/new.txt")]), profile: profile, root: "/r", generation: generation)
        let loaded = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(loaded?.documents.map(\.entry.path), ["/r/new.txt"])
    }

    func testSavingAKeyHidesItEvenIfACallerMissedIt() async throws {
        let store = SearchIndexStore(directory: directory)
        let key = SyntheticKey.pem()
        try await store.save(snapshot([document("/r/notes.txt", text: "first\n" + key)]), profile: profile, root: "/r")
        let onDisk = String(decoding: try Data(contentsOf: try XCTUnwrap(files().first)), as: UTF8.self)
        for fragment in SyntheticKey.fragments(of: key) {
            XCTAssertFalse(onDisk.contains(fragment.replacingOccurrences(of: "/", with: "\\/")))
        }
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

    func testReloadPreservesTruncationAndTreatsOlderIndexesAsUnknown() async throws {
        let store = SearchIndexStore(directory: directory)
        func recorded(_ path: String, truncated: Bool?) -> SearchIndexDocument {
            let base = document(path)
            return .init(entry: base.entry, segments: base.segments, isTruncated: truncated)
        }
        try await store.save(snapshot([recorded("/r/complete.txt", truncated: false), recorded("/r/cut.txt", truncated: true)]),
                             profile: profile, root: "/r")
        let saved = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(saved?.documents.map(\.isTruncated), [false, true])
        // An index written before truncation was recorded has no such key and must still load.
        let file = try XCTUnwrap(files().first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let documents = try XCTUnwrap(json["documents"] as? [[String: Any]])
        json["documents"] = documents.map { $0.filter { $0.key != "isTruncated" } }
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let older = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(older?.documents.map(\.entry.path), ["/r/complete.txt", "/r/cut.txt"])
        XCTAssertEqual(older?.documents.map(\.isTruncated), [nil, nil])
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

    /// A name starting with a joiner or a combining mark forms one Character with the slash before it.
    /// Split by Character, its path had no such name, and one file like it failed every save of its index.
    func testNamesStartingWithAJoinerOrCombiningMarkAreSavedAndSearched() async throws {
        let store = SearchIndexStore(directory: directory)
        for root in ["/r", "/"] {
            let prefix = root == "/" ? "/" : root + "/"
            let paths = [prefix + "\u{200D}join.txt", prefix + "\u{301}x", prefix + "sub/\u{301}y.txt", prefix + "a\u{600}/z.txt"]
            try await store.save(snapshot(paths.map { document($0) }), profile: profile, root: root)
            let loaded = try await store.load(profile: profile, root: root)
            XCTAssertEqual(loaded?.documents.map(\.entry.path), paths)
            XCTAssertEqual(loaded?.documents.map(\.entry.name), ["\u{200D}join.txt", "\u{301}x", "\u{301}y.txt", "z.txt"])
            let found = try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: try XCTUnwrap(loaded), includeHidden: false, root: root)
            XCTAssertEqual(found.contentMatches.map(\.entry.path), paths)
        }
        // Hidden by its first byte, as the folder walk and the server see it.
        let hidden = "/r/.\u{301}x"
        do { try await store.save(snapshot([document(hidden)]), profile: profile, root: "/r"); XCTFail("A hidden name was saved as visible") }
        catch SearchIndexError.invalidSnapshot {}
        try await store.save(snapshot([document(hidden)], hidden: true), profile: profile, root: "/r")
        let saved = try await store.load(profile: profile, root: "/r")
        let withHidden = try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: try XCTUnwrap(saved), includeHidden: true, root: "/r")
        XCTAssertEqual(withHidden.contentMatches.map(\.entry.path), [hidden])
        let withoutHidden = try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: try XCTUnwrap(saved), includeHidden: false, root: "/r")
        XCTAssertEqual(withoutHidden.contentMatches.map(\.entry.path), [])

        // An index of visible files saved when hidden went by the first Character can hold such a
        // name. It loads without it, where it would otherwise count as damaged and never update.
        try await store.save(snapshot([document("/r/a.txt"), document(hidden)], hidden: true), profile: profile, root: "/r")
        var edited = false
        for file in try files() where file.lastPathComponent.count == 69 {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            guard object["root"] as? String == "/r" else { continue }
            object["includeHidden"] = false; edited = true
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        }
        XCTAssertTrue(edited)
        let older = try await SearchIndexStore(directory: directory).load(profile: profile, root: "/r")
        XCTAssertEqual(older?.documents.map(\.entry.path), ["/r/a.txt"]); XCTAssertEqual(older?.includeHidden, false)
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

    /// Windows share this store. An automatic update starting in one must not replace a build
    /// someone asked for in another, whose save would then fail as superseded.
    func testAnAutomaticUpdateNeverReplacesABuildSomeoneAskedFor() async throws {
        let store = SearchIndexStore(directory: directory)
        let started = Date(timeIntervalSince1970: 1_000)
        let manual = try await store.beginBuild(profile: profile, root: "/r", now: started)
        do {
            _ = try await store.beginBuild(profile: profile, root: "/r", automatic: true, now: started.addingTimeInterval(5))
            XCTFail("An automatic update replaced a manual build under way")
        } catch SearchIndexError.superseded {}
        let otherRoot = try await store.beginBuild(profile: profile, root: "/s", automatic: true, now: started)
        try await store.save(snapshot([document("/s/a.txt")]), profile: profile, root: "/s", generation: otherRoot)
        try await store.save(snapshot([document("/r/manual.txt")]), profile: profile, root: "/r", generation: manual)

        // Once the manual build has saved, failed or been cancelled, automatic updates run again.
        let afterSave = try await store.beginBuild(profile: profile, root: "/r", automatic: true, now: started.addingTimeInterval(6))
        // A manual build still replaces an automatic one, as it always did.
        let replacing = try await store.beginBuild(profile: profile, root: "/r", now: started.addingTimeInterval(7))
        do {
            try await store.save(snapshot([document("/r/automatic.txt")]), profile: profile, root: "/r", generation: afterSave)
            XCTFail("An automatic update outlived the manual build that replaced it")
        } catch SearchIndexError.superseded {}
        await store.endBuild(profile: profile, root: "/r", generation: afterSave)
        do {
            _ = try await store.beginBuild(profile: profile, root: "/r", automatic: true, now: started.addingTimeInterval(8))
            XCTFail("Ending a replaced reservation released the one that replaced it")
        } catch SearchIndexError.superseded {}
        await store.endBuild(profile: profile, root: "/r", generation: replacing)
        let afterEnd = try await store.beginBuild(profile: profile, root: "/r", automatic: true, now: started.addingTimeInterval(9))
        try await store.save(snapshot([document("/r/automatic.txt")]), profile: profile, root: "/r", generation: afterEnd)

        // A reservation nothing ever ended stops holding updates off after its allowance.
        _ = try await store.beginBuild(profile: profile, root: "/r", now: started)
        do {
            _ = try await store.beginBuild(profile: profile, root: "/r", automatic: true,
                                           now: started.addingTimeInterval(SearchIndexStore.manualBuildAllowance - 1))
            XCTFail("A manual build within its allowance was replaced")
        } catch SearchIndexError.superseded {}
        _ = try await store.beginBuild(profile: profile, root: "/r", automatic: true,
                                       now: started.addingTimeInterval(SearchIndexStore.manualBuildAllowance))
        let saved = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(saved?.documents.map(\.entry.path), ["/r/automatic.txt"])
    }

    /// Opening a folder asks whether its index is due. That reads when the index was made, once,
    /// and never its text; the answer follows every save, deletion and change of the setting.
    func testWhetherAnIndexIsDueFollowsSavesDeletionsAndTheSetting() async throws {
        let store = SearchIndexStore(directory: directory)
        let made = Date(timeIntervalSince1970: 123), interval: TimeInterval = 900
        func due(_ store: SearchIndexStore, at offset: TimeInterval, root: String = "/r") async throws -> Bool {
            try await store.isDueForAutomaticUpdate(profile: profile, root: root, now: made.addingTimeInterval(offset), interval: interval)
        }
        let unsaved = try await due(store, at: interval)
        XCTAssertFalse(unsaved)
        try await store.save(snapshot([document("/r/a.txt")]), profile: profile, root: "/r")
        let notAutomatic = try await due(store, at: interval)
        XCTAssertFalse(notAutomatic, "Only an index set to update automatically is ever due")
        try await store.setUpdatesAutomatically(true, profile: profile, root: "/r")
        let early = try await due(store, at: interval - 1), onTime = try await due(store, at: interval), clockBack = try await due(store, at: -60)
        XCTAssertFalse(early); XCTAssertTrue(onTime); XCTAssertTrue(clockBack)
        let otherRoot = try await due(store, at: interval, root: "/s")
        XCTAssertFalse(otherRoot)

        // Another store on the same files, as after a relaunch, reads it from the file.
        let reopened = SearchIndexStore(directory: directory)
        let reopenedEarly = try await due(reopened, at: interval - 1), reopenedDue = try await due(reopened, at: interval)
        XCTAssertFalse(reopenedEarly); XCTAssertTrue(reopenedDue)

        // A newer index saved through one store is seen by the other, which remembered the older one.
        let later = SearchIndexSnapshot(createdAt: made.addingTimeInterval(600), documents: [document("/r/b.txt")],
                                        includeHidden: false, extraction: .init(includePDF: true, includeOCR: true), isPartial: false)
        try await reopened.save(later, profile: profile, root: "/r")
        let afterUpdate = try await due(store, at: interval), afterUpdateLater = try await due(store, at: 600 + interval)
        XCTAssertFalse(afterUpdate, "The saved index is newer than the one last asked about")
        XCTAssertTrue(afterUpdateLater)
        let loaded = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(loaded?.createdAt, later.createdAt)

        try await store.setUpdatesAutomatically(false, profile: profile, root: "/r")
        let turnedOff = try await due(store, at: 10_000)
        XCTAssertFalse(turnedOff)
        try await store.setUpdatesAutomatically(true, profile: profile, root: "/r")
        try await store.remove(profile: profile, root: "/r")
        let removed = try await due(store, at: 10_000)
        XCTAssertFalse(removed)

        // A file that can't be read isn't due: nothing can be updated from it.
        try await store.save(snapshot([document("/r/c.txt")]), profile: profile, root: "/r")
        try await store.setUpdatesAutomatically(true, profile: profile, root: "/r")
        try Data("{".utf8).write(to: try XCTUnwrap(files().first { $0.lastPathComponent.count == 69 }))
        do { _ = try await due(SearchIndexStore(directory: directory), at: interval); XCTFail("A damaged index was reported as due") }
        catch SearchIndexError.damaged {}
    }

    /// A process that ends between writing a save's temporary file and renaming it leaves extracted
    /// text that no limit counts and no deletion finds.
    func testTemporaryFilesLeftByAnEarlierProcessAreRemoved() async throws {
        let store = SearchIndexStore(directory: directory)
        try await store.save(snapshot([document("/r/a.txt")]), profile: profile, root: "/r")
        func plant(_ name: String, age: TimeInterval) throws -> URL {
            let file = directory.appendingPathComponent(name)
            try Data("left behind".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
            return file
        }
        var old = try plant(".pending-" + UUID().uuidString, age: SearchIndexStore.abandonedWriteAge + 60)
        var recent = try plant(".pending-" + UUID().uuidString, age: 5)
        try await store.save(snapshot([document("/r/b.txt")]), profile: profile, root: "/r")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "It may be another store's save under way")
        try FileManager.default.removeItem(at: recent)

        old = try plant(".pending-" + UUID().uuidString, age: SearchIndexStore.abandonedWriteAge + 60)
        recent = try plant(".pending-" + UUID().uuidString, age: 5)
        try await store.remove(connectionID: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        let kept = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(kept?.documents.map(\.entry.path), ["/r/b.txt"])
        // A save leaves nothing of its own behind.
        try FileManager.default.removeItem(at: recent)
        try await store.save(snapshot([document("/r/c.txt")]), profile: profile, root: "/r")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }, [])
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

    func testAutomaticUpdatesNeedASavedIndexPersistAcrossSavesAndEndWithTheIndex() async throws {
        let store = SearchIndexStore(directory: directory)
        do {
            try await store.setUpdatesAutomatically(true, profile: profile, root: "/r")
            XCTFail("Automatic updates turned on without a saved index")
        } catch SearchIndexError.notSaved {}
        try await store.save(snapshot([document("/r/a.txt")]), profile: profile, root: "/r")
        try await store.save(snapshot([document("/s/a.txt")]), profile: profile, root: "/s")
        let initiallyOff = try await store.updatesAutomatically(profile: profile, root: "/r")
        XCTAssertFalse(initiallyOff)
        try await store.setUpdatesAutomatically(true, profile: profile, root: "/r")
        let reopened = SearchIndexStore(directory: directory)
        let persisted = try await reopened.updatesAutomatically(profile: profile, root: "/r")
        let otherRoot = try await reopened.updatesAutomatically(profile: profile, root: "/s")
        var edited = profile; edited.port = 2222
        let editedProfile = try await reopened.updatesAutomatically(profile: edited, root: "/r")
        XCTAssertTrue(persisted); XCTAssertFalse(otherRoot); XCTAssertFalse(editedProfile)
        // The settings name an index only by its hashed key, never by folder or host.
        let settings = try JSONDecoder().decode([String: UUID].self,
            from: Data(contentsOf: directory.appendingPathComponent("automatic-updates-v1.json")))
        XCTAssertEqual(Array(settings.values), [profile.id])
        XCTAssertEqual(settings.keys.first?.count, 64)
        XCTAssertEqual(Set(try files().map { $0.deletingPathExtension().lastPathComponent }).intersection(settings.keys).count, 1)

        // Updating or rebuilding an index keeps its setting.
        try await reopened.save(snapshot([document("/r/b.txt")]), profile: profile, root: "/r")
        let afterSave = try await reopened.updatesAutomatically(profile: profile, root: "/r")
        XCTAssertTrue(afterSave)

        // Deleting the index forgets the setting, so a new index starts with it off.
        try await reopened.remove(profile: profile, root: "/r")
        try await reopened.save(snapshot([document("/r/c.txt")]), profile: profile, root: "/r")
        let afterDelete = try await SearchIndexStore(directory: directory).updatesAutomatically(profile: profile, root: "/r")
        XCTAssertFalse(afterDelete)

        try await reopened.setUpdatesAutomatically(true, profile: profile, root: "/r")
        try await reopened.setUpdatesAutomatically(false, profile: profile, root: "/r")
        let turnedOff = try await SearchIndexStore(directory: directory).updatesAutomatically(profile: profile, root: "/r")
        XCTAssertFalse(turnedOff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("automatic-updates-v1.json").path))
    }

    func testConnectionRemovalAndEvictionTurnOffAutomaticUpdates() async throws {
        let store = SearchIndexStore(directory: directory)
        var other = profile; other.id = UUID()
        try await store.save(snapshot([document("/r/a.txt")]), profile: profile, root: "/r")
        try await store.save(snapshot([document("/r/a.txt")]), profile: other, root: "/r")
        try await store.setUpdatesAutomatically(true, profile: profile, root: "/r")
        try await store.setUpdatesAutomatically(true, profile: other, root: "/r")
        try await store.remove(connectionID: profile.id)
        let removed = try await store.updatesAutomatically(profile: profile, root: "/r")
        let kept = try await SearchIndexStore(directory: directory).updatesAutomatically(profile: other, root: "/r")
        XCTAssertFalse(removed); XCTAssertTrue(kept)

        for number in 1..<SearchIndexStore.maximumIndexes {
            try await store.save(snapshot([document("/r\(number)/file.txt")]), profile: profile, root: "/r\(number)")
        }
        for file in try files() {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let isOther = (json["connectionID"] as? String) == other.id.uuidString
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: isOther ? 0 : 100)], ofItemAtPath: file.path)
        }
        try await store.save(snapshot([document("/new/file.txt")]), profile: profile, root: "/new")
        let evicted = try await store.load(profile: other, root: "/r")
        XCTAssertNil(evicted)
        try await store.save(snapshot([document("/r/a.txt")]), profile: other, root: "/r")
        let afterEviction = try await SearchIndexStore(directory: directory).updatesAutomatically(profile: other, root: "/r")
        XCTAssertFalse(afterEviction, "An evicted index's setting does not carry over to a new index")
    }

    func testUnreadableAutomaticSettingsTurnUpdatesOffWithoutBreakingTheIndex() async throws {
        let store = SearchIndexStore(directory: directory)
        try await store.save(snapshot([document("/r/a.txt")]), profile: profile, root: "/r")
        try Data("not json".utf8).write(to: directory.appendingPathComponent("automatic-updates-v1.json"))
        let reopened = SearchIndexStore(directory: directory)
        let enabled = try await reopened.updatesAutomatically(profile: profile, root: "/r")
        XCTAssertFalse(enabled)
        let loaded = try await reopened.load(profile: profile, root: "/r")
        XCTAssertNotNil(loaded)
        try await reopened.setUpdatesAutomatically(true, profile: profile, root: "/r")
        let repaired = try await SearchIndexStore(directory: directory).updatesAutomatically(profile: profile, root: "/r")
        XCTAssertTrue(repaired)
    }

    func testAutomaticUpdateIsDueOnceTheIntervalPassesOrTheClockMovesBack() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let index = SearchIndexSnapshot(createdAt: created, documents: [], includeHidden: false, extraction: .init(), isPartial: false)
        let interval = SearchIndexSnapshot.automaticUpdateInterval
        XCTAssertEqual(interval, 15 * 60)
        XCTAssertFalse(index.isDueForAutomaticUpdate(at: created))
        XCTAssertFalse(index.isDueForAutomaticUpdate(at: created.addingTimeInterval(interval - 1)))
        XCTAssertTrue(index.isDueForAutomaticUpdate(at: created.addingTimeInterval(interval)))
        XCTAssertTrue(index.isDueForAutomaticUpdate(at: created.addingTimeInterval(-60)), "A clock set back cannot postpone updates")
    }
}

/// A folder holding one file. An update that keeps a file's text mustn't read it.
private actor NoReadsService: RemoteFileService {
    let entry: RemoteEntry
    init(entry: RemoteEntry) { self.entry = entry }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: [entry]) }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data {
        XCTFail("An unchanged file should be kept")
        throw RemoteFileError.unsupportedFile
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() async {}
}
