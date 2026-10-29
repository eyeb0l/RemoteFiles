#if os(iOS)
import XCTest
import UIKit
import WebKit
import RemoteFilesCore
@testable import RemoteFilesUI

@MainActor final class HTMLReadingPositionTests: XCTestCase {
    private var prose: String {
        "<p id='passage' style='margin:0;font-size:20px;line-height:1.5'>" +
        (0..<500).map { "Passage \($0): café 東京 🌍 e\u{301} remains readable after the viewport changes. " }.joined() + "</p>"
    }

    func testTextAnchorKeepsUnicodePassageAfterWidthAndFontChanges() async throws {
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        try await load(prose, in: fixture.view)
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 1700), animated: false)
        try await waitUntil { abs(try await self.number("window.scrollY", in: fixture.view) - 1700) < 2 }
        let captured = try await HTMLReadingAnchor.capture(in: fixture.view)
        let anchor = try XCTUnwrap(captured)
        XCTAssertEqual(anchor.kind, "html-text")
        XCTAssertGreaterThan(anchor.character, 0)
        let before = try await characterY(anchor.character, in: fixture.view)
        XCTAssertEqual(before, anchor.viewportY, accuracy: 3)

        let originalHeight = fixture.view.scrollView.contentSize.height
        fixture.view.frame.size.width = 240
        _ = try await evaluate("document.getElementById('passage').style.fontSize='27px'", in: fixture.view)
        try await waitUntil {
            let width = try await self.number("window.innerWidth", in: fixture.view)
            return abs(width - 240) < 2 && fixture.view.scrollView.contentSize.height > originalHeight * 1.4
        }
        let restored = try await HTMLReadingAnchor.restore(anchor, in: fixture.view)
        XCTAssertTrue(restored)
        try await waitUntil {
            abs(try await self.characterY(anchor.character, in: fixture.view) - anchor.viewportY) < 3
        }
        XCTAssertGreaterThan(abs(fixture.view.scrollView.contentOffset.y - 1700), 100,
                             "The character must follow reflow instead of restoring the old pixels")
    }

    func testTextAnchorRestoresAfterPageZoomChangesCSSPixelScale() async throws {
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        try await load(prose, in: fixture.view)
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 1700), animated: false)
        try await waitUntil { abs(try await self.number("window.scrollY", in: fixture.view) - 1700) < 2 }
        let captured = try await HTMLReadingAnchor.capture(in: fixture.view)
        let anchor = try XCTUnwrap(captured)
        XCTAssertEqual(anchor.kind, "html-text")
        fixture.view.pageZoom = 1.6
        try await waitUntil {
            try await self.number("window.visualViewport.width", in: fixture.view) < 300
        }
        let restored = try await HTMLReadingAnchor.restore(anchor, in: fixture.view)
        XCTAssertTrue(restored)
        try await waitUntil {
            abs(try await self.characterY(anchor.character, in: fixture.view) - anchor.viewportY) < 3
        }
    }

    func testVisualBlockAnchorKeepsItsProportionalPositionAfterResize() async throws {
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        try await load("""
        <svg id='picture' xmlns='http://www.w3.org/2000/svg' style='display:block;width:100%;height:3000px' viewBox='0 0 100 3000'>
        <rect width='100' height='3000' fill='#8050b0'/></svg>
        """, in: fixture.view)
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 1100), animated: false)
        try await waitUntil { abs(try await self.number("window.scrollY", in: fixture.view) - 1100) < 2 }
        let captured = try await HTMLReadingAnchor.capture(in: fixture.view)
        let anchor = try XCTUnwrap(captured)
        XCTAssertEqual(anchor.kind, "html-block")
        XCTAssertGreaterThan(anchor.fraction, 0)
        XCTAssertLessThan(anchor.fraction, 1)

        _ = try await evaluate("document.getElementById('picture').style.height='4500px'", in: fixture.view)
        try await waitUntil { fixture.view.scrollView.contentSize.height > 4400 }
        let restored = try await HTMLReadingAnchor.restore(anchor, in: fixture.view)
        XCTAssertTrue(restored)
        try await waitUntil {
            let point = try await self.number("""
            (() => { const rect=document.getElementById('picture').getBoundingClientRect();
            return rect.top + rect.height * \(anchor.fraction); })()
            """, in: fixture.view)
            return abs(point - anchor.viewportY) < 3
        }
        XCTAssertGreaterThan(fixture.view.scrollView.contentOffset.y, 1500)
    }

    func testMissingTextAnchorDoesNotInventAnotherPassage() async throws {
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        try await load(prose, in: fixture.view)
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 700), animated: false)
        try await waitUntil { abs(try await self.number("window.scrollY", in: fixture.view) - 700) < 2 }
        let invalid = SavedReadingPosition.Anchor(kind: "html-text", ordinal: 19_999, character: 20)
        let restored = try await HTMLReadingAnchor.restore(invalid, in: fixture.view)
        XCTAssertFalse(restored)
        XCTAssertEqual(fixture.view.scrollView.contentOffset.y, 700, accuracy: 2)
    }

    func testHiddenTextAnchorFallsBackWithoutMovingTheViewport() async throws {
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        try await load(prose, in: fixture.view)
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 700), animated: false)
        try await waitUntil { abs(try await self.number("window.scrollY", in: fixture.view) - 700) < 2 }
        let captured = try await HTMLReadingAnchor.capture(in: fixture.view)
        let anchor = try XCTUnwrap(captured)
        XCTAssertEqual(anchor.kind, "html-text")
        _ = try await evaluate("document.getElementById('passage').style.visibility='hidden'", in: fixture.view)
        let restored = try await HTMLReadingAnchor.restore(anchor, in: fixture.view)
        XCTAssertFalse(restored)
        XCTAssertEqual(fixture.view.scrollView.contentOffset.y, 700, accuracy: 2)
    }

    func testDOMBeyondTraversalBudgetKeepsCoordinateFallback() async throws {
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        // Hidden nodes still count toward the budget and preserve later node identities.
        // The visible passage lies beyond the entire bounded traversal.
        let source = String(repeating: "<span hidden></span>", count: 20_010) + prose
        try await load(source, in: fixture.view)
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 700), animated: false)
        try await waitUntil { abs(try await self.number("window.scrollY", in: fixture.view) - 700) < 2 }
        let captured = try await HTMLReadingAnchor.capture(in: fixture.view)
        XCTAssertNil(captured)
        XCTAssertEqual(fixture.view.scrollView.contentOffset.y, 700, accuracy: 2)
    }

    func testLegacyCoordinateHistoryRestoresThroughHTMLCoordinator() async throws {
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        let position = DocumentReadingPosition()
        position.rendered = CGPoint(x: 0, y: 700)
        let coordinator = StaticHTMLWebView.Coordinator(readingPosition: position,
            onFinish: { XCTAssertFalse($0) }, onFailure: { XCTFail($0) },
            openExternalLink: { _ in XCTFail("Loading must not open external links") })
        coordinator.attach(fixture.view)
        fixture.view.navigationDelegate = coordinator
        fixture.view.scrollView.delegate = coordinator
        coordinator.beginLoading(prose)
        coordinator.navigation = fixture.view.loadHTMLString(StaticHTMLWebView.html(prose), baseURL: nil)
        try await waitUntil(timeout: .seconds(30)) { coordinator.finishedLoading }
        try await waitUntil { abs(fixture.view.scrollView.contentOffset.y - 700) < 3 }
        XCTAssertEqual(position.source, .zero)
        StaticHTMLWebView.dismantleUIView(fixture.view, coordinator: coordinator)
    }

    func testCoordinatorRestoresPersistedPassageAtNewWidthAndAfterLiveResize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), connectionID = UUID()
        let first = DocumentReadingPosition()
        await first.prepare(text: prose, store: ReadingPositionStore(fileURL: file), connectionID: connectionID, path: "/report.html")
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        let coordinator = coordinate(fixture.view, position: first)
        try await waitUntil(timeout: .seconds(30)) { coordinator.finishedLoading && first.htmlAnchor != nil }
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 1700), animated: false)
        try await waitUntil { abs(first.rendered.y - 1700) < 2 && first.htmlAnchor?.kind == "html-text" }
        await first.flush()
        let anchor = try XCTUnwrap(first.htmlAnchor)
        coordinator.detach()
        fixture.close()

        let next = DocumentReadingPosition()
        await next.prepare(text: prose, store: ReadingPositionStore(fileURL: file), connectionID: connectionID, path: "/report.html")
        XCTAssertEqual(next.htmlAnchor, anchor)
        let replacement = try await host(width: 240)
        addTeardownBlock { @MainActor in replacement.close() }
        let replacementCoordinator = coordinate(replacement.view, position: next)
        defer { replacementCoordinator.detach() }
        try await waitUntil {
            guard replacementCoordinator.finishedLoading else { return false }
            return abs(try await self.characterY(anchor.character, in: replacement.view) - anchor.viewportY) < 3
        }
        XCTAssertGreaterThan(abs(replacement.view.scrollView.contentOffset.y - 1700), 100)
        try await waitUntil { abs(next.rendered.y - replacement.view.scrollView.contentOffset.y) < 2 && next.htmlAnchor != nil }
        let liveAnchor = try XCTUnwrap(next.htmlAnchor)

        // Exercise the production bounds callback, rather than calling restore directly.
        replacement.view.frame.size.width = 320
        replacement.view.layoutIfNeeded()
        try await waitUntil {
            let width = try await self.number("window.innerWidth", in: replacement.view)
            let y = try await self.characterY(liveAnchor.character, in: replacement.view)
            return abs(width - 320) < 2 && abs(y - liveAnchor.viewportY) < 3
        }
    }

    func testNonTouchScrollInterruptsPendingRestoration() async throws {
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        let position = DocumentReadingPosition()
        let coordinator = coordinate(fixture.view, position: position)
        defer { coordinator.detach() }
        try await waitUntil(timeout: .seconds(30)) { coordinator.finishedLoading && position.htmlAnchor != nil }
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 700), animated: false)
        try await waitUntil { abs(position.rendered.y - 700) < 2 }
        coordinator.restorePosition()
        XCTAssertFalse(fixture.view.scrollView.isDragging)
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 1300), animated: false)
        try await waitUntil { abs(position.rendered.y - 1300) < 2 }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fixture.view.scrollView.contentOffset.y, 1300, accuracy: 2)
        XCTAssertEqual(position.rendered.y, 1300, accuracy: 2)
    }

    func testReadinessWaitsForWebKitFirstCommitSoAnImmediateScrollIsKept() async throws {
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        let position = DocumentReadingPosition()
        var geometryAtReadiness: CGSize?
        let coordinator = coordinate(fixture.view, position: position) {
            XCTAssertFalse($0)
            geometryAtReadiness = fixture.view.scrollView.contentSize
        }
        defer { coordinator.detach() }
        try await waitUntil(timeout: .seconds(30)) { coordinator.finishedLoading }
        XCTAssertGreaterThan(try XCTUnwrap(geometryAtReadiness).height, fixture.view.bounds.height)
        // WebKit's first post-load layer-tree commit resets the native offset to the
        // top. It must already have been applied, rather than undo and record this scroll.
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 700), animated: false)
        try await waitUntil { abs(try await self.number("window.scrollY", in: fixture.view) - 700) < 2 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(fixture.view.scrollView.contentOffset.y, 700, accuracy: 2)
        XCTAssertEqual(position.rendered.y, 700, accuracy: 2)
    }

    func testReflowLeavesScrollingToAppAnchorsInsteadOfWebKitScrollAnchoring() async throws {
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        try await load(prose, in: fixture.view)
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 1700), animated: false)
        try await waitUntil { abs(try await self.number("window.scrollY", in: fixture.view) - 1700) < 2 }
        var webKitScrolls: [CGFloat] = []
        let observation = fixture.view.scrollView.observe(\.contentOffset, options: [.old, .new]) { _, change in
            guard let old = change.oldValue, let new = change.newValue, abs(old.y - new.y) >= 0.5 else { return }
            MainActor.assumeIsolated { webKitScrolls.append(new.y) }
        }
        defer { observation.invalidate() }
        let originalHeight = fixture.view.scrollView.contentSize.height
        fixture.view.frame.size.width = 240
        _ = try await evaluate("document.getElementById('passage').style.fontSize='27px'", in: fixture.view)
        try await waitUntil {
            let width = try await self.number("window.innerWidth", in: fixture.view)
            return abs(width - 240) < 2 && fixture.view.scrollView.contentSize.height > originalHeight * 1.4
        }
        try await Task.sleep(for: .milliseconds(500))
        // A WebKit-requested anchoring scroll can land after, and undo, a native restoration.
        XCTAssertEqual(webKitScrolls, [], "Reflow must not request a native scroll")
    }

    func testFailedInspectionFlushesNewCoordinatesInsteadOfStaleAnchor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), connectionID = UUID()
        let position = DocumentReadingPosition()
        await position.prepare(text: prose, store: ReadingPositionStore(fileURL: file), connectionID: connectionID, path: "/report.html")
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        try await load(prose, in: fixture.view)
        let coordinator = StaticHTMLWebView.Coordinator(readingPosition: position,
            onFinish: { _ in }, onFailure: { XCTFail($0) }, openExternalLink: { _ in })
        coordinator.attach(fixture.view)
        coordinator.finishedLoading = true
        fixture.view.scrollView.delegate = coordinator
        defer { coordinator.detach() }
        await position.flush()
        XCTAssertNotNil(position.htmlAnchor)
        // Fail the actual app-world DOM inspection without enabling document scripts
        // or replacing the native scrolling/persistence path with a test double.
        _ = try await evaluate("document.createTreeWalker = () => { throw new Error('fixture inspection unavailable'); }; true", in: fixture.view)
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        await position.flush()
        let saved = await ReadingPositionStore(fileURL: file).restore(connectionID: connectionID,
            path: "/report.html", revision: SavedReadingPosition.revision(for: prose))
        XCTAssertEqual(try XCTUnwrap(saved).rendered.y, 1200, accuracy: 2)
        XCTAssertNil(saved?.renderedAnchor, "An old semantic anchor must not override newer coordinates")
    }

    func testDetachFlushesLastNonTouchHTMLScroll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), connectionID = UUID()
        let store = ReadingPositionStore(fileURL: file)
        let position = DocumentReadingPosition()
        await position.prepare(text: prose, store: store, connectionID: connectionID, path: "/report.html")
        position.source = CGPoint(x: 0, y: 310)
        position.sourceAnchor = .init(kind: "source", character: 170, viewportY: 22)
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        let coordinator = coordinate(fixture.view, position: position)
        try await waitUntil(timeout: .seconds(30)) { coordinator.finishedLoading && position.htmlAnchor != nil }
        XCTAssertFalse(fixture.view.scrollView.isDragging)
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 850), animated: false)
        try await waitUntil { abs(try await self.number("window.scrollY", in: fixture.view) - 850) < 2 }
        coordinator.detach()
        let revision = SavedReadingPosition.revision(for: prose)
        try await waitUntil {
            let saved = await store.restore(connectionID: connectionID, path: "/report.html", revision: revision)
            return abs((saved?.rendered.y ?? 0) - 850) < 2 && saved?.renderedAnchor?.kind == "html-text"
        }
        let saved = await store.restore(connectionID: connectionID, path: "/report.html", revision: revision)
        XCTAssertEqual(saved?.source.y, 310)
        XCTAssertEqual(saved?.sourceAnchor, position.sourceAnchor)
    }

    func testReusedCoordinatorCapturesTheChangedRevisionAfterPreparationResetsItsSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), connectionID = UUID()
        let store = ReadingPositionStore(fileURL: file)
        let position = DocumentReadingPosition()
        await position.prepare(text: prose, store: store, connectionID: connectionID, path: "/report.html")
        position.source = CGPoint(x: 0, y: 310)
        position.sourceAnchor = .init(kind: "source", character: 170, viewportY: 22)
        let fixture = try await host()
        addTeardownBlock { @MainActor in fixture.close() }
        let coordinator = coordinate(fixture.view, position: position)
        defer { coordinator.detach() }
        try await waitUntil(timeout: .seconds(30)) { coordinator.finishedLoading && position.htmlAnchor != nil }
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 850), animated: false)
        try await waitUntil { abs(position.rendered.y - 850) < 2 }
        await position.flush()

        let changed = "<h1>Updated report</h1>" + prose
        await position.prepare(text: changed, store: store, connectionID: connectionID, path: "/report.html")
        XCTAssertNil(position.htmlSessionID)
        XCTAssertNil(position.captureHTMLPosition)
        XCTAssertNil(position.htmlAnchor)
        XCTAssertNil(position.sourceAnchor)
        XCTAssertEqual(position.source, .zero)
        XCTAssertEqual(position.rendered, .zero)

        // SwiftUI can reuse the same native viewport/coordinator for a new source.
        coordinator.beginLoading(changed)
        XCTAssertNotNil(position.htmlSessionID)
        XCTAssertNotNil(position.captureHTMLPosition)
        coordinator.navigation = fixture.view.loadHTMLString(StaticHTMLWebView.html(changed), baseURL: nil)
        try await waitUntil(timeout: .seconds(30)) { coordinator.finishedLoading && position.htmlAnchor != nil }
        fixture.view.scrollView.setContentOffset(CGPoint(x: 0, y: 650), animated: false)
        try await waitUntil { abs(position.rendered.y - 650) < 2 && position.htmlAnchor?.kind == "html-text" }
        await position.flush()
        let saved = await store.restore(connectionID: connectionID, path: "/report.html", revision: SavedReadingPosition.revision(for: changed))
        let old = await store.restore(connectionID: connectionID, path: "/report.html", revision: SavedReadingPosition.revision(for: prose))
        XCTAssertEqual(saved?.renderedAnchor, position.htmlAnchor)
        XCTAssertEqual(saved?.rendered.y, 650)
        XCTAssertEqual(saved?.source.y, 0)
        XCTAssertNil(saved?.sourceAnchor)
        XCTAssertNil(old)
    }

    func testHTMLHistoryRecreatesIndependentModesAndResetsChangedContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("positions.json"), connectionID = UUID()
        let original = DocumentReadingPosition()
        await original.prepare(text: prose, store: ReadingPositionStore(fileURL: file), connectionID: connectionID, path: "/report.html")
        original.htmlAnchor = .init(kind: "html-text", ordinal: 1, character: 412, viewportY: 18)
        original.rendered = CGPoint(x: 0, y: 700)
        original.sourceAnchor = .init(kind: "source", character: 170, viewportY: 22)
        original.source = CGPoint(x: 0, y: 310)
        await original.flush()

        let recreated = DocumentReadingPosition()
        await recreated.prepare(text: prose, store: ReadingPositionStore(fileURL: file), connectionID: connectionID, path: "/report.html")
        XCTAssertEqual(recreated.htmlAnchor, original.htmlAnchor)
        XCTAssertEqual(recreated.sourceAnchor, original.sourceAnchor)
        XCTAssertEqual(recreated.rendered, original.rendered)
        XCTAssertEqual(recreated.source, original.source)
        XCTAssertNil(recreated.overflowGeometry.snapshot, "HTML anchors must not enter the Markdown renderer")
        await recreated.prepare(text: prose + "<p>New revision</p>", store: ReadingPositionStore(fileURL: file), connectionID: connectionID, path: "/report.html")
        XCTAssertNil(recreated.htmlAnchor)
        XCTAssertNil(recreated.sourceAnchor)
        XCTAssertEqual(recreated.rendered, .zero)
        XCTAssertEqual(recreated.source, .zero)
    }

    @MainActor private struct Fixture {
        let view: AnchoredHTMLWebView
        let window: UIWindow
        let previous: UIWindow?
        func close() {
            guard window.rootViewController != nil else { return }
            view.stopLoading()
            view.navigationDelegate = nil
            view.scrollView.delegate = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
    }

    private func host(width: CGFloat = 360) async throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let rules = try await SVGResourceBlocker.rules()
        let view = AnchoredHTMLWebView(frame: CGRect(x: 0, y: 0, width: width, height: 400),
                             configuration: StaticHTMLWebView.configuration(rules: rules))
        view.scrollView.contentInsetAdjustmentBehavior = .never
        let controller = UIViewController()
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        return Fixture(view: view, window: window, previous: previous)
    }

    private func coordinate(_ view: AnchoredHTMLWebView, position: DocumentReadingPosition,
                            onFinish: @escaping (Bool) -> Void = { XCTAssertFalse($0) }) -> StaticHTMLWebView.Coordinator {
        let coordinator = StaticHTMLWebView.Coordinator(readingPosition: position,
            onFinish: onFinish, onFailure: { XCTFail($0) },
            openExternalLink: { _ in XCTFail("Loading must not open external links") })
        coordinator.attach(view)
        view.navigationDelegate = coordinator
        view.scrollView.delegate = coordinator
        coordinator.beginLoading(prose)
        coordinator.navigation = view.loadHTMLString(StaticHTMLWebView.html(prose), baseURL: nil)
        return coordinator
    }

    private func load(_ source: String, in view: WKWebView) async throws {
        let probe = HTMLAnchorNavigationProbe()
        view.navigationDelegate = probe
        view.loadHTMLString(StaticHTMLWebView.html(source), baseURL: nil)
        try await waitUntil(timeout: .seconds(30)) { probe.finished || probe.failure != nil }
        if let error = probe.failure { throw error }
        view.navigationDelegate = nil
        try await waitUntil(timeout: .seconds(30)) { view.scrollView.contentSize.height > view.bounds.height }
    }

    private func characterY(_ character: Int, in view: WKWebView) async throws -> Double {
        try await number("""
        (() => { const node=document.getElementById('passage').firstChild;
        const range=document.createRange(); range.setStart(node, \(character));
        range.setEnd(node, Math.min(node.length, \(character + 1)));
        return range.getBoundingClientRect().top; })()
        """, in: view)
    }

    private func evaluate(_ script: String, in view: WKWebView) async throws -> Any? {
        try await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
    }

    private func number(_ script: String, in view: WKWebView) async throws -> Double {
        let result = try await evaluate(script, in: view)
        return try XCTUnwrap(result as? NSNumber).doubleValue
    }

    private func waitUntil(timeout: Duration = .seconds(15), file: StaticString = #filePath, line: UInt = #line, _ ready: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await ready() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for view in windows.flatMap(views).compactMap({ $0 as? WKWebView }) {
            let dom = try? await evaluate("JSON.stringify({ready:document.readyState,y:scrollY,width:innerWidth,height:innerHeight,body:document.body.getBoundingClientRect().toJSON(),text:document.body.innerText.length})", in: view)
            let anchor = try? await HTMLReadingAnchor.capture(in: view)
            print("HTML TIMEOUT native=\(view.bounds) content=\(view.scrollView.contentSize) offset=\(view.scrollView.contentOffset) loading=\(view.isLoading) hidden=\(view.window?.isHidden ?? true) dom=\(String(describing: dom)) anchor=\(String(describing: anchor))")
        }
        XCTFail("Timed out waiting for the attached HTML renderer", file: file, line: line)
        throw HTMLAnchorTestError.timeout
    }
}

private enum HTMLAnchorTestError: Error { case timeout }

@MainActor private final class HTMLAnchorNavigationProbe: NSObject, WKNavigationDelegate {
    var finished = false
    var failure: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
}
#endif
