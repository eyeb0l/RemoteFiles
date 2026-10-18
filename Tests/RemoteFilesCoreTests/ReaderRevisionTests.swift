#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import RemoteFilesCore
@testable import RemoteFilesUI

private actor RevisionFileService: RemoteFileService {
    var bytes: Data
    init(_ text: String) { bytes = Data(text.utf8) }
    func replace(_ text: String) { bytes = Data(text.utf8) }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { bytes }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() async {}
}

@MainActor final class ReaderRevisionTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func viewport(_ window: UIWindow, source: Bool) -> UIScrollView? {
        descendants(window).compactMap { $0 as? UIScrollView }.first {
            $0.window === window && !$0.isHidden && $0.bounds.height > 200 &&
            $0.contentSize.height > $0.bounds.height * 2 && (source ? $0 is SourceTextView : !($0 is UITextView))
        }
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(predicate())
    }
    private func verifyNewSessionResetsChangedText(source: Bool) async throws {
        let text = source ? (0..<700).map { "Line \($0) of original source\n" }.joined() :
            (0..<70).map { "## Original section \($0)\n\nA paragraph of original report content to create a long reader.\n\n" }.joined()
        let changed = text.replacingOccurrences(of: "original", with: "updated").replacingOccurrences(of: "Original", with: "Updated")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RevisionFileService(text), model = try AppModel(directory: directory, fileService: service)
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "fixture", identityID: UUID(), startingDirectory: "/")
        model.metadata.connections = [profile]
        let entry = RemoteEntry(name: source ? "source.txt" : "report.md", path: source ? "/source.txt" : "/report.md", kind: .file)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ReaderView(model: model, profile: profile, entry: entry) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await waitUntil { self.viewport(window, source: source) != nil }
        let first = try XCTUnwrap(viewport(window, source: source))
        first.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        try await waitUntil { first.contentOffset.y > 800 }
        await service.replace(changed)
        model.sessionRevision += 1 // Foreground/reconnection path, not manual Refresh.
        try await waitUntil { self.viewport(window, source: source).map { $0 !== first } ?? false }
        let second = try XCTUnwrap(viewport(window, source: source))
        try await waitUntil { abs(second.contentOffset.y) < 2 }
        if source { XCTAssertEqual((second as? UITextView)?.attributedText.string, changed) }
        window.isHidden = true; window.rootViewController = nil
        let revision = SavedReadingPosition.revision(for: changed)
        let deadline = ContinuousClock.now + .seconds(5)
        var saved: SavedReadingPosition?
        repeat {
            saved = await model.readingPositions.restore(connectionID: profile.id, path: entry.path, revision: revision)
            if saved != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        let position = try XCTUnwrap(saved)
        XCTAssertEqual(source ? position.source.y : position.rendered.y, 0, accuracy: 2)
    }
    func testChangedRenderedTextOnReconnectStartsAtTopAndSavesNewRevision() async throws {
        try await verifyNewSessionResetsChangedText(source: false)
    }
    func testChangedBoundedSourceOnReconnectStartsAtTopAndSavesNewRevision() async throws {
        try await verifyNewSessionResetsChangedText(source: true)
    }
}
#endif
