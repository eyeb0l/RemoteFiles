#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import RemoteFilesCore
@testable import RemoteFilesUI
@testable import Textual

@MainActor @Observable private final class ReadingFixtureState {
    var path: [Int] = []
    var source = false
    var version = 0
    var text = DemoRemoteFileService.navigationGuide
    var paragraphGap: CGFloat?
    let position = DocumentReadingPosition()
}

private struct ReadingFixtureParagraphStyle: StructuredText.ParagraphStyle {
    let gap: CGFloat?
    func makeBody(configuration: Configuration) -> some View {
        if let gap {
            configuration.label.padding(.top, gap)
                // Avoid UIKit/SwiftUI preferred spacing changing with padding.
                // The regression changes only the two explicit paragraph gaps.
                .textual.blockSpacing(.init(top: 0, bottom: 0))
        }
        else { StructuredText.DefaultParagraphStyle().makeBody(configuration: configuration) }
    }
}

private struct ReadingPositionFixture: View {
    @Bindable var state: ReadingFixtureState
    var body: some View {
        NavigationStack(path: $state.path) {
            DocumentContentView(text: state.text, markdown: true,
                                source: state.source, filename: "guide.md", readingPosition: state.position)
                .id(state.version)
                .textual.paragraphStyle(ReadingFixtureParagraphStyle(gap: state.paragraphGap))
                .navigationTitle("Reading fixture")
                .navigationDestination(for: Int.self) { _ in Text("Linked note marker").navigationTitle("Linked note") }
        }
    }
}

@MainActor final class DocumentReadingPositionTests: XCTestCase {
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private func scrollView(_ window: UIWindow) -> UIScrollView? {
        views(window).compactMap { $0 as? UIScrollView }.filter {
            // Select the active viewport, never a UITextView used for source selection.
            $0.isScrollEnabled && !($0 is UITextView) && $0.window === window &&
            !$0.isHidden && $0.alpha > 0.01 && $0.bounds.height > 200 &&
            $0.contentSize.height > $0.bounds.height * 2 &&
            $0.convert($0.bounds, to: window).intersection(window.bounds).height > 200
        }.max { $0.bounds.height < $1.bounds.height }
    }
    private func describeScrollViews(_ window: UIWindow) -> String {
        views(window).compactMap { $0 as? UIScrollView }.map {
            "\(type(of: $0)) enabled=\($0.isScrollEnabled) hidden=\($0.isHidden) " +
            "bounds=\($0.bounds) content=\($0.contentSize) offset=\($0.contentOffset) " +
            "label=\($0.accessibilityLabel ?? "nil")"
        }.joined(separator: "\n")
    }
    private func waitUntil(_ condition: () -> Bool, diagnostics: (() -> String)? = nil,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for reader scroll state\n" + (diagnostics?() ?? ""), file: file, line: line)
    }
    private func host(_ state: ReadingFixtureState) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ReadingPositionFixture(state: state))
        window.makeKeyAndVisible()
        return window
    }
    private func offset(_ scroll: UIScrollView) -> CGPoint {
        .init(x: scroll.contentOffset.x + scroll.adjustedContentInset.left,
              y: scroll.contentOffset.y + scroll.adjustedContentInset.top)
    }
    private func scroll(_ window: UIWindow, to value: CGPoint, saved: @escaping () -> CGPoint) async throws {
        try await waitUntil { self.scrollView(window) != nil }
        await Task.yield()
        let native = try XCTUnwrap(scrollView(window))
        native.setContentOffset(.init(x: value.x - native.adjustedContentInset.left,
                                     y: value.y - native.adjustedContentInset.top), animated: false)
        try await waitUntil({ abs(saved().y - value.y) < 2 }, diagnostics: {
            "Expected saved=\(value), actual=\(saved())\n" + self.describeScrollViews(window)
        })
    }
    private func assertRestored(_ window: UIWindow, to expected: CGPoint) async throws {
        try await waitUntil({
            guard let scroll = self.scrollView(window) else { return false }
            return abs(self.offset(scroll).y - expected.y) < 2 && abs(self.offset(scroll).x - expected.x) < 2
        }, diagnostics: { "Expected restored=\(expected)\n" + self.describeScrollViews(window) })
    }
    private func switchMode(_ state: ReadingFixtureState, toSource source: Bool,
                            in window: UIWindow) async throws {
        let previous = scrollView(window)
        state.source = source
        // Wait for the conditional branch to mount its own viewport. The old rendered
        // scroll view can remain in the hierarchy during the source mode transition.
        try await waitUntil({ self.scrollView(window).map { $0 !== previous } ?? false },
                            diagnostics: { self.describeScrollViews(window) })
    }

    func testRenderedReaderPreservesActualScrollAcrossPushBackAndContentRemount() async throws {
        let state = ReadingFixtureState()
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        let expected = CGPoint(x: 0, y: 1_100)
        try await scroll(window, to: expected, saved: { state.position.rendered })
        state.path = [1]
        try await Task.sleep(for: .milliseconds(350))
        state.path = []
        try await assertRestored(window, to: expected)
        // Refresh replaces the content subtree. The route still owns its coordinates.
        let oldScroll = scrollView(window)
        state.version += 1
        try await waitUntil { self.scrollView(window).map { $0 !== oldScroll } ?? false }
        try await assertRestored(window, to: expected)
        XCTAssertEqual(state.position.rendered.y, expected.y, accuracy: 2)
    }

    private func textInteractionOverlay(_ window: UIWindow) -> UITextInteractionView? {
        views(window).compactMap { $0 as? UITextInteractionView }.first {
            $0.window === window && !$0.isHidden && $0.bounds.width > 100 && $0.bounds.height > 50
        }
    }
    private func linkPoint(in overlay: UITextInteractionView, reference: String) -> CGPoint? {
        // Inspect the production hit map at native coordinates, without invoking openURL
        // directly or substituting a test layout. This short fixture has only three blocks.
        for y in stride(from: CGFloat(0), through: overlay.bounds.maxY, by: 4) {
            for x in stride(from: CGFloat(0), through: overlay.bounds.maxX, by: 8) {
                let point = CGPoint(x: x, y: y)
                if overlay.model.url(for: point)?.absoluteString == reference { return point }
            }
        }
        return nil
    }
    private func assertParentLinkHitMap(_ window: UIWindow) async throws {
        let reference = "../Navigation%20guide.md"
        try await waitUntil({
            guard let overlay = self.textInteractionOverlay(window) else { return false }
            return self.linkPoint(in: overlay, reference: reference) != nil
        }, diagnostics: { "The short rendered document's actual native overlay has no parent-link hit map" })
        let overlay = try XCTUnwrap(textInteractionOverlay(window))
        let point = try XCTUnwrap(linkPoint(in: overlay, reference: reference))
        XCTAssertEqual(overlay.model.url(for: point)?.absoluteString, reference)
        XCTAssertFalse(overlay.isAccessibilityElement)
        XCTAssertTrue(overlay.accessibilityElementsHidden,
                      "The selection overlay must not duplicate the accessible rendered text/link")
    }

    func testShortRenderedDocumentHandsCurrentLinkLayoutToNativeOverlay() async throws {
        let state = ReadingFixtureState()
        state.text = DemoRemoteFileService.linkedNotes
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        try await assertParentLinkHitMap(window)
        state.path = [1]
        try await Task.sleep(for: .milliseconds(350))
        state.path = []
        try await assertParentLinkHitMap(window)
        let oldOverlay = textInteractionOverlay(window)
        state.version += 1
        try await waitUntil { self.textInteractionOverlay(window).map { $0 !== oldOverlay } ?? false }
        try await assertParentLinkHitMap(window)
    }

    func testShortDocumentRefreshesLinkHitCoordinatesAfterParagraphLayoutShift() async throws {
        let state = ReadingFixtureState()
        state.text = DemoRemoteFileService.linkedNotes
        state.paragraphGap = 0
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        try await assertParentLinkHitMap(window)
        let overlay = try XCTUnwrap(textInteractionOverlay(window))
        let reference = "../Navigation%20guide.md"
        let oldPoint = try XCTUnwrap(linkPoint(in: overlay, reference: reference))
        let oldHeight = overlay.bounds.height
        state.paragraphGap = 48
        // Two paragraph boxes gain 48 points each. Their text/layout anchors persist;
        // the parent link's actual position must move while the same model stays alive.
        try await waitUntil({
            guard let current = self.textInteractionOverlay(window), current === overlay,
                  current.bounds.height >= oldHeight + 90,
                  let point = self.linkPoint(in: current, reference: reference) else { return false }
            return abs(point.y - oldPoint.y - 96) <= 4
        }, diagnostics: {
            "Expected parent hit point to move96pt from \(oldPoint); actual=\(String(describing: self.linkPoint(in: overlay, reference: reference))) bounds=\(overlay.bounds)"
        })
        XCTAssertTrue(textInteractionOverlay(window) === overlay, "Layout changes must update the existing selection overlay")
        let newPoint = try XCTUnwrap(linkPoint(in: overlay, reference: reference))
        XCTAssertEqual(newPoint.y, oldPoint.y + 96, accuracy: 4)
        XCTAssertNil(overlay.model.url(for: oldPoint), "The stale pre-layout hit coordinate must no longer open the parent link")
        XCTAssertEqual(overlay.model.url(for: newPoint)?.absoluteString, reference)
    }

    func testSourceAndRenderedModesKeepIndependentActualScrollPositions() async throws {
        let state = ReadingFixtureState()
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        let rendered = CGPoint(x: 0, y: 900)
        let source = CGPoint(x: 0, y: 400)
        try await scroll(window, to: rendered, saved: { state.position.rendered })
        try await switchMode(state, toSource: true, in: window)
        try await scroll(window, to: source, saved: { state.position.source })
        try await switchMode(state, toSource: false, in: window)
        try await assertRestored(window, to: rendered)
        try await switchMode(state, toSource: true, in: window)
        try await assertRestored(window, to: source)
        state.path = [1]
        try await Task.sleep(for: .milliseconds(350))
        state.path = []
        try await assertRestored(window, to: source)
    }
}
#endif
