#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import RemoteFilesUI
@testable import Textual

@MainActor @Observable private final class RevealFixtureState {
    let text: String
    let navigation = ReaderNavigationState()
    let position = DocumentReadingPosition()
    var version = 0
    init(_ text: String) { self.text = text }
}

private struct RevealFixture: View {
    @Bindable var state: RevealFixtureState
    var body: some View {
        DocumentContentView(text: state.text, markdown: true, source: false,
            filename: "overflow-find.md", readingPosition: state.position, navigation: state.navigation)
            .id(state.version)
    }
}

@MainActor @Observable private final class PreparedRevealState {
    var document: AttributedString
    var request: UUID?
    init(_ document: AttributedString) { self.document = document }
}

private struct PreparedRevealFixture: View {
    @Bindable var state: PreparedRevealState
    var body: some View {
        ScrollView {
            StructuredText(state.document)
                .textual.revealNavigationTarget(state.request)
                .textual.textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
    }
}

@MainActor final class TextualNavigationRevealTests: XCTestCase {
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private func documentScroll(_ window: UIWindow) -> UIScrollView? {
        views(window).compactMap { $0 as? UIScrollView }.filter {
            $0.bounds.height > 200 && $0.contentSize.height > $0.bounds.height * 2
        }.max { $0.bounds.height < $1.bounds.height }
    }
    private func wait(_ predicate: () -> Bool, diagnostics: () -> String = { "" },
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Requested overflow result did not become visible\n" + diagnostics(), file: file, line: line)
        throw NSError(domain: "TextualNavigationRevealTests", code: 1)
    }
    private func diagnostics(_ needle: String, window: UIWindow) -> String {
        let scrolls = views(window).compactMap { $0 as? UIScrollView }.map {
            "\(type(of: $0)) offset=\($0.contentOffset) insets=\($0.adjustedContentInset) bounds=\($0.bounds) content=\($0.contentSize)"
        }
        let targets = views(window).compactMap { $0 as? UITextInteractionView }.compactMap { interaction -> String? in
            let model = interaction.model
            let all = TextRange(start: model.startPosition, end: model.endPosition)
            let range = (model.text(in: all) as NSString).range(of: needle)
            guard range.location != NSNotFound,
                  let lower = model.position(from: model.startPosition, offset: range.location),
                  let upper = model.position(from: lower, offset: range.length) else { return nil }
            let rects = model.selectionRects(for: TextRange(start: lower, end: upper)).map { interaction.convert($0.rect, to: window) }
            return "target overlay=\(interaction.bounds) range=\(range) windowRects=\(rects)"
        }
        return (scrolls + targets).joined(separator: "\n")
    }
    private func targetVisible(_ needle: String, window: UIWindow) -> Bool {
        for interaction in views(window).compactMap({ $0 as? UITextInteractionView }) {
            let model = interaction.model
            let all = TextRange(start: model.startPosition, end: model.endPosition)
            let range = (model.text(in: all) as NSString).range(of: needle)
            guard range.location != NSNotFound,
                  let lower = model.position(from: model.startPosition, offset: range.location),
                  let upper = model.position(from: lower, offset: range.length) else { continue }
            guard let selection = model.selectionRects(for: TextRange(start: lower, end: upper)).first else { continue }
            let rect = interaction.convert(selection.rect, to: window)
            guard rect.width > 0, rect.height > 0 else { continue }
            var scrolls: [UIScrollView] = []
            var ancestor = interaction.superview
            while let value = ancestor {
                if let scroll = value as? UIScrollView { scrolls.append(scroll) }
                ancestor = value.superview
            }
            // The outer prose model represents overflow blocks as attachments;
            // verify the actual inner text, including its horizontal viewport.
            guard scrolls.contains(where: { $0.contentSize.width > $0.bounds.width + 100 }) else { continue }
            let clipped = scrolls.reduce(window.bounds) { $0.intersection($1.convert($1.bounds, to: window)) }
            let visible = rect.intersection(clipped)
            if visible.width >= min(rect.width, 20), visible.height >= min(rect.height, 8) { return true }
        }
        return false
    }
    func testUnresolvableRevealStopsItsDisplayLinkAndDoesNotRestartTheSameRequest() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let probe = NavigationRevealBridge.Probe(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let id = UUID(), coordinator = NavigationRevealCoordinator()
        probe.id = id; probe.coordinator = coordinator
        probe.target = CGRect(x: 0, y: 0, width: 20, height: 20)
        // A real window with no scroll ancestor can never fulfill this request.
        controller.view.addSubview(probe)
        try await wait { probe.failedID == id }
        XCTAssertFalse(probe.isWaitingForGeometry)
        XCTAssertTrue(coordinator.isPending(id), "Unresolved geometry must not report successful reveal")
        probe.schedule()
        XCTAssertFalse(probe.isWaitingForGeometry, "Layout must not restart the failed UUID forever")
        probe.id = UUID(); probe.schedule()
        XCTAssertTrue(probe.isWaitingForGeometry, "A new user request can try again")
        probe.stop()
    }
    func testPreparedAttributeChangesUpdateLinksAndRevealWithoutReplacingTheRenderingSubtree() async throws {
        let markdown = (0..<45).map { index in
            "## Prepared \(index)\n\n" + String(repeating: "Retained readable paragraph content. ", count: 18) +
                (index == 25 ? " [prepared_link_target](./before.md)" : "")
        }.joined(separator: "\n\n")
        let state = PreparedRevealState(try AttributedStringMarkdownParser.markdown().attributedString(for: markdown))
        let originalCharacters = String(state.document.characters)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: PreparedRevealFixture(state: state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await wait { self.documentScroll(window) != nil && self.views(window).contains { ($0 as? UITextInteractionView)?.model.hasText == true } }
        let scroll = try XCTUnwrap(documentScroll(window))
        let interaction = try XCTUnwrap(views(window).compactMap { $0 as? UITextInteractionView }.first { $0.model.hasText })
        let initialHeight = scroll.contentSize.height
        scroll.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        let id = UUID(), updatedURL = try XCTUnwrap(URL(string: "./after.md"))
        let target = try XCTUnwrap(state.document.range(of: "prepared_link_target"))
        state.document[target].link = updatedURL
        state.document[target].backgroundColor = .yellow
        state.document[target][TextualNavigationTarget.self] = id
        state.request = id
        func copy() -> NSAttributedString {
            interaction.model.attributedText(in: TextRange(start: interaction.model.startPosition, end: interaction.model.endPosition))
        }
        func linkMatches(_ url: URL) -> Bool {
            let text = copy(), range = (text.string as NSString).range(of: "prepared_link_target")
            guard range.location != NSNotFound else { return false }
            return (text.attribute(.link, at: range.location, effectiveRange: nil) as? URL) == url
        }
        try await wait { linkMatches(updatedURL) && scroll.contentOffset.y > 2_000 }
        XCTAssertEqual(String(state.document.characters), originalCharacters)
        XCTAssertTrue(documentScroll(window) === scroll, "Prepared updates must retain the native scroll container")
        XCTAssertTrue(views(window).contains { $0 === interaction }, "Prepared updates must retain the selection overlay")
        XCTAssertEqual(scroll.contentSize.height, initialHeight, accuracy: 2)
        let revealedOffset = scroll.contentOffset
        let finalURL = try XCTUnwrap(URL(string: "./final.md"))
        state.document[target].link = finalURL
        state.document[target].backgroundColor = nil
        state.document[target][TextualNavigationTarget.self] = nil
        state.request = nil
        try await wait { linkMatches(finalURL) }
        XCTAssertEqual(scroll.contentOffset.y, revealedOffset.y, accuracy: 2,
                       "An attribute-only update after reveal must keep the user's current viewport")
        XCTAssertTrue(documentScroll(window) === scroll)
        XCTAssertTrue(views(window).contains { $0 === interaction })
    }
    private func check(block: String, needle: String) async throws {
        let opening = (0..<100).map { "Opening paragraph \($0). " + String(repeating: "Readable prose preserves geometry. ", count: 25) }.joined(separator: "\n\n")
        let text = opening + "\n\n" + block + "\n\n" + String(repeating: "Closing prose.\n\n", count: 60)
        XCTAssertGreaterThan(text.utf8.count, 64 * 1024)
        let state = RevealFixtureState(text)
        await state.navigation.prepare(text: text, markdown: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RevealFixture(state: state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await wait { self.views(window).compactMap { $0 as? UIScrollView }.contains { $0.contentSize.height > 5_000 } }
        XCTAssertFalse(targetVisible(needle, window: window))
        state.navigation.isFinding = true
        state.navigation.query = needle
        await state.navigation.search(inSource: false)
        XCTAssertEqual(state.navigation.matches.count, 1)
        try await wait({ self.targetVisible(needle, window: window) },
                       diagnostics: { self.diagnostics(needle, window: window) })
        let scroll = try XCTUnwrap(documentScroll(window))
        XCTAssertGreaterThan(scroll.contentOffset.y, 1_000)
        scroll.setContentOffset(CGPoint(x: -scroll.adjustedContentInset.left,
                                       y: -scroll.adjustedContentInset.top), animated: false)
        // An already fulfilled UUID must not pull the user back to its result.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 2)
        state.version += 1
        // SwiftUI replaces the subtree on a later update. The old tall scroll view
        // still satisfies the initial-mount predicate until that update begins.
        try await wait({
            guard let candidate = self.documentScroll(window) else { return false }
            return candidate !== scroll
        }, diagnostics: { self.diagnostics(needle, window: window) })
        let recreated = try XCTUnwrap(documentScroll(window))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(views(window).contains { $0 === recreated }, "The recreated scroll must remain mounted")
        XCTAssertEqual(recreated.contentOffset.y + recreated.adjustedContentInset.top, 0, accuracy: 2,
                       "A fulfilled Find request must stay fulfilled after the content subtree remounts")
    }
    func testFindMountsOffscreenCodeAndRevealsItsExactHorizontalAndVerticalRange() async throws {
        let lines = (0..<35).map { "code_line_\($0) " + String(repeating: "wide_", count: 55) }
        let block = "```text\n" + lines.joined(separator: "\n") + "\n" + String(repeating: "wide_", count: 55) + "code_find_target\n```"
        try await check(block: block, needle: "code_find_target")
    }
    func testFindMountsOffscreenTableAndRevealsItsDistantCell() async throws {
        let headings = (0..<10).map { "Column \($0)" }.joined(separator: " | ")
        let divider = (0..<10).map { _ in "---" }.joined(separator: " | ")
        let rows = (0..<24).map { row in
            "| " + (0..<10).map { column in row == 22 && column == 9 ? "table_find_target" : "wide_cell_\(row)_\(column)" }.joined(separator: " | ") + " |"
        }.joined(separator: "\n")
        try await check(block: "| \(headings) |\n| \(divider) |\n\(rows)", needle: "table_find_target")
    }
}

@MainActor final class ReaderWarmUpTests: XCTestCase {
    func testWarmUpRunsOffTheMainActorCoalescesAndRepeatsCheaply() async {
        let first = ReaderWarmUp.start()
        XCTAssertEqual(first, ReaderWarmUp.start(), "An in-flight warm-up must be shared, not duplicated")
        let outcome = await first.value
        XCTAssertFalse(outcome.ranOnMainThread)
        XCTAssertTrue(outcome.completed)
        XCTAssertGreaterThan(outcome.preparedTypes, 30)
        // Runtime caches are populated; a later folder appearance repeats the same lookups.
        let repeated = await ReaderWarmUp.start().value
        XCTAssertEqual(repeated, outcome)
        // Time the repeated lookups themselves. Waiting for a utility-priority task to be scheduled
        // took 0.85 s on a loaded 3-CPU CI runner and says nothing about the cached work.
        let elapsed = await Task.detached {
            ContinuousClock().measure { _ = ReaderWarmUp.perform(shouldContinue: { true }) }
        }.value
        XCTAssertLessThan(elapsed, .milliseconds(500))
    }

    func testWarmUpStopsBetweenTypesWhenCancelled() async {
        let partial = await Task.detached {
            var checks = 0
            return ReaderWarmUp.perform(shouldContinue: { checks += 1; return checks <= 3 })
        }.value
        XCTAssertEqual(partial, .init(preparedTypes: 3, completed: false, ranOnMainThread: false))
        XCTAssertEqual(StructuredText.prepareRendering(shouldContinue: { false }), 0)
        let task = ReaderWarmUp.start()
        ReaderWarmUp.cancel()
        let outcome = await task.value
        XCTAssertFalse(outcome.ranOnMainThread)
        XCTAssertNotEqual(ReaderWarmUp.start(), task, "A finished or cancelled run must not block later warm-up")
    }

    func testWarmUpDoesNotChangeRenderedDocumentPixels() async throws {
        let markdown = """
        # Warm-up heading

        Paragraph with **bold**, *italic*, `code` and a [link](./other.md).

        - First item
        - Second item

        1. Ordered

        > Quoted text

        ```swift
        let value = 42
        ```

        | Name | Value |
        | --- | --- |
        | A | 1 |
        """
        let before = try await renderedPixels(markdown)
        _ = await ReaderWarmUp.start().value
        let after = try await renderedPixels(markdown)
        XCTAssertEqual(before.count, after.count)
        XCTAssertTrue(before == after, "Warm-up must not change rendering output")
    }

    private func renderedPixels(_ markdown: String) async throws -> [UInt8] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: DocumentContentView(text: markdown, markdown: true, source: false, filename: "warm-up.md"))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        // Let preparation, inline styles, attachments and highlighting settle before capturing.
        try await Task.sleep(for: .seconds(3))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let pixels = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                                              bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        let ink = stride(from: 0, to: bytes.count, by: 4).filter { min(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) < 180 }.count
        XCTAssertGreaterThan(ink, 500, "The comparison needs a rendered document, not a blank or loading view")
        return bytes
    }
}
#endif
