#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import PDFKit
@testable import RemoteFilesCore
@testable import RemoteFilesUI

/// Serves one folder holding a six-page PDF and a long plain-text file.
private actor OfflineHistoryTransport: RemoteFileService {
    let pdf: Data
    let text: String
    init(pdf: Data, text: String) { self.pdf = pdf; self.text = text }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        .init(path: path, entries: ["report.pdf", "notes.txt"].map { .init(name: $0, path: "/docs/" + $0, kind: .file) })
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: "docs", path: path, kind: .directory)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        throw RemoteFileError.unsupportedFile
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL,
                      limit: Int) async throws -> RemoteEntry {
        try (path.hasSuffix(".pdf") ? pdf : Data(text.utf8)).write(to: destination)
        return .init(name: RemotePath.name(of: path), path: path, kind: .file)
    }
    func disconnect() {}
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await downloadFile(profile: profile, path: path, allowedRoot: canonicalRoot, destination: destination, limit: limit)
    }
}

@MainActor @Observable private final class OfflineHistoryFixtureState {
    var path: [OfflineDocumentRoute] = []
    var phase = ScenePhase.active
}

private struct OfflineHistoryFixture: View {
    @Bindable var state: OfflineHistoryFixtureState
    let store: OfflineFileStore
    let positions: ReadingPositionStore?
    var body: some View {
        NavigationStack(path: $state.path) {
            Text("Offline library")
                .navigationDestination(for: OfflineDocumentRoute.self) { route in
                    OfflineReaderView(pin: route.pin, store: store, initialFragment: route.fragment,
                                      readingPositions: positions, openDocument: { state.path.append($0) })
                }
        }.environment(\.scenePhase, state.phase)
    }
}

@MainActor final class OfflineReaderHistoryTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let store: OfflineFileStore
        let profile: ConnectionProfile
        let pdf: OfflinePin
        let text: OfflinePin
        let pdfBytes: Data
        let textContents: String
    }

    func testOfflinePDFOpensAtTheSharedSavedPageAndRecordsWhereItWasLeft() async throws {
        let fixture = try await makeFixture()
        let positionsURL = fixture.directory.appendingPathComponent("positions.json")
        let positions = ReadingPositionStore(fileURL: positionsURL)
        // History written by the connected reader for these exact bytes.
        let revision = try SavedReadingPosition.revision(forFileAt: writeTemporary(fixture.pdfBytes, in: fixture.directory))
        try await positions.save(.init(revision: revision, renderedAnchor: .init(kind: "pdf-page", ordinal: 3, fraction: 0.25)),
                                 connectionID: fixture.profile.id, path: "/docs/report.pdf")
        let state = OfflineHistoryFixtureState()
        let window = try host(state: state, store: fixture.store, positions: positions)

        state.path.append(.init(pin: fixture.pdf))
        var view = try await restoredPDF(in: window)
        XCTAssertEqual(currentPage(view), 3, "The offline copy opens at the connected reader's saved page")

        // The last page can't reach the top of a tall viewport; use the one before it.
        let target = try XCTUnwrap(view.document?.page(at: 4))
        view.go(to: target)
        try await waitUntil { self.currentPage(view) == 4 }
        state.path.removeAll()
        try await waitUntil { self.leaseURLs(fixture.directory).isEmpty }
        var saved: SavedReadingPosition?
        try await waitUntil {
            saved = await positions.restore(connectionID: fixture.profile.id, path: "/docs/report.pdf", revision: revision)
            return saved?.renderedAnchor?.ordinal == 4
        }
        XCTAssertEqual(saved?.renderedAnchor?.kind, "pdf-page")

        // A fresh store reads the file the reader wrote; a new route has no in-memory position.
        let reopened = ReadingPositionStore(fileURL: positionsURL)
        let restored = await reopened.restore(connectionID: fixture.profile.id, path: "/docs/report.pdf", revision: revision)
        XCTAssertEqual(restored?.renderedAnchor?.ordinal, 4)
        state.path.append(.init(pin: fixture.pdf))
        view = try await restoredPDF(in: window)
        XCTAssertEqual(currentPage(view), 4, "Reopening the copy returns to where it was left")

        // Backgrounding releases the copy and writes its position without leaving the reader.
        view.go(to: try XCTUnwrap(view.document?.page(at: 1)))
        try await waitUntil { self.currentPage(view) == 1 }
        state.phase = .background
        try await waitUntil { self.leaseURLs(fixture.directory).isEmpty }
        try await waitUntil {
            await positions.restore(connectionID: fixture.profile.id, path: "/docs/report.pdf", revision: revision)?.renderedAnchor?.ordinal == 1
        }
        state.phase = .active
        view = try await restoredPDF(in: window)
        XCTAssertEqual(currentPage(view), 1)
        state.path.removeAll()
        try await waitUntil { self.leaseURLs(fixture.directory).isEmpty }
    }

    func testOfflineTextRestoresItsSourcePositionAcrossReaders() async throws {
        let fixture = try await makeFixture()
        let positions = ReadingPositionStore(fileURL: fixture.directory.appendingPathComponent("positions.json"))
        let state = OfflineHistoryFixtureState()
        let window = try host(state: state, store: fixture.store, positions: positions)

        state.path.append(.init(pin: fixture.text))
        var source = try await sourceView(in: window)
        XCTAssertEqual(source.contentOffset.y + source.adjustedContentInset.top, 0, accuracy: 1, "No history opens at the top")
        let offset = CGPoint(x: 0, y: 2_400 - source.adjustedContentInset.top)
        source.setContentOffset(offset, animated: false)
        // Mirrors the end of a user scroll, which records the reading anchor.
        source.captureReadingAnchor()
        let revision = SavedReadingPosition.revision(for: fixture.textContents)
        state.path.removeAll()
        try await waitUntil { self.leaseURLs(fixture.directory).isEmpty }
        var saved: SavedReadingPosition?
        try await waitUntil {
            saved = await positions.restore(connectionID: fixture.profile.id, path: "/docs/notes.txt", revision: revision)
            return (saved?.source.y ?? 0) > 1_000
        }

        state.path.append(.init(pin: fixture.text))
        source = try await sourceView(in: window)
        try await waitUntil { abs(source.contentOffset.y - offset.y) < 40 }
        state.path.removeAll()
        try await waitUntil { self.leaseURLs(fixture.directory).isEmpty }
    }

    func testOfflineReaderWithoutHistoryWritesNone() async throws {
        let fixture = try await makeFixture()
        let state = OfflineHistoryFixtureState()
        let window = try host(state: state, store: fixture.store, positions: nil)
        state.path.append(.init(pin: fixture.pdf))
        let view = try await restoredPDF(in: window)
        XCTAssertEqual(currentPage(view), 0)
        view.go(to: try XCTUnwrap(view.document?.page(at: 4)))
        try await waitUntil { self.currentPage(view) == 4 }
        // Back within the session still returns to the page held in memory.
        let text = try await fixture.store.resolveDocumentLink(from: fixture.pdf, reference: "notes.txt")
        state.path.append(.init(pin: text))
        _ = try await sourceView(in: window)
        state.path.removeLast()
        let returned = try await restoredPDF(in: window)
        XCTAssertEqual(currentPage(returned), 4)
        state.path.removeAll()
        try await waitUntil { self.leaseURLs(fixture.directory).isEmpty }
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        XCTAssertFalse(files.contains { $0.hasPrefix("positions") })
    }

    func testDemoAndRemovedConnectionsGiveOfflineCopiesNoHistory() async throws {
        let directory = try temporaryDirectory()
        let model = try AppModel(directory: directory, fileService: OfflineHistoryTransport(pdf: Data(), text: ""))
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "reader", identityID: UUID())
        let pin = OfflinePin(id: UUID(), connectionID: profile.id, connectionName: profile.name, routeKey: OfflinePin.routeKey(profile),
                             path: "/docs/notes.txt", filename: "notes.txt", previewFilename: "notes.txt", byteCount: 1,
                             savedAt: .now, blobID: UUID(), digest: "")
        XCTAssertNil(model.offlineReadingPositions(for: pin), "A copy whose connection was removed writes no new history")
        model.metadata.connections = [profile]
        XCTAssertTrue(model.offlineReadingPositions(for: pin) === model.readingPositions)
        model.demo = true
        XCTAssertNil(model.offlineReadingPositions(for: pin), "Demo writes no reading history")
    }

    // MARK: - Helpers

    private func makeFixture() async throws -> Fixture {
        let directory = try temporaryDirectory()
        let store = try OfflineFileStore(directory: directory.appendingPathComponent("Offline", isDirectory: true))
        let profile = ConnectionProfile(name: "Offline fixture", host: "fixture.invalid", username: "reader",
                                        identityID: UUID(), startingDirectory: "/docs")
        let pdf = Self.pdfData(pages: 6)
        let text = (1...600).map { "Line \($0) of the saved plain-text notes." }.joined(separator: "\n")
        _ = try await store.pinFolder(profile: profile, path: "/docs", service: OfflineHistoryTransport(pdf: pdf, text: text))
        let pins = await store.snapshot()
        return Fixture(directory: directory, store: store, profile: profile,
                       pdf: try XCTUnwrap(pins.first { $0.filename == "report.pdf" }),
                       text: try XCTUnwrap(pins.first { $0.filename == "notes.txt" }),
                       pdfBytes: pdf, textContents: text)
    }
    private static func pdfData(pages: Int) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                ("Page \(index + 1)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 48)])
            }
        }
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func writeTemporary(_ data: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
    private func host(state: OfflineHistoryFixtureState, store: OfflineFileStore, positions: ReadingPositionStore?) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: OfflineHistoryFixture(state: state, store: store, positions: positions))
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        return window
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private func restoredPDF(in window: UIWindow) async throws -> RestoringPDFView {
        var result: RestoringPDFView?
        try await waitUntil {
            result = self.views(window).compactMap { $0 as? RestoringPDFView }.first { $0.window != nil && $0.isRestored }
            return result != nil
        }
        return try XCTUnwrap(result)
    }
    private func sourceView(in window: UIWindow) async throws -> SourceTextView {
        var result: SourceTextView?
        try await waitUntil {
            result = self.views(window).compactMap { $0 as? SourceTextView }
                .first { $0.window != nil && $0.contentSize.height > $0.bounds.height * 2 }
            return result != nil
        }
        return try XCTUnwrap(result)
    }
    private func currentPage(_ view: RestoringPDFView) -> Int? {
        guard let document = view.document, let anchor = view.readingAnchor() else { return nil }
        return anchor.ordinal < document.pageCount ? anchor.ordinal : nil
    }
    private func leaseURLs(_ directory: URL) -> [URL] {
        let base = directory.appendingPathComponent("Offline/.leases")
        return (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []
    }
    private func waitUntil(timeout: Duration = .seconds(15), file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Offline reader history did not settle", file: file, line: line)
        throw OfflineFileError.timedOut
    }
}
#endif
