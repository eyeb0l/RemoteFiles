#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import RemoteFilesCore
@testable import RemoteFilesUI
@testable import Textual

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
            $0.contentSize.height > $0.bounds.height * 2 &&
                (source ? ($0 as? SourceTextView).map { $0.pendingOffset == nil } == true : !($0 is UITextView))
        }
    }
    private func containsDocument(_ window: UIWindow, source: Bool, marker: String) -> Bool {
        if source {
            return descendants(window).compactMap { $0 as? SourceTextView }.contains {
                $0.window === window && $0.text.contains(marker)
            }
        }
        return descendants(window).compactMap { $0 as? UITextInteractionView }.contains {
            guard $0.window === window, $0.model.hasText else { return false }
            return $0.model.text(in: TextRange(start: $0.model.startPosition, end: $0.model.endPosition)).contains(marker)
        }
    }
    private enum WaitFailure: Error { case timeout }
    private func waitUntil(_ condition: String, diagnostics: () -> String = { "" },
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard predicate() else {
            XCTFail("Timed out waiting for \(condition): \(diagnostics())", file: file, line: line)
            throw WaitFailure.timeout
        }
    }
    private func viewportState(_ window: UIWindow) -> String {
        descendants(window).compactMap { $0 as? UIScrollView }.map {
            "\(type(of: $0)) attached=\($0.window === window) hidden=\($0.isHidden) bounds=\($0.bounds) content=\($0.contentSize) inset=\($0.adjustedContentInset) offset=\($0.contentOffset) pending=\(String(describing: ($0 as? SourceTextView)?.pendingOffset))"
        }.joined(separator: "; ")
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
        let originalMarker = source ? "Line 699 of original source" : "Original section 69"
        let changedMarker = originalMarker.replacingOccurrences(of: "original", with: "updated").replacingOccurrences(of: "Original", with: "Updated")
        try await waitUntil("initial document in viewport", diagnostics: { self.viewportState(window) }) {
            self.viewport(window, source: source) != nil && self.containsDocument(window, source: source, marker: originalMarker)
        }
        await Task.yield()
        let first = try XCTUnwrap(viewport(window, source: source))
        first.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        try await waitUntil("original document scrolled", diagnostics: { self.viewportState(window) }) { first.contentOffset.y > 800 }
        if !source {
            // A native offset alone can precede SwiftUI's scroll observation.
            // The source adapter intentionally records only user-driven scrolling.
            let originalRevision = SavedReadingPosition.revision(for: text)
            let scrollDeadline = ContinuousClock.now + .seconds(10)
            var originalSaved: SavedReadingPosition?
            repeat {
                originalSaved = await model.readingPositions.restore(connectionID: profile.id, path: entry.path, revision: originalRevision)
                if let originalSaved, originalSaved.rendered.y > 800 { break }
                try await Task.sleep(for: .milliseconds(25))
            } while ContinuousClock.now < scrollDeadline
            let originalPosition = try XCTUnwrap(originalSaved, "The original rendered scroll must be observed before reconnecting")
            XCTAssertGreaterThan(originalPosition.rendered.y, 800)
            guard originalPosition.rendered.y > 800 else { throw WaitFailure.timeout }
        }
        await service.replace(changed)
        model.sessionRevision += 1 // Foreground/reconnection path, not manual Refresh.
        try await waitUntil("replacement document in viewport", diagnostics: { self.viewportState(window) }) {
            (self.viewport(window, source: source).map { $0 !== first } ?? false) &&
                !first.isDescendant(of: window) && self.containsDocument(window, source: source, marker: changedMarker)
        }
        let second = try XCTUnwrap(viewport(window, source: source))
        try await waitUntil("replacement viewport at top", diagnostics: { self.viewportState(window) }) { abs(second.contentOffset.y) < 2 }
        if source { XCTAssertEqual((second as? UITextView)?.attributedText.string, changed) }
        else { XCTAssertTrue(containsDocument(window, source: false, marker: changedMarker)) }
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
