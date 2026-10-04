#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import Observation
@testable import RemoteFilesUI
@testable import Textual

@MainActor @Observable private final class OverflowFixtureState {
    var text: String
    var source = false
    let position = DocumentReadingPosition()
    init(_ text: String) { self.text = text }
}
private struct OverflowFixtureView: View {
    @Bindable var state: OverflowFixtureState
    var body: some View { DocumentContentView(text: state.text, markdown: true, source: state.source,
        filename: "viewport.md", readingPosition: state.position) }
}

@MainActor final class OverflowViewportTests: XCTestCase {
    private func fixture(_ count: Int = 24) -> String {
        (0..<count).map { index in
            """
            ## Section \(index)

            Paragraph \(index) remains selectable with a [relative note](./note.md) after offscreen regions retire.

            ```text
            code_marker_\(index) \(String(repeating: "wide_code_", count: 45))
            second_line_\(index)
            ```

            | \((0..<12).map { "Column \($0)" }.joined(separator: " | ")) |
            | \((0..<12).map { _ in "---" }.joined(separator: " | ")) |
            | \((0..<12).map { "cell_\(index)_\($0)" }.joined(separator: " | ")) |

            \(String(repeating: "Retained prose geometry and selection. ", count: 20))

            """
        }.joined(separator: "\n\n")
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private func outer(_ window: UIWindow) -> UIScrollView? {
        views(window).compactMap { $0 as? UIScrollView }.filter {
            $0.bounds.width > 200 && $0.bounds.height > 200 && $0.contentSize.height > $0.bounds.height * 4
        }.max { $0.bounds.height < $1.bounds.height }
    }
    private func horizontal(_ window: UIWindow) -> [UIScrollView] {
        views(window).compactMap { $0 as? UIScrollView }.filter {
            $0.bounds.width > 100 && $0.bounds.height < 600 && $0.contentSize.width > $0.bounds.width + 100
        }.sorted { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
    }
    private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Timed out waiting for settled overflow viewport state", file: file, line: line)
        throw NSError(domain: "OverflowViewportTests", code: 1)
    }
    private func host(text: String? = nil) throws -> (UIWindow, UIWindow?, OverflowFixtureState) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let state = OverflowFixtureState(text ?? fixture())
        window.rootViewController = UIHostingController(rootView: OverflowFixtureView(state: state))
        window.makeKeyAndVisible()
        return (window, previous, state)
    }
    private func selectedText(_ model: TextSelectionModel) -> NSAttributedString {
        model.attributedText(in: TextRange(start: model.startPosition, end: model.endPosition))
    }
    private func cleanup(_ window: UIWindow, previous: UIWindow?) {
        window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
    }

    func testRetiringOverflowPreservesGeometryHorizontalOffsetAndFullProseCopy() async throws {
        let (window, previous, _) = try host(); defer { cleanup(window, previous: previous) }
        try await wait { self.outer(window) != nil && self.horizontal(window).count == 48 }
        try await Task.sleep(for: .seconds(2))
        let scroll = try XCTUnwrap(outer(window))
        let first = try XCTUnwrap(horizontal(window).first)
        let initialSize = scroll.contentSize
        let innerSize = first.contentSize
        let innerBounds = first.bounds.size
        let parent = try XCTUnwrap(views(window).compactMap { $0 as? UITextInteractionView }.first {
            $0.bounds.height > initialSize.height * 0.9 && $0.model.hasText
        })
        let originalCopy = selectedText(parent.model)
        XCTAssertTrue(originalCopy.string.contains("Paragraph 23"), "Offscreen prose must remain in the full selection model")
        first.setContentOffset(CGPoint(x: 80, y: 0), animated: false)
        XCTAssertEqual(first.contentOffset.x, 80, accuracy: 1)
        scroll.setContentOffset(CGPoint(x: 0, y: min(scroll.bounds.height * 8, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        try await wait { !self.views(first).contains { $0 is UITextInteractionView } }
        XCTAssertTrue(views(window).contains { $0 === first }, "Keep the same horizontal scroll container mounted")
        XCTAssertEqual(scroll.contentSize.height, initialSize.height, accuracy: 1)
        XCTAssertEqual(scroll.contentSize.width, initialSize.width, accuracy: 1)
        XCTAssertEqual(first.contentSize.width, innerSize.width, accuracy: 1)
        XCTAssertEqual(first.contentSize.height, innerSize.height, accuracy: 1)
        XCTAssertEqual(first.bounds.height, innerBounds.height, accuracy: 1)
        XCTAssertEqual(first.contentOffset.x, 80, accuracy: 1)
        let retiredCopy = selectedText(parent.model)
        XCTAssertEqual(retiredCopy.string, originalCopy.string)
        XCTAssertTrue(retiredCopy.isEqual(to: originalCopy), "Preserve structured copy attributes, links and block semantics")
        scroll.setContentOffset(.zero, animated: false)
        try await wait { self.views(first).contains { ($0 as? UITextInteractionView)?.model.hasText == true } }
        XCTAssertEqual(scroll.contentSize.height, initialSize.height, accuracy: 1)
        XCTAssertEqual(first.contentOffset.x, 80, accuracy: 1)
    }

    func testActiveCodeSelectionRetainsItsModelAndFormattedCopyWhenScrolledOffscreen() async throws {
        let (window, previous, _) = try host(); defer { cleanup(window, previous: previous) }
        try await wait { self.outer(window) != nil && self.horizontal(window).count == 48 }
        try await Task.sleep(for: .seconds(2))
        let scroll = try XCTUnwrap(outer(window)); let first = try XCTUnwrap(horizontal(window).first)
        try await wait { self.views(first).contains { ($0 as? UITextInteractionView)?.model.hasText == true } }
        let interaction = try XCTUnwrap(views(first).compactMap { $0 as? UITextInteractionView }.first { $0.model.hasText })
        let originalCopy = selectedText(interaction.model)
        XCTAssertTrue(originalCopy.string.contains("code_marker_0"))
        interaction.model.selectedRange = TextRange(start: interaction.model.startPosition, end: interaction.model.endPosition)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.bounds.height * 8), animated: false)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(views(first).contains { $0 === interaction }, "Active selection must keep its native interaction model")
        XCTAssertNotNil(interaction.model.selectedRange)
        XCTAssertTrue(selectedText(interaction.model).isEqual(to: originalCopy))
        interaction.model.selectedRange = nil
        try await wait { !self.views(first).contains { $0 is UITextInteractionView } }
    }
    func testChangedOffscreenCodeRemeasuresBeforeRetirementAndRemount() async throws {
        let (window, previous, state) = try host(); defer { cleanup(window, previous: previous) }
        try await wait { self.outer(window) != nil && self.horizontal(window).count == 48 }
        try await Task.sleep(for: .seconds(2))
        let scroll = try XCTUnwrap(outer(window)); let first = try XCTUnwrap(horizontal(window).first)
        let oldHeight = scroll.contentSize.height
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.bounds.height * 8), animated: false)
        try await wait { !self.views(first).contains { $0 is UITextInteractionView } }
        state.text = state.text.replacingOccurrences(of: "second_line_0", with:
            (0..<20).map { "updated_offscreen_code_\($0)" }.joined(separator: "\n"))
        try await wait { scroll.contentSize.height > oldHeight + 200 }
        try await Task.sleep(for: .seconds(1))
        try await wait { !self.views(first).contains { $0 is UITextInteractionView } }
        let updatedHeight = scroll.contentSize.height
        scroll.setContentOffset(.zero, animated: false)
        try await wait { self.views(first).contains { ($0 as? UITextInteractionView)?.model.hasText == true } }
        let interaction = try XCTUnwrap(views(first).compactMap { $0 as? UITextInteractionView }.first { $0.model.hasText })
        XCTAssertTrue(selectedText(interaction.model).string.contains("updated_offscreen_code_19"))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(scroll.contentSize.height, updatedHeight, accuracy: 1)
    }

    private func prose(_ window: UIWindow) -> UITextInteractionView? {
        guard let scroll = outer(window) else { return nil }
        return views(window).compactMap { $0 as? UITextInteractionView }.first {
            $0.model.hasText && $0.bounds.height > scroll.contentSize.height * 0.9
        }
    }
    private func visibleCharacter(_ window: UIWindow) throws -> (Int, CGFloat) {
        let scroll = try XCTUnwrap(outer(window)); let interaction = try XCTUnwrap(prose(window))
        let viewport = scroll.convert(scroll.bounds, to: window)
        let point = CGPoint(x: viewport.minX + 30, y: viewport.minY + 60)
        let position = try XCTUnwrap(interaction.model.closestPosition(to: interaction.convert(point, from: window)))
        return (interaction.model.offset(from: interaction.model.startPosition, to: position),
                interaction.convert(interaction.model.caretRect(for: position), to: window).minY)
    }
    private func characterY(_ character: Int, in window: UIWindow) throws -> CGFloat {
        let interaction = try XCTUnwrap(prose(window))
        let position = try XCTUnwrap(interaction.model.position(from: interaction.model.startPosition, offset: character))
        return interaction.convert(interaction.model.caretRect(for: position), to: window).minY
    }

    func testLargeInitialMountDefersRegionsWithoutLosingFullProseCopyOrSelectAll() async throws {
        let text = fixture(72); XCTAssertGreaterThan(text.utf8.count, 64 * 1024)
        let (window, previous, _) = try host(text: text); defer { cleanup(window, previous: previous) }
        try await wait { self.prose(window).map { self.selectedText($0.model).string.contains("Paragraph 71") } == true }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThan(horizontal(window).count, 144, "Do not initially construct all distant horizontal labels")
        let interaction = try XCTUnwrap(prose(window))
        let copy = selectedText(interaction.model)
        XCTAssertTrue(copy.string.contains("Paragraph 0")); XCTAssertTrue(copy.string.contains("Paragraph 71"))
        interaction.model.selectedRange = TextRange(start: interaction.model.startPosition, end: interaction.model.endPosition)
        try await wait { self.horizontal(window).count == 144 }
        XCTAssertNotNil(interaction.model.selectedRange)
        XCTAssertTrue(selectedText(interaction.model).isEqual(to: copy), "Full formatted prose copy must survive eager selection fallback")
        interaction.model.selectedRange = nil
    }

    func testLargeFastJumpKeepsVisibleProseAnchorAndSourceReturnRestoresSameCharacter() async throws {
        let (window, previous, state) = try host(text: fixture(72)); defer { cleanup(window, previous: previous) }
        try await wait { self.prose(window).map { self.selectedText($0.model).string.contains("Paragraph 71") } == true }
        let scroll = try XCTUnwrap(outer(window))
        let initialHeight = scroll.contentSize.height
        let initialViewport = scroll.bounds.height
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height * 0.73), animated: false)
        let before = try visibleCharacter(window)
        let initialOffset = scroll.contentOffset.y
        try await Task.sleep(for: .seconds(2))
        let settledCharacterY = try characterY(before.0, in: window)
        print("OVERFLOW RANGE initial_height=\(initialHeight) settled_height=\(scroll.contentSize.height) viewport_height=\(initialViewport) initial_offset=\(initialOffset) settled_offset=\(scroll.contentOffset.y) character=\(before.0) initial_caret_y=\(before.1) settled_caret_y=\(settledCharacterY) vertical_indicator=\(scroll.showsVerticalScrollIndicator)")
        XCTAssertEqual(settledCharacterY, before.1, accuracy: 2,
                       "Measuring skipped regions above the viewport must keep the visible prose line anchored")
        try await wait { state.position.overflowGeometry.hasReadingAnchor }
        let saved = try visibleCharacter(window)
        for _ in 0..<3 {
            state.source = true
            try await Task.sleep(for: .seconds(1))
            state.source = false
            try await wait { self.prose(window).map { self.selectedText($0.model).string.contains("Paragraph 71") } == true && !state.position.overflowGeometry.isRestoringReadingAnchor }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(try characterY(saved.0, in: window), saved.1, accuracy: 2,
                           "Return to the same logical prose character even when previously unseen heights become precise")
        }
    }

    private func checkBlockReturn(marker: String) async throws {
        let text = String(repeating: "Selectable opening prose. ", count: 2700) + "\n\n```text\n" +
            (0..<40).map { "anchor-code-\($0) " + String(repeating: "wide_", count: 50) }.joined(separator: "\n") +
            "\n```\n\n| Heading | Value |\n| --- | --- |\n" +
            (0..<40).map { "| anchor-cell-\($0) | " + String(repeating: "wide_", count: 30) + " |" }.joined(separator: "\n") +
            "\n\nClosing selectable prose."
        XCTAssertGreaterThan(text.utf8.count, 64 * 1024)
        let (window, previous, state) = try host(text: text); defer { cleanup(window, previous: previous) }
        func region() -> ReadingAnchorRegionBridge.Probe? {
            views(window).compactMap { $0 as? ReadingAnchorRegionBridge.Probe }.first {
                if case .overflow(let key) = $0.id { return String(key.revision.characters).contains(marker) }
                return false
            }
        }
        try await wait { self.outer(window) != nil && region() != nil }
        let scroll = try XCTUnwrap(outer(window))
        var block = try XCTUnwrap(region())
        var viewport = scroll.convert(scroll.bounds, to: window)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + block.convert(block.bounds, to: window).minY - viewport.minY), animated: false)
        try await wait { region()?.ready == true }
        try await Task.sleep(for: .seconds(1))
        block = try XCTUnwrap(region()); viewport = scroll.convert(scroll.bounds, to: window)
        let localY = min(block.bounds.height / 2, 300)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + block.convert(block.bounds, to: window).minY + localY - viewport.minY - 60), animated: false)
        try await Task.sleep(for: .seconds(1))
        state.position.overflowGeometry.recordReadingAnchor()
        XCTAssertTrue(state.position.overflowGeometry.hasReadingAnchor)
        let before = block.convert(block.bounds, to: window).minY
        for _ in 0..<3 {
            state.source = true; try await Task.sleep(for: .milliseconds(500))
            state.source = false
            try await wait { region()?.ready == true && !state.position.overflowGeometry.isRestoringReadingAnchor }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(try XCTUnwrap(region()).convert(try XCTUnwrap(region()).bounds, to: window).minY,
                           before, accuracy: 2, "Keep the same point inside a dominant code/table block")
        }
    }

    func testDominantCodeBlockReturnsAcrossRepeatedSourceSwitches() async throws {
        try await checkBlockReturn(marker: "anchor-code-")
    }
    func testDominantTableReturnsAcrossRepeatedSourceSwitches() async throws {
        try await checkBlockReturn(marker: "anchor-cell-")
    }

}
#endif
