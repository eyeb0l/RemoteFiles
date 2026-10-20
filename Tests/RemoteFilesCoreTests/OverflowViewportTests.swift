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
    /// Polls observable state, so a passing run returns as soon as it settles. The bound covers main-thread
    /// layout of the 72-section fixture: each Source/Rendered switch took 5-7 s on a loaded local Simulator
    /// and longer on 3-CPU CI runners, while restoration and retirement stay frame-driven behind it.
    private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(45)
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
        do {
            try await wait { !self.views(first).contains { $0 is UITextInteractionView } }
        } catch {
            print("OVERFLOW SELECTION RETIREMENT offset=\(scroll.contentOffset) viewport=\(scroll.convert(scroll.bounds, to: window)) block=\(first.convert(first.bounds, to: window)) selection=\(String(describing: interaction.model.selectedRange)) attached=\(first.window === window) hasText=\(interaction.model.hasText)")
            throw error
        }
    }
    func testChangedOffscreenCodeRemeasuresBeforeRetirementAndRemount() async throws {
        let (window, previous, state) = try host(); defer { cleanup(window, previous: previous) }
        try await wait { self.outer(window) != nil && self.horizontal(window).count == 48 }
        try await Task.sleep(for: .seconds(2))
        let scroll = try XCTUnwrap(outer(window)); let first = try XCTUnwrap(horizontal(window).first)
        let oldHeight = scroll.contentSize.height
        let oldBlockHeight = first.bounds.height
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.bounds.height * 8), animated: false)
        try await wait { !self.views(first).contains { $0 is UITextInteractionView } }
        let offscreenOffset = scroll.contentOffset
        state.text = state.text.replacingOccurrences(of: "second_line_0", with:
            (0..<20).map { "updated_offscreen_code_\($0)" }.joined(separator: "\n"))
        try await wait {
            scroll.contentSize.height > oldHeight + 200 && self.horizontal(window).count == 48 &&
                self.horizontal(window).first === first
        }
        XCTAssertTrue(first.window === window, "Keep the original horizontal container mounted while its text changes")
        XCTAssertGreaterThan(first.bounds.height, oldBlockHeight + 200,
                             "The changed code block must measure its added lines before retiring")
        try await Task.sleep(for: .seconds(1))
        do {
            try await wait { !self.views(first).contains { $0 is UITextInteractionView } }
        } catch {
            let interactions = views(first).compactMap { $0 as? UITextInteractionView }.map {
                "frame=\($0.frame) hasText=\($0.model.hasText) selection=\(String(describing: $0.model.selectedRange))"
            }.joined(separator: "; ")
            print("OVERFLOW CHANGED RETIREMENT beforeOffset=\(offscreenOffset) currentOffset=\(scroll.contentOffset) saved=\(state.position.rendered) outerSize=\(scroll.contentSize) viewport=\(scroll.convert(scroll.bounds, to: window)) block=\(first.convert(first.bounds, to: window)) blockSize=\(first.contentSize) attached=\(first.window === window) currentFirst=\(horizontal(window).first === first) currentOuter=\(outer(window) === scroll) restoring=\(state.position.overflowGeometry.isRestoringReadingAnchor) hasAnchor=\(state.position.overflowGeometry.hasReadingAnchor) interactions=[\(interactions)]")
            throw error
        }
        XCTAssertTrue(views(window).contains { $0 === first }, "Keep the original horizontal container mounted after retirement")
        let updatedHeight = scroll.contentSize.height
        scroll.setContentOffset(.zero, animated: false)
        try await wait { self.views(first).contains { ($0 as? UITextInteractionView)?.model.hasText == true } }
        XCTAssertTrue(horizontal(window).first === first, "Remount the changed label inside its retained horizontal container")
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
    private func showSource(_ state: OverflowFixtureState, in window: UIWindow) async throws {
        state.source = true
        // Observe the actual replacement, not a fixed delay that can coalesce
        // Source and Rendered into one update on a busy Simulator.
        try await wait {
            !self.views(window).contains { $0 is UITextInteractionView } &&
                self.views(window).compactMap { $0 as? SourceTextView }.contains {
                    $0.window === window && $0.bounds.width > 0 && $0.bounds.height > 0 && $0.text == state.text
                }
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
            try await showSource(state, in: window)
            state.source = false
            do {
                try await wait { self.prose(window).map { self.selectedText($0.model).string.contains("Paragraph 71") } == true && !state.position.overflowGeometry.isRestoringReadingAnchor }
            } catch {
                print("OVERFLOW SOURCE RETURN source=\(state.source) proseReady=\(self.prose(window).map { self.selectedText($0.model).string.contains("Paragraph 71") } == true) restoring=\(state.position.overflowGeometry.isRestoringReadingAnchor) hasAnchor=\(state.position.overflowGeometry.hasReadingAnchor) sourceViews=\(self.views(window).filter { $0 is SourceTextView }.count)")
                throw error
            }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(try characterY(saved.0, in: window), saved.1, accuracy: 2,
                           "Return to the same logical prose character even when previously unseen heights become precise")
        }
    }

    func testReadingAnchorRestorationWaitsForTheReplacementViewportToAttach() async throws {
        let (window, previous, state) = try host(text: fixture(72)); defer { cleanup(window, previous: previous) }
        try await wait { self.prose(window).map { self.selectedText($0.model).string.contains("Paragraph 71") } == true }
        let scroll = try XCTUnwrap(outer(window))
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height * 0.73), animated: false)
        try await Task.sleep(for: .seconds(2))
        let saved = try visibleCharacter(window)
        let cache = state.position.overflowGeometry
        cache.recordReadingAnchor()
        XCTAssertTrue(cache.hasReadingAnchor)
        let probe = try XCTUnwrap(views(window).compactMap { $0 as? OverflowAnchorBridge.Probe }.first)
        let parent = try XCTUnwrap(probe.superview)
        // Model a replacement subtree whose prepared text takes longer to attach
        // than the old five-second correction budget. Keep this independent of CPU speed.
        probe.removeFromSuperview()
        var completed = false
        cache.restoreReadingAnchor { _ in completed = true }
        scroll.setContentOffset(.zero, animated: false)
        try await Task.sleep(for: .milliseconds(5500))
        XCTAssertNil(probe.window, "The replacement viewport has not attached yet")
        XCTAssertTrue(cache.isRestoringReadingAnchor, "Waiting for a viewport must not consume the geometry-correction budget")
        parent.addSubview(probe)
        try await wait { completed && !cache.isRestoringReadingAnchor }
        XCTAssertEqual(try characterY(saved.0, in: window), saved.1, accuracy: 2)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Reading position restored after delayed viewport attachment"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAttachedUnreadyAnchorFinishesWithinItsCorrectionBudget() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: window.bounds.width, height: 3000)
        controller.view.addSubview(scroll)
        let cache = OverflowGeometryCache()
        let probe = OverflowAnchorBridge.Probe(cache, deferring: true)
        probe.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        scroll.addSubview(probe)
        let region = ReadingAnchorRegionBridge.Probe(cache, id: .image("delayed-region"), ready: true)
        region.frame = CGRect(x: 0, y: 1000, width: window.bounds.width, height: 500)
        scroll.addSubview(region)
        window.makeKeyAndVisible()
        defer { cache.cancelAnchor(); cleanup(window, previous: previous) }
        scroll.setContentOffset(CGPoint(x: 0, y: 1000), animated: false)
        cache.recordReadingAnchor()
        XCTAssertTrue(cache.hasReadingAnchor)
        region.ready = false
        var completed = false
        cache.restoreReadingAnchor { _ in completed = true }
        scroll.setContentOffset(.zero, animated: false)
        try await wait { scroll.contentOffset.y > 999 && cache.isRestoringReadingAnchor }
        // Keep the anchor attached but deliberately unready beyond the five-second
        // correction budget. Attachment waiting must not extend that budget.
        try await Task.sleep(for: .seconds(6))
        XCTAssertFalse(region.ready)
        XCTAssertTrue(completed, "Attached content must finish restoration within its correction budget")
        XCTAssertFalse(cache.isRestoringReadingAnchor)
        XCTAssertEqual(scroll.contentOffset.y, 1000, accuracy: 1)
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
            try await showSource(state, in: window)
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
