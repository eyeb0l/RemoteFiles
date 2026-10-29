import XCTest
@testable import RemoteFilesCore

final class ReadingPositionStoreTests: XCTestCase {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("positions.json") }
    private func position(_ text: String, y: Double = 700) -> SavedReadingPosition {
        .init(revision: SavedReadingPosition.revision(for: text), rendered: .init(x: 8, y: y), source: .init(x: 22, y: 320))
    }
    func testRecreationRestoresIndependentModesOnlyForExactContent() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID(), original = position("Report\r\n東京")
        let store = ReadingPositionStore(fileURL: url)
        try await store.save(original, connectionID: id, path: "/Reports/report.md")
        let recreated = ReadingPositionStore(fileURL: url)
        let restored = await recreated.restore(connectionID: id, path: "/Reports/report.md", revision: original.revision)
        XCTAssertEqual(restored, original)
        let changed = await recreated.restore(connectionID: id, path: "/Reports/report.md", revision: SavedReadingPosition.revision(for: "Report\n東京"))
        XCTAssertNil(changed)
        let otherServer = await recreated.restore(connectionID: UUID(), path: "/Reports/report.md", revision: original.revision)
        XCTAssertNil(otherServer)
    }
    func testPathKeysPreserveExactUnicodeBytesAndCase() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ReadingPositionStore(fileURL: url), id = UUID()
        let composed = "/caf\u{e9}.md", decomposed = "/cafe\u{301}.md"
        try await store.save(position("same", y: 100), connectionID: id, path: composed)
        try await store.save(position("same", y: 200), connectionID: id, path: decomposed)
        let first = await store.restore(connectionID: id, path: composed, revision: position("same").revision)
        let second = await store.restore(connectionID: id, path: decomposed, revision: position("same").revision)
        let uppercase = await store.restore(connectionID: id, path: "/CAFÉ.md", revision: position("same").revision)
        XCTAssertEqual(first?.rendered.y, 100); XCTAssertEqual(second?.rendered.y, 200); XCTAssertNil(uppercase)
    }
    func testAnchorsRoundTripAndLegacyCoordinatesRemainReadable() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID(), store = ReadingPositionStore(fileURL: url)
        var value = position("report", y: 300)
        value.renderedAnchor = .init(kind: "prose", ordinal: 2, character: 230, viewportY: 40)
        value.sourceAnchor = .init(kind: "source", character: 420, viewportY: 30)
        try await store.save(value, connectionID: id, path: "/a")
        let restored = await ReadingPositionStore(fileURL: url).restore(connectionID: id, path: "/a", revision: value.revision)
        XCTAssertEqual(restored, value)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json.removeValue(forKey: "renderedAnchor"); json.removeValue(forKey: "sourceAnchor")
        let legacy = try JSONDecoder().decode(SavedReadingPosition.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.renderedAnchor); XCTAssertNil(legacy.sourceAnchor)
        XCTAssertEqual(legacy.rendered, value.rendered)
        value.sourceAnchor?.character = -1
        try await store.save(value, connectionID: id, path: "/invalid")
        let invalid = await store.restore(connectionID: id, path: "/invalid", revision: value.revision)
        XCTAssertNil(invalid)
    }

    func testHTMLAnchorsRoundTripWithoutDocumentContents() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID(), store = ReadingPositionStore(fileURL: url)
        for kind in ["html-text", "html-block"] {
            var value = position("Private HTML document text", y: 900)
            value.renderedAnchor = .init(kind: kind, ordinal: 12, character: 19, fraction: 0.4, viewportY: -3)
            value.sourceAnchor = .init(kind: "source", character: 700, viewportY: 8)
            try await store.save(value, connectionID: id, path: "/" + kind)
            let restored = await ReadingPositionStore(fileURL: url).restore(connectionID: id, path: "/" + kind, revision: value.revision)
            XCTAssertEqual(restored, value)
            let history = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(history.contains("Private HTML document text"))
        }
        for anchor in [SavedReadingPosition.Anchor(kind: "html-text", ordinal: -1),
                       .init(kind: "html-block", fraction: 1.01),
                       .init(kind: "html-text", character: 2_097_153),
                       .init(kind: "html-block", viewportY: .infinity)] {
            var value = position("Private HTML document text")
            value.renderedAnchor = anchor
            try await store.save(value, connectionID: id, path: "/invalid-html")
            let restored = await store.restore(connectionID: id, path: "/invalid-html", revision: value.revision)
            XCTAssertNil(restored)
        }
    }

    func testCapacityEvictsOldestAndUpdatingExistingRecordRetainsIt() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ReadingPositionStore(fileURL: url, capacity: 2), id = UUID(), value = position("report")
        try await store.save(value, connectionID: id, path: "/a")
        try await store.save(value, connectionID: id, path: "/b")
        try await store.save(position("report", y: 99), connectionID: id, path: "/a")
        try await store.save(value, connectionID: id, path: "/c")
        let recreated = ReadingPositionStore(fileURL: url, capacity: 2)
        let a = await recreated.restore(connectionID: id, path: "/a", revision: value.revision)
        let b = await recreated.restore(connectionID: id, path: "/b", revision: value.revision)
        let c = await recreated.restore(connectionID: id, path: "/c", revision: value.revision)
        XCTAssertEqual(a?.rendered.y, 99); XCTAssertNil(b); XCTAssertEqual(c, value)
    }
    func testRemovalPersistsAndRejectsLateReaderSaves() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ReadingPositionStore(fileURL: url), removed = UUID(), retained = UUID(), value = position("report")
        try await store.save(value, connectionID: removed, path: "/a")
        try await store.save(value, connectionID: retained, path: "/a")
        try await store.remove(connectionID: removed)
        try await store.save(value, connectionID: removed, path: "/a")
        let recreated = ReadingPositionStore(fileURL: url)
        let missing = await recreated.restore(connectionID: removed, path: "/a", revision: value.revision)
        let present = await recreated.restore(connectionID: retained, path: "/a", revision: value.revision)
        XCTAssertNil(missing); XCTAssertEqual(present, value)
    }
    func testCorruptHistoryAndInvalidCoordinatesDoNotPreventNewValidSaves() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt history".utf8).write(to: url)
        let store = ReadingPositionStore(fileURL: url), id = UUID(), valid = position("report")
        for invalid in [Double.nan, Double.infinity, -1, 100_000_001] {
            var candidate = valid; candidate.rendered.y = invalid
            try await store.save(candidate, connectionID: id, path: "/a")
        }
        let missing = await store.restore(connectionID: id, path: "/a", revision: valid.revision)
        XCTAssertNil(missing)
        try await store.save(valid, connectionID: id, path: "/a")
        let recreated = ReadingPositionStore(fileURL: url)
        let restored = await recreated.restore(connectionID: id, path: "/a", revision: valid.revision)
        XCTAssertEqual(restored, valid)
    }
}
