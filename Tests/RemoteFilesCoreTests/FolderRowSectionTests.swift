#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import RemoteFilesCore
@testable import RemoteFilesUI

final class FolderRowSectionTests: XCTestCase {
    func testSectionsCoverEveryRowInOrderWithBoundedSizeAndCount() {
        for count in [0, 1, 31, 32, 33, 1_000, 1_024, 1_025, 4_096, 4_097, 10_000, 100_000, 250_000] {
            let sections = (0..<FolderRowSections.count(for: count)).map { FolderRowSections.rows(in: $0, of: count) }
            XCTAssertEqual(sections.flatMap { Array($0) }, Array(0..<count), "\(count) rows")
            XCTAssertFalse(sections.contains { $0.isEmpty }, "\(count) rows")
            let size = FolderRowSections.size(for: count)
            XCTAssertGreaterThanOrEqual(size * size, count)
            XCTAssertTrue(size == 32 || (size / 2) * (size / 2) < count, "\(count) rows use the smallest size that covers them")
        }
        XCTAssertEqual(FolderRowSections.size(for: 1_000), 32)
        XCTAssertEqual(FolderRowSections.size(for: 10_000), 128)
        XCTAssertEqual(FolderRowSections.count(for: 250_000), 489, "The listing limit stays within a few hundred sections")
    }

    /// Each revision replaces every section. A refresh that adds a row below the viewport must still
    /// leave the visible row where it was.
    @MainActor func testRefreshThatReplacesTheSectionsKeepsTheVisibleRow() async throws {
        let service = GrowingFolderService(count: 1_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: service)
        let profile = ConnectionProfile(name: "Rows", host: "fixture.invalid", username: "rows", identityID: UUID(), startingDirectory: "/rows")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            FolderView(model: model, profile: profile, requestedPath: "/rows")
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        func find(_ view: UIView) -> UICollectionView? {
            (view as? UICollectionView) ?? view.subviews.lazy.compactMap(find).first
        }
        func total(_ list: UICollectionView) -> Int { (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) } }
        /// The first row whose top is in view, by its position among all rows, and its distance from the
        /// top. Only rows below the viewport change here, so the same position is the same row.
        func top(_ list: UICollectionView) -> (row: Int, y: CGFloat)? {
            let visibleTop = list.contentOffset.y + list.adjustedContentInset.top
            guard let path = list.indexPathsForVisibleItems.sorted().first(where: {
                (list.layoutAttributesForItem(at: $0)?.frame.minY ?? -.infinity) >= visibleTop
            }), let frame = list.layoutAttributesForItem(at: path)?.frame else { return nil }
            let before = (0..<path.section).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
            return (before + path.item, frame.minY - list.contentOffset.y)
        }
        // Hosted runners are slow; these bounds only end a failing run.
        func wait(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(60)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    XCTFail("Timed out waiting for \(what)")
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        /// Waits for the layout to stop moving the top row.
        func settledTop(_ list: UICollectionView) async throws -> (row: Int, y: CGFloat) {
            var last = top(list), stableSince = ContinuousClock.now
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now - stableSince < .milliseconds(500) {
                guard ContinuousClock.now < deadline else {
                    XCTFail("The folder's layout never settled")
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(20))
                let now = top(list)
                if now?.row != last?.row || now?.y != last?.y { last = now; stableSince = ContinuousClock.now }
            }
            return try XCTUnwrap(last)
        }

        var list: UICollectionView?
        try await wait("rows") { list = find(window); return list.map { total($0) == 1_000 && !$0.visibleCells.isEmpty } ?? false }
        let rows = try XCTUnwrap(list)
        XCTAssertGreaterThan(rows.numberOfSections, 1, "A thousand rows are split into sections")
        rows.setContentOffset(CGPoint(x: 0, y: (rows.contentSize.height - rows.bounds.height) / 2), animated: false)
        let before = try await settledTop(rows)
        XCTAssertGreaterThan(before.row, 100, "The list is scrolled well past its first section")

        try XCTUnwrap(rows.refreshControl).sendActions(for: .valueChanged)
        // Find the list again, so a list rebuilt by the refresh is measured rather than waited on.
        try await wait("refreshed rows") { list = find(window); return list.map { total($0) == 1_001 } ?? false }
        let after = try await settledTop(try XCTUnwrap(list))
        XCTAssertEqual(after.row, before.row, "The same row stays at the top")
        XCTAssertEqual(after.y, before.y, accuracy: 1, "at the same height")
    }
}

/// Lists a folder of `count` files, and one more, sorted last, each time after the first.
private actor GrowingFolderService: RemoteFileService {
    private let count: Int
    private var listings = 0
    init(count: Int) { self.count = count }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        listings += 1
        let names = (0..<count).map { String(format: "File %04d.txt", $0) } + (listings > 1 ? ["Zulu.txt"] : [])
        return .init(path: path, entries: names.map { RemoteEntry(name: $0, path: path + "/" + $0, kind: .file, size: 1) })
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .directory)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { Data() }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        throw RemoteFileError.unavailable("Not used")
    }
    func disconnect() async {}
}
#endif
