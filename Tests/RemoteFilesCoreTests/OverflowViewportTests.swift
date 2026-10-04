#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import Observation
@testable import RemoteFilesUI
@testable import Textual

@MainActor @Observable private final class OverflowFixtureState {
    var text: String
    init(_ text: String) { self.text = text }
}
private struct OverflowFixtureView: View {
    @Bindable var state: OverflowFixtureState
    var body: some View { DocumentContentView(text: state.text, markdown: true, source: false, filename: "viewport.md") }
}

@MainActor final class OverflowViewportTests: XCTestCase {
    private var fixture: String {
        (0..<24).map { index in
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
    private func host() throws -> (UIWindow, UIWindow?, OverflowFixtureState) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let state = OverflowFixtureState(fixture)
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

}
#endif
