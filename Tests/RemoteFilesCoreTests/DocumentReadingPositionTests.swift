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
    var wrapLines = true
    var version = 0
    var text = DemoRemoteFileService.navigationGuide
    var typeSize = DynamicTypeSize.large
    var width: CGFloat?
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
                                source: state.source, filename: "guide.md", readingPosition: state.position, wrapLines: state.wrapLines)
                .environment(\.dynamicTypeSize, state.typeSize)
                .frame(width: state.width)
                .id(state.version)
                .textual.paragraphStyle(ReadingFixtureParagraphStyle(gap: state.paragraphGap))
                .navigationTitle("Reading fixture")
                .navigationDestination(for: Int.self) { _ in Text("Linked note marker").navigationTitle("Linked note") }
        }
    }
}

@MainActor final class DocumentReadingPositionTests: XCTestCase {
    func testPersistenceRecreatesModesAndResetsForChangedContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), id = UUID()
        let original = DocumentReadingPosition()
        await original.prepare(text: "original report", store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/report.md")
        original.rendered = CGPoint(x: 0, y: 720)
        original.source = CGPoint(x: 12, y: 280)
        await original.flush()
        let recreated = DocumentReadingPosition()
        await recreated.prepare(text: "original report", store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/report.md")
        XCTAssertEqual(recreated.rendered, original.rendered)
        XCTAssertEqual(recreated.source, original.source)
        await recreated.prepare(text: "changed report", store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/report.md")
        XCTAssertEqual(recreated.rendered, .zero)
        XCTAssertEqual(recreated.source, .zero)
        await recreated.flush()
        let changed = DocumentReadingPosition()
        await changed.prepare(text: "changed report", store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/report.md")
        XCTAssertEqual(changed.rendered, .zero)
    }

    func testPersistedRenderedAnchorRestoresPassageAtDifferentWidth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), id = UUID()
        let first = ReadingFixtureState(); first.width = 360
        await first.position.prepare(text: first.text, store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/guide.md")
        let window = try host(first)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await scroll(window, to: CGPoint(x: 0, y: 980), saved: { first.position.rendered })
        let anchor = try XCTUnwrap(first.position.overflowGeometry.snapshot)
        XCTAssertEqual(anchor.kind, "prose")
        await first.position.flush()
        window.isHidden = true; window.rootViewController = nil
        let next = ReadingFixtureState(); next.width = 240; next.typeSize = .xxxLarge
        await next.position.prepare(text: next.text, store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/guide.md")
        let nextWindow = try host(next)
        defer { nextWindow.isHidden = true; nextWindow.rootViewController = nil }
        try await waitUntil({
            guard let scroll = self.scrollView(nextWindow) else { return false }
            let overlays = self.views(scroll).compactMap { $0 as? UITextInteractionView }
            guard overlays.indices.contains(anchor.ordinal) else { return false }
            let overlay = overlays[anchor.ordinal]
            guard let position = overlay.model.position(from: overlay.model.startPosition, offset: anchor.character) else { return false }
            let rect = overlay.convert(overlay.model.caretRect(for: position), to: nextWindow)
            let viewport = scroll.convert(scroll.bounds, to: nextWindow)
            return abs(rect.minY - viewport.minY - anchor.viewportY) < 4
        }, diagnostics: { self.describeScrollViews(nextWindow) })
        try await waitUntil { !next.position.overflowGeometry.isRestoringReadingAnchor }
        XCTAssertNotEqual(next.position.rendered.y, 980, "The passage, rather than its old pixel coordinate, must be restored")
        let liveAnchor = try XCTUnwrap(next.position.overflowGeometry.snapshot)
        next.width = 320; next.typeSize = .large
        try await waitUntil({
            guard let scroll = self.scrollView(nextWindow) else { return false }
            let overlays = self.views(scroll).compactMap { $0 as? UITextInteractionView }
            guard overlays.indices.contains(liveAnchor.ordinal) else { return false }
            let overlay = overlays[liveAnchor.ordinal]
            guard let position = overlay.model.position(from: overlay.model.startPosition, offset: liveAnchor.character) else { return false }
            let rect = overlay.convert(overlay.model.caretRect(for: position), to: nextWindow)
            let viewport = scroll.convert(scroll.bounds, to: nextWindow)
            return abs(scroll.bounds.width - 320) < 1 && abs(rect.minY - viewport.minY - liveAnchor.viewportY) < 4
        }, diagnostics: { self.describeScrollViews(nextWindow) })
    }

    func testPersistedSourceAnchorRestoresCharacterAtDifferentWidth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), id = UUID()
        let first = ReadingFixtureState(); first.width = 360; first.source = true
        await first.position.prepare(text: first.text, store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/guide.md")
        let window = try host(first)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await scroll(window, to: CGPoint(x: 0, y: 980), saved: { first.position.source })
        let anchor = try XCTUnwrap(first.position.sourceAnchor)
        await first.position.flush()
        window.isHidden = true; window.rootViewController = nil
        let next = ReadingFixtureState(); next.width = 240; next.source = true; next.typeSize = .xxxLarge
        await next.position.prepare(text: next.text, store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/guide.md")
        let nextWindow = try host(next)
        defer { nextWindow.isHidden = true; nextWindow.rootViewController = nil }
        try await waitUntil({
            guard let view = self.scrollView(nextWindow) as? SourceTextView, !view.restoreAnchor,
                  let position = view.position(from: view.beginningOfDocument, offset: anchor.character) else { return false }
            return abs(view.caretRect(for: position).minY - view.contentOffset.y - anchor.viewportY) < 4
        }, diagnostics: { self.describeScrollViews(nextWindow) })
        XCTAssertNotEqual(next.position.source.y, 980)
        let liveAnchor = try XCTUnwrap(next.position.sourceAnchor)
        next.width = 320; next.typeSize = .large
        try await waitUntil({
            guard let view = self.scrollView(nextWindow) as? SourceTextView, !view.restoreAnchor,
                  let position = view.position(from: view.beginningOfDocument, offset: liveAnchor.character) else { return false }
            return abs(view.bounds.width - 320) < 1 && abs(view.caretRect(for: position).minY - view.contentOffset.y - liveAnchor.viewportY) < 4
        }, diagnostics: { self.describeScrollViews(nextWindow) })
    }

    func testNonTouchSourceScrollIsSavedAndRestoredAcrossModeSwitch() async throws {
        let state = ReadingFixtureState(); state.source = true
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { self.scrollView(window) is SourceTextView }
        let view = try XCTUnwrap(scrollView(window) as? SourceTextView)
        try await waitUntil { view.pendingOffset == nil && !view.restoreAnchor }
        XCTAssertFalse(view.isDragging); XCTAssertFalse(view.isDecelerating)
        // Accessibility page scrolling uses native scrolling without touch flags.
        // Exercise its animated completion through the actual UIScrollView delegate.
        view.setContentOffset(CGPoint(x: 0, y: 600), animated: true)
        try await waitUntil { abs(state.position.source.y - 600) < 2 }
        XCTAssertNotNil(state.position.sourceAnchor)
        try await switchMode(state, toSource: false, in: window)
        try await switchMode(state, toSource: true, in: window)
        try await assertRestored(window, to: CGPoint(x: 0, y: 600))
    }

    func testUnwrappedSourceAnchorClampsHorizontalOffsetAfterLayoutShrinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), id = UUID()
        let text = (0..<100).map { "row \($0) " + String(repeating: "abcdefghij", count: 8) }.joined(separator: "\n")
        let first = ReadingFixtureState()
        first.source = true; first.wrapLines = false; first.width = 240; first.typeSize = .xxxLarge; first.text = text
        await first.position.prepare(text: text, store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/guide.md")
        let window = try host(first)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { self.scrollView(window) is SourceTextView }
        let native = try XCTUnwrap(scrollView(window) as? SourceTextView)
        let oldX = native.contentSize.width - native.bounds.width
        XCTAssertGreaterThan(oldX, 500)
        try await scroll(window, to: CGPoint(x: oldX, y: 600), saved: { first.position.source })
        XCTAssertNotNil(first.position.sourceAnchor)
        await first.position.flush()
        window.isHidden = true; window.rootViewController = nil
        let next = ReadingFixtureState()
        next.source = true; next.wrapLines = false; next.width = 360; next.typeSize = .small; next.text = text
        await next.position.prepare(text: text, store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/guide.md")
        let nextWindow = try host(next)
        defer { nextWindow.isHidden = true; nextWindow.rootViewController = nil }
        try await waitUntil {
            guard let view = self.scrollView(nextWindow) as? SourceTextView else { return false }
            return view.pendingOffset == nil && !view.restoreAnchor
        }
        let restored = try XCTUnwrap(scrollView(nextWindow) as? SourceTextView)
        let maxX = max(0, restored.contentSize.width - restored.bounds.width)
        XCTAssertLessThan(maxX, oldX - 100, "The saved offset must exceed the new horizontal range")
        XCTAssertGreaterThanOrEqual(restored.contentOffset.x, 0)
        XCTAssertLessThanOrEqual(restored.contentOffset.x, maxX + 1)
        XCTAssertLessThanOrEqual(next.position.source.x, maxX + 1)
    }

    func testMemoryWarningAndInactivityReleaseAttributedKeysButRetainAnchor() async throws {
        let state = ReadingFixtureState()
        state.text = String(repeating: "Paragraph before code.\n\n```swift\nlet value = 42\n```\n\n", count: 80)
        let window = try host(state)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { state.position.overflowGeometry.retainedExtentCount > 0 }
        let cache = state.position.overflowGeometry
        XCTAssertLessThanOrEqual(cache.retainedExtentCount, 64)
        XCTAssertLessThanOrEqual(cache.retainedExtentCost, 2 * 1024 * 1024)
        cache.snapshot = .init(kind: "prose", ordinal: 0, character: 20, fraction: 0, viewportY: 40)
        let anchor = cache.snapshot
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await waitUntil { cache.retainedExtentCount == 0 }
        XCTAssertEqual(cache.snapshot, anchor)
        XCTAssertNotNil(scrollView(window), "Memory pressure must leave the active document readable")
        cache.releaseInactiveContent()
        XCTAssertEqual(cache.retainedExtentCount, 0)
        XCTAssertEqual(cache.retainedExtentCost, 0)
        XCTAssertEqual(cache.snapshot, anchor)
        let navigation = ReaderNavigationState()
        await navigation.prepare(text: state.text, markdown: true)
        XCTAssertNotNil(navigation.index)
        navigation.clear()
        XCTAssertNil(navigation.index)
    }

    func testDemoReadingDoesNotCreatePersistentHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory)
        await model.setDemo(true)
        let profile = try XCTUnwrap(model.metadata.connections.first)
        let position = DocumentReadingPosition()
        await model.prepareReadingPosition(position, text: "demo", profile: profile, path: "/Projects/report.md")
        position.rendered = CGPoint(x: 0, y: 420)
        await position.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("reading-positions-v1.json").path))
    }

    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private func scrollView(_ window: UIWindow) -> UIScrollView? {
        views(window).compactMap { $0 as? UIScrollView }.filter {
            // Select the active viewport, never a UITextView used for source selection.
            $0.isScrollEnabled && $0.window === window &&
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
        (native as? SourceTextView)?.captureReadingAnchor()
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

    func testRecreatedReaderRestoresActualRenderedAndSourceViewportsFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), id = UUID()
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let first = ReadingFixtureState()
        await first.position.prepare(text: first.text, store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/guide.md")
        let firstWindow = try host(first)
        defer { firstWindow.isHidden = true; firstWindow.rootViewController = nil; previousWindow?.makeKey() }
        let rendered = CGPoint(x: 0, y: 980), source = CGPoint(x: 0, y: 420)
        try await scroll(firstWindow, to: rendered, saved: { first.position.rendered })
        try await switchMode(first, toSource: true, in: firstWindow)
        try await scroll(firstWindow, to: source, saved: { first.position.source })
        await first.position.flush()
        firstWindow.isHidden = true; firstWindow.rootViewController = nil
        // A fresh route, position object, store and native viewport imitate a later launch.
        let recreated = ReadingFixtureState()
        let recreatedStore = ReadingPositionStore(fileURL: file)
        let persisted = await recreatedStore.restore(connectionID: id, path: "/guide.md", revision: SavedReadingPosition.revision(for: recreated.text))
        XCTAssertEqual(try XCTUnwrap(persisted).rendered.y, Double(rendered.y), accuracy: 2, "Disk restoration must succeed before the cold viewport mounts")
        XCTAssertEqual(try XCTUnwrap(persisted).source.y, Double(source.y), accuracy: 2)
        await recreated.position.prepare(text: recreated.text, store: recreatedStore, connectionID: id, path: "/guide.md")
        XCTAssertEqual(recreated.position.rendered.y, rendered.y, accuracy: 2, "The cold reader must mount with the restored coordinate")
        XCTAssertEqual(recreated.position.source.y, source.y, accuracy: 2)
        let secondWindow = try host(recreated)
        defer {
            firstWindow.isHidden = true; firstWindow.rootViewController = nil
            secondWindow.isHidden = true; secondWindow.rootViewController = nil; previousWindow?.makeKey()
        }
        try await waitUntil({
            guard let scroll = self.scrollView(secondWindow) else { return false }
            return abs(self.offset(scroll).y - rendered.y) < 2
        }, diagnostics: {
            "Cold restore expected=\(rendered), saved=\(recreated.position.rendered)\n" + self.describeScrollViews(secondWindow)
        })
        XCTAssertEqual(recreated.position.rendered.y, rendered.y, accuracy: 2)
        try await switchMode(recreated, toSource: true, in: secondWindow)
        try await assertRestored(secondWindow, to: source)
        await recreated.position.flush()
    }

    func testRecreatedShortUnwrappedSourceRestoresActualHorizontalAndVerticalOffsets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), id = UUID()
        let text = (0..<120).map { "row \($0) " + String(repeating: "1234567890 ", count: 25) }.joined(separator: "\r\n")
        XCTAssertFalse(SourceLayout.needsBoundedLayout(text), "This must exercise ordinary short unwrapped source")
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let first = ReadingFixtureState()
        first.text = text; first.source = true; first.wrapLines = false
        await first.position.prepare(text: text, store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/guide.md")
        let firstWindow = try host(first)
        defer { firstWindow.isHidden = true; firstWindow.rootViewController = nil; previousWindow?.makeKey() }
        let expected = CGPoint(x: 900, y: 600)
        try await waitUntil({
            guard let scroll = self.scrollView(firstWindow) else { return false }
            return scroll.contentSize.width > expected.x + scroll.bounds.width
        }, diagnostics: { self.describeScrollViews(firstWindow) })
        try await scroll(firstWindow, to: expected, saved: { first.position.source })
        XCTAssertEqual(first.position.source.x, expected.x, accuracy: 2)
        await first.position.flush()
        firstWindow.isHidden = true; firstWindow.rootViewController = nil
        let recreated = ReadingFixtureState()
        recreated.text = text; recreated.source = true; recreated.wrapLines = false
        await recreated.position.prepare(text: text, store: ReadingPositionStore(fileURL: file), connectionID: id, path: "/guide.md")
        XCTAssertEqual(recreated.position.source.x, expected.x, accuracy: 2)
        XCTAssertEqual(recreated.position.source.y, expected.y, accuracy: 2)
        let secondWindow = try host(recreated)
        defer { secondWindow.isHidden = true; secondWindow.rootViewController = nil; previousWindow?.makeKey() }
        try await assertRestored(secondWindow, to: expected)
        XCTAssertEqual(recreated.position.source.x, expected.x, accuracy: 2)
        XCTAssertEqual(recreated.position.source.y, expected.y, accuracy: 2)
        await recreated.position.flush()
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
