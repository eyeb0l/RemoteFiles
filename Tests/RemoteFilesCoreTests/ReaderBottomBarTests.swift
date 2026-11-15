#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import WebKit
@testable import RemoteFilesUI
import RemoteFilesCore

@MainActor @Observable private final class BottomBarProbe {
    /// Stands for any reader state that isn't the reading mode, such as `loading` or `loadedAt`.
    var revision = 0
    var rendered = -1
    var source = false
}

/// Reports each SwiftUI update pass that has reached UIKit.
private struct RevisionMarker: UIViewRepresentable {
    let revision: Int
    let probe: BottomBarProbe
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        let revision = revision
        Task { @MainActor in probe.rendered = revision }
    }
}

private struct RevisionKey: EnvironmentKey { static let defaultValue = 0 }
private extension EnvironmentValues {
    var readerRevision: Int {
        get { self[RevisionKey.self] }
        set { self[RevisionKey.self] = newValue }
    }
}

/// Like the reader, the mode is view state, other state re-evaluates the body that owns the bar,
/// and the bar's actions capture that view, so each evaluation makes a bar SwiftUI sees as new.
/// The changing environment value updates the control however the bar is composed.
private struct BottomBarFixture: View {
    let probe: BottomBarProbe
    @State private var source = false
    @State private var finds = 0
    var body: some View {
        NavigationStack {
            Text("Revision \(probe.revision)")
                .background { RevisionMarker(revision: probe.revision, probe: probe) }
                .toolbar {
                    ReaderBottomBar(findTitle: "Find in Document", find: { finds += 1 }, headings: { finds += 1 }, source: $source)
                }
                .environment(\.readerRevision, probe.revision)
        }
        .onChange(of: source) { _, value in probe.source = value }
    }
}

@MainActor final class ReaderBottomBarTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func waitUntil(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
        throw NSError(domain: "ReaderBottomBarTests", code: 1)
    }

    /// UIKit changes a segmented control's selection when the touch ends, and sends its action only
    /// after the next Core Animation commit. A reader update in between must not put the old mode
    /// back; see "Source-mode tap" in docs/CI_HISTORY.md.
    func testReaderUpdateBeforeThePendingActionKeepsTheChosenReadingMode() async throws {
        let probe = BottomBarProbe()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: BottomBarFixture(probe: probe))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        func modes() -> UISegmentedControl? {
            descendants(window).compactMap { $0 as? UISegmentedControl }.first { $0.numberOfSegments == 2 && $0.window === window }
        }
        try await waitUntil("the reading-mode control") { modes()?.selectedSegmentIndex == 0 && probe.rendered == 0 }
        let control = try XCTUnwrap(modes())
        XCTAssertEqual(control.titleForSegment(at: 1), "Source")

        for round in 1...3 {
            let chosen = round % 2, before = probe.revision
            control.selectedSegmentIndex = chosen
            probe.revision += 1
            try await waitUntil("the reader update to reach UIKit") { probe.rendered == before + 1 }
            // The bar's own hosting view may update a turn after the content's.
            try await Task.sleep(for: .milliseconds(100))
            control.sendActions(for: .valueChanged)
            try await waitUntil("reading mode \(chosen) in round \(round), control at \(control.selectedSegmentIndex)") {
                probe.source == (chosen == 1) && control.selectedSegmentIndex == chosen
            }
        }
    }

    /// The source, HTML and rich Markdown readers run under the bar to the bottom edge. Their own
    /// UIKit safe area leaves out SwiftUI's bottom bar, so without the full inset the end of a
    /// document stayed behind the bar however far it was scrolled.
    func testDocumentEndsScrollClearOfTheBottomBar() async throws {
        let lines = (1...200).map { "Line \($0)" }
        let documents: [(name: String, text: String, scrollView: (UIView) -> UIScrollView?)] = [
            ("source.txt", lines.joined(separator: "\n"), { $0 as? SourceTextView }),
            ("page.html", "<!doctype html><p>" + lines.joined(separator: "<br>") + "</p>", { ($0 as? WKWebView)?.scrollView }),
            ("rich.md", "Inline math: $x^2$.\n\n" + lines.joined(separator: "\n\n"), { ($0 as? WKWebView)?.scrollView }),
        ]
        for document in documents {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = try AppModel(directory: directory, fileService: FixedFileService(text: document.text))
            let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "fixture", identityID: UUID(), startingDirectory: "/")
            model.metadata.connections = [profile]
            let entry = RemoteEntry(name: document.name, path: "/" + document.name, kind: .file)
            let probe = BottomEdgeProbe()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousWindow = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                ZStack {
                    // Fills only what the bar and home indicator leave uncovered.
                    Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { probe.uncoveredMaxY = $0 }
                    ReaderView(model: model, profile: profile, entry: entry)
                }
            })
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
            func scroll() -> UIScrollView? {
                descendants(window).lazy.compactMap(document.scrollView).first { $0.window === window }
            }
            try await waitUntil("the \(document.name) reader") { scroll() != nil && probe.uncoveredMaxY > 0 }
            let view = try XCTUnwrap(scroll())
            // Where the content ends when scrolled as far as it goes.
            func contentEnd() -> CGFloat { view.convert(view.bounds, to: nil).maxY - view.adjustedContentInset.bottom }
            try await waitUntil("the end of \(document.name) above the bar") { abs(contentEnd() - probe.uncoveredMaxY) < 1 }
            // The reader still runs under the bar, which covers more than its UIKit safe area.
            let reader = view.superview as? WKWebView ?? view
            XCTAssertEqual(view.convert(view.bounds, to: nil).maxY, window.bounds.maxY, accuracy: 1, document.name)
            XCTAssertGreaterThan(window.bounds.maxY - probe.uncoveredMaxY, reader.safeAreaInsets.bottom + 20, document.name)
        }
    }

    func testAModeChangedElsewhereStillMovesTheControl() async throws {
        let probe = BottomBarProbe()
        let state = ModeState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ExternalModeFixture(state: state, probe: probe)
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        func modes() -> UISegmentedControl? {
            descendants(window).compactMap { $0 as? UISegmentedControl }.first { $0.numberOfSegments == 2 && $0.window === window }
        }
        try await waitUntil("the reading-mode control") { modes()?.selectedSegmentIndex == 0 }
        // The keyboard shortcut, Find in an HTML document and a heading link all set the mode.
        state.source = true
        try await waitUntil("Source selected by the model") { modes()?.selectedSegmentIndex == 1 }
        state.source = false
        try await waitUntil("Rendered selected by the model") { modes()?.selectedSegmentIndex == 0 }
    }
}

@MainActor @Observable private final class BottomEdgeProbe { var uncoveredMaxY: CGFloat = 0 }
private struct FixedFileService: RemoteFileService {
    let text: String
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { Data(text.utf8) }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() async {}
}

@MainActor @Observable private final class ModeState { var source = false }
private struct ExternalModeFixture: View {
    @Bindable var state: ModeState
    let probe: BottomBarProbe
    var body: some View {
        Text("Document")
            .toolbar { ReaderBottomBar(findTitle: "Find in Document", find: {}, headings: nil, source: $state.source) }
    }
}
#endif
