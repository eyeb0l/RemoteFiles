#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import PDFKit
import RemoteFilesCore
@testable import RemoteFilesUI

@MainActor @Observable private final class PDFFixtureState {
    var document: PDFDocument
    var restoration: SavedReadingPosition.Anchor?
    var page = 0
    let position: DocumentReadingPosition
    init(document: PDFDocument, restoration: SavedReadingPosition.Anchor?, position: DocumentReadingPosition) {
        self.document = document; self.restoration = restoration; self.position = position
    }
}

private struct PDFFixture: View {
    @Bindable var state: PDFFixtureState
    var body: some View {
        PDFDocumentView(document: state.document, restoration: state.restoration,
                        readingPosition: state.position, onPageChange: { state.page = $0 })
    }
}

@MainActor final class PDFReadingPositionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    /// Letter-sized pages, each labelled so a failure screenshot identifies the page.
    private func writePDF(pages: Int, label: String = "Page", to url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                ("\(label) \(index + 1)" as NSString).draw(at: CGPoint(x: 72, y: 72),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 48)])
            }
        }
        try data.write(to: url)
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private func pdfView(_ window: UIWindow) -> RestoringPDFView? { views(window).compactMap { $0 as? RestoringPDFView }.first }
    private func waitUntil(_ condition: () -> Bool, _ message: @autoclosure () -> String = "",
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for PDF state. " + message(), file: file, line: line)
    }
    private func host(_ state: PDFFixtureState) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: PDFFixture(state: state))
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        return window
    }

    func testSavedPageRestoresAfterLayoutAndLaterScrollIsPersisted() async throws {
        let directory = try temporaryDirectory()
        let pdfURL = directory.appendingPathComponent("report.pdf"), store = directory.appendingPathComponent("positions.json")
        try writePDF(pages: 6, to: pdfURL)
        let id = UUID(), saved = SavedReadingPosition.Anchor(kind: "pdf-page", ordinal: 3, fraction: 0.5)

        let first = DocumentReadingPosition()
        let prepared = await first.preparePDF(fileURL: pdfURL, store: ReadingPositionStore(fileURL: store), connectionID: id, path: "/report.pdf")
        XCTAssertTrue(prepared)
        XCTAssertNil(first.pdfAnchor, "A PDF without history opens at the top")
        let state = PDFFixtureState(document: try XCTUnwrap(PDFDocument(url: pdfURL)), restoration: saved, position: first)
        first.pdfAnchor = saved
        let window = try host(state)
        try await waitUntil({ self.pdfView(window)?.isRestored == true })
        let view = try XCTUnwrap(pdfView(window))
        let restored = try XCTUnwrap(view.readingAnchor())
        XCTAssertEqual(restored.ordinal, 3, "\(restored)")
        XCTAssertEqual(restored.fraction, 0.5, accuracy: 0.05, "\(restored)")
        XCTAssertEqual(state.page, 3, "The page indicator follows the restored page")

        // A user scroll back to page 2 is captured when the reader flushes.
        view.restore(.init(kind: "pdf-page", ordinal: 1, fraction: 0.25))
        try await waitUntil({ view.readingAnchor()?.ordinal == 1 }, "\(String(describing: view.readingAnchor()))")
        await first.flush()
        XCTAssertEqual(first.pdfAnchor?.ordinal, 1)
        XCTAssertEqual(first.pdfAnchor?.fraction ?? -1, 0.25, accuracy: 0.05)

        let recreated = DocumentReadingPosition()
        await recreated.preparePDF(fileURL: pdfURL, store: ReadingPositionStore(fileURL: store), connectionID: id, path: "/report.pdf")
        XCTAssertEqual(recreated.pdfAnchor?.ordinal, 1, "History restores from disk for identical bytes")
        XCTAssertNil(recreated.htmlAnchor)
        XCTAssertNil(recreated.overflowGeometry.snapshot, "PDF anchors never reach the Markdown restorer")

        try writePDF(pages: 6, label: "Revised page", to: pdfURL)
        await recreated.preparePDF(fileURL: pdfURL, store: ReadingPositionStore(fileURL: store), connectionID: id, path: "/report.pdf")
        XCTAssertNil(recreated.pdfAnchor, "Changed PDF bytes start at the top")
    }

    func testInitialLayoutDoesNotReplaceSavedPositionBeforeRestoration() async throws {
        let directory = try temporaryDirectory()
        let pdfURL = directory.appendingPathComponent("report.pdf")
        try writePDF(pages: 4, to: pdfURL)
        let position = DocumentReadingPosition(), saved = SavedReadingPosition.Anchor(kind: "pdf-page", ordinal: 2)
        position.pdfAnchor = saved
        let state = PDFFixtureState(document: try XCTUnwrap(PDFDocument(url: pdfURL)), restoration: saved, position: position)
        let window = try host(state)
        // Capturing before the asynchronous restoration must not record page 1.
        position.capturePDFPosition?()
        XCTAssertEqual(position.pdfAnchor, saved)
        try await waitUntil({ self.pdfView(window)?.isRestored == true })
        position.capturePDFPosition?()
        XCTAssertEqual(position.pdfAnchor?.ordinal, 2)

        // Replacing the document restarts restoration for the new document.
        try writePDF(pages: 3, label: "Other", to: pdfURL)
        state.restoration = nil
        state.document = try XCTUnwrap(PDFDocument(url: pdfURL))
        try await waitUntil({ self.pdfView(window).map { $0.isRestored && $0.document === state.document } == true })
        XCTAssertEqual(pdfView(window)?.readingAnchor()?.ordinal, 0)
    }

    func testSearchPageWinsOnceAndMissingPagesFallBack() {
        let saved = SavedReadingPosition.Anchor(kind: "pdf-page", ordinal: 4, fraction: 0.3)
        XCTAssertEqual(RemoteMediaView.pdfRestoration(openingPage: 2, saved: saved, pageCount: 6),
                       .init(kind: "pdf-page", ordinal: 1))
        XCTAssertEqual(RemoteMediaView.pdfRestoration(openingPage: nil, saved: saved, pageCount: 6), saved)
        XCTAssertEqual(RemoteMediaView.pdfRestoration(openingPage: 9, saved: saved, pageCount: 6), saved,
                       "A stale result page beyond the current document falls back to history")
        XCTAssertNil(RemoteMediaView.pdfRestoration(openingPage: nil, saved: saved, pageCount: 4),
                     "Saved pages beyond a shorter document open at the top")
        XCTAssertNil(RemoteMediaView.pdfRestoration(openingPage: nil, saved: .init(kind: "prose", ordinal: 1), pageCount: 6))
    }

    func testDemoPDFReadingDoesNotCreatePersistentHistory() async throws {
        let directory = try temporaryDirectory()
        let pdfURL = directory.appendingPathComponent("sample.pdf")
        try writePDF(pages: 2, to: pdfURL)
        let model = try AppModel(directory: directory)
        await model.setDemo(true)
        let profile = try XCTUnwrap(model.metadata.connections.first)
        let position = DocumentReadingPosition()
        let prepared = await model.preparePDFReadingPosition(position, fileURL: pdfURL, profile: profile, path: "/Projects/sample.pdf")
        XCTAssertTrue(prepared)
        position.pdfAnchor = .init(kind: "pdf-page", ordinal: 1)
        await position.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("reading-positions-v1.json").path))
    }
}
#endif
