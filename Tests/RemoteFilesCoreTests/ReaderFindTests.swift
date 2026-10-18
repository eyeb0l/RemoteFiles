#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import RemoteFilesCore
@testable import RemoteFilesUI
@testable import Textual

@MainActor @Observable private final class FindFixtureState {
    let text: String
    let markdown: Bool
    var source: Bool
    var wrapLines: Bool
    let navigation = ReaderNavigationState()
    let position = DocumentReadingPosition()
    init(text: String, markdown: Bool = true, source: Bool = false, wrapLines: Bool = true) {
        self.text = text; self.markdown = markdown; self.source = source; self.wrapLines = wrapLines
    }
}

private struct FindFixture: View {
    @Bindable var state: FindFixtureState
    var body: some View {
        NavigationStack {
            DocumentContentView(text: state.text, markdown: state.markdown, source: state.source,
                filename: state.markdown ? "report.md" : "original.txt", readingPosition: state.position,
                wrapLines: state.wrapLines, navigation: state.navigation)
                .navigationTitle("Find fixture")
        }
    }
}

@MainActor final class ReaderFindTests: XCTestCase {
    private let needle = "farneedle 👩🏽‍💻 cafe\u{301}"
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func waitUntil(_ condition: () -> Bool, diagnostics: @escaping () -> String = { "" },
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for real Find viewport: \(diagnostics())", file: file, line: line)
        throw NSError(domain: "ReaderFindTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: diagnostics()])
    }
    private func host(_ state: FindFixtureState) async throws -> UIWindow {
        await state.navigation.prepare(text: state.text, markdown: state.markdown)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: FindFixture(state: state))
        window.makeKeyAndVisible()
        return window
    }
    private func previousWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }
    private func renderedScroll(_ window: UIWindow) -> UIScrollView? {
        descendants(window).compactMap { $0 as? UIScrollView }.filter {
            !($0 is UITextView) && $0.isScrollEnabled && $0.window === window && !$0.isHidden &&
            $0.bounds.height > 200 && $0.contentSize.height > $0.bounds.height * 2
        }.max { $0.bounds.height < $1.bounds.height }
    }
    private func sourceView(_ window: UIWindow) -> UITextView? {
        descendants(window).compactMap { $0 as? UITextView }.first {
            $0.accessibilityIdentifier == "Bounded source text" && $0.window === window && !$0.isHidden
        }
    }
    private func diagnostics(_ window: UIWindow) -> String {
        descendants(window).compactMap { $0 as? UIScrollView }.map {
            let source = $0 as? SourceTextView
            return "\(type(of: $0)) offset=\($0.contentOffset) size=\($0.contentSize) bounds=\($0.bounds) " +
                "pending=\(String(describing: source?.pendingReveal)) container=\(String(describing: source?.textContainer.size))"
        }.joined(separator: "\n")
    }
    /// Reads Textual's production hit-map geometry. No test-only anchor or substitute layout.
    private func renderedRects(_ query: String, in window: UIWindow) -> [CGRect] {
        var rectangles: [CGRect] = []
        for overlay in descendants(window).compactMap({ $0 as? UITextInteractionView }) where overlay.window === window && !overlay.isHidden {
            let model = overlay.model
            let fullRange = TextRange(start: model.startPosition, end: model.endPosition)
            let text = model.text(in: fullRange) as NSString
            var start = 0
            while start < text.length {
                let range = text.range(of: query, options: [.literal], range: NSRange(location: start, length: text.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                if let lower = model.position(from: model.startPosition, offset: range.location),
                   let upper = model.position(from: model.startPosition, offset: NSMaxRange(range)) {
                    let rect = model.selectionRects(for: TextRange(start: lower, end: upper)).first?.rect ?? .null
                    if !rect.isEmpty { rectangles.append(overlay.convert(rect, to: window)) }
                }
                start = NSMaxRange(range)
            }
        }
        return rectangles.sorted { $0.minY < $1.minY }
    }
    private func targetIsVisible(_ rect: CGRect, scroll: UIScrollView, window: UIWindow) -> Bool {
        let viewport = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
        return rect.height > 0 && rect.intersection(viewport).height >= min(rect.height, 8)
    }
    private func assertRenderedVisible(_ query: String, occurrence: Int, in window: UIWindow,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil({
            guard let scroll = self.renderedScroll(window) else { return false }
            let rects = self.renderedRects(query, in: window)
            return rects.indices.contains(occurrence) && self.targetIsVisible(rects[occurrence], scroll: scroll, window: window)
        }, diagnostics: { "query=\(query), occurrence=\(occurrence), rects=\(self.renderedRects(query, in: window))\n\(self.diagnostics(window))" }, file: file, line: line)
    }
    private var renderedDocument: String {
        (0..<60).map { section in
            let marker = [18, 43].contains(section) ? "\n\n\(needle) marks the requested result." : ""
            return "## Section \(section)\n\n" + (0..<3).map {
                "Paragraph \(section).\($0) contains ordinary report prose that must scroll naturally. This sentence adds enough text to wrap over several lines on a phone."
            }.joined(separator: "\n\n") + marker
        }.joined(separator: "\n\n")
    }

    func testRenderedFindRevealsActualFarMatchesNextPreviousWrapAndNoResults() async throws {
        let state = FindFixtureState(text: renderedDocument), previous = previousWindow()
        let window = try await host(state)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await waitUntil({ self.renderedScroll(window) != nil }, diagnostics: { self.diagnostics(window) })
        state.navigation.isFinding = true; state.navigation.query = needle
        await state.navigation.search(inSource: false)
        XCTAssertEqual(state.navigation.matches.count, 2)
        try await assertRenderedVisible(needle, occurrence: 0, in: window)
        let firstOffset = try XCTUnwrap(renderedScroll(window)).contentOffset.y
        XCTAssertGreaterThan(firstOffset, 1_000, "Find must physically scroll to a distant result")
        state.navigation.move(1, inSource: false)
        try await assertRenderedVisible(needle, occurrence: 1, in: window)
        let secondOffset = try XCTUnwrap(renderedScroll(window)).contentOffset.y
        XCTAssertGreaterThan(secondOffset, firstOffset + 1_000)
        state.navigation.move(-1, inSource: false)
        try await assertRenderedVisible(needle, occurrence: 0, in: window)
        state.navigation.move(-1, inSource: false)
        try await assertRenderedVisible(needle, occurrence: 1, in: window)
        XCTAssertEqual(state.navigation.selected, 1)
        state.navigation.move(1, inSource: false)
        try await assertRenderedVisible(needle, occurrence: 0, in: window)
        XCTAssertEqual(state.navigation.selected, 0)
        let beforeNoResults = try XCTUnwrap(renderedScroll(window)).contentOffset.y
        state.navigation.query = "certainly absent from this report 9c583c"
        await state.navigation.search(inSource: false)
        XCTAssertTrue(state.navigation.matches.isEmpty); XCTAssertNil(state.navigation.reveal)
        state.navigation.move(1, inSource: false)
        await Task.yield()
        XCTAssertEqual(try XCTUnwrap(renderedScroll(window)).contentOffset.y, beforeNoResults, accuracy: 2)
    }

    func testHeadingNavigationRevealsTheActualDistantHeadingThenReturnsToAnEarlierOne() async throws {
        let state = FindFixtureState(text: renderedDocument), previous = previousWindow()
        let window = try await host(state)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await waitUntil { self.renderedScroll(window) != nil }
        let far = try XCTUnwrap(state.navigation.index?.headings.first { $0.title == "Section 52" })
        state.navigation.show(far)
        try await assertRenderedVisible("Section 52", occurrence: 0, in: window)
        let farOffset = try XCTUnwrap(renderedScroll(window)).contentOffset.y
        XCTAssertGreaterThan(farOffset, 1_000)
        let earlier = try XCTUnwrap(state.navigation.index?.headings.first { $0.title == "Section 3" })
        state.navigation.show(earlier)
        try await assertRenderedVisible("Section 3", occurrence: 0, in: window)
        XCTAssertLessThan(try XCTUnwrap(renderedScroll(window)).contentOffset.y, farOffset - 1_000)
    }

    func testPendingHeadingOnColdMountOverridesAnEarlierSavedCoordinate() async throws {
        let state = FindFixtureState(text: renderedDocument), previous = previousWindow()
        await state.navigation.prepare(text: state.text, markdown: true)
        state.position.rendered = CGPoint(x: 0, y: 900)
        state.navigation.show(try XCTUnwrap(state.navigation.index?.headings.first { $0.title == "Section 52" }))
        let window = try await host(state)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await assertRenderedVisible("Section 52", occurrence: 0, in: window)
        try await Task.sleep(for: .milliseconds(300))
        try await assertRenderedVisible("Section 52", occurrence: 0, in: window)
        XCTAssertGreaterThan(try XCTUnwrap(renderedScroll(window)).contentOffset.y, 10_000)
    }

    private func sourceTargetVisible(_ range: NSRange, view: UITextView, window: UIWindow) -> Bool {
        guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
              let end = view.position(from: start, offset: range.length),
              let textRange = view.textRange(from: start, to: end) else { return false }
        return targetIsVisible(view.convert(view.firstRect(for: textRange), to: window), scroll: view, window: window)
    }
    private func assertSourceTarget(_ state: FindFixtureState, in window: UIWindow,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let reveal = try XCTUnwrap(state.navigation.reveal, file: file, line: line)
        try await waitUntil({
            guard let view = self.sourceView(window) else { return false }
            return self.sourceTargetVisible(reveal.target.range, view: view, window: window)
        }, diagnostics: { self.diagnostics(window) }, file: file, line: line)
        let view = try XCTUnwrap(sourceView(window), file: file, line: line)
        XCTAssertEqual(Data(view.attributedText.string.utf8), Data(state.text.utf8), "Finding must preserve literal source bytes", file: file, line: line)
        let substring = (view.attributedText.string as NSString).substring(with: reveal.target.range)
        XCTAssertEqual(Data(substring.utf8), Data(needle.utf8), "UTF-16 ranges must cover the exact emoji and decomposed accent", file: file, line: line)
        var highlighted: [NSRange] = []
        view.attributedText.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: view.attributedText.length)) { color, range, _ in
            if let color = color as? UIColor, color.isEqual(UIColor.systemYellow) { highlighted.append(range) }
        }
        XCTAssertEqual(highlighted, [reveal.target.range], "Only the chosen literal match is highlighted", file: file, line: line)
    }

    func testShortUnwrappedSourceFindRevealsHorizontallyAndKeepsNativeViewportAfterClosing() async throws {
        let text = "start\r\n\t" + String(repeating: "prefix ", count: 40) + needle + "  \r\nend\r\n"
        XCTAssertFalse(SourceLayout.needsBoundedLayout(text), "This case must exercise the short-source renderer transition")
        let state = FindFixtureState(text: text, markdown: false, source: true, wrapLines: false)
        let previous = previousWindow(), window = try await host(state)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        state.navigation.isFinding = true; state.navigation.query = needle
        await state.navigation.search(inSource: true)
        let target = try XCTUnwrap(state.navigation.reveal).target.range
        try await waitUntil({
            guard let view = self.sourceView(window),
                  let lower = view.position(from: view.beginningOfDocument, offset: target.location),
                  let upper = view.position(from: lower, offset: target.length),
                  let range = view.textRange(from: lower, to: upper) else { return false }
            let rect = view.convert(view.firstRect(for: range), to: window)
            let viewport = view.convert(view.bounds, to: window).intersection(window.bounds)
            let intersection = rect.intersection(viewport)
            return !view.textContainer.widthTracksTextView && view.contentOffset.x > 100 &&
                intersection.width >= min(rect.width, 30) && intersection.height >= min(rect.height, 8)
        }, diagnostics: {
            var result = self.diagnostics(window)
            if let view = self.sourceView(window),
               let lower = view.position(from: view.beginningOfDocument, offset: target.location),
               let upper = view.position(from: lower, offset: target.length),
               let range = view.textRange(from: lower, to: upper) {
                result += " target=\(target) rect=\(view.firstRect(for: range)) caret=\(view.caretRect(for: lower))"
            }
            return result
        })
        try await assertSourceTarget(state, in: window)
        let native = try XCTUnwrap(sourceView(window)), offset = try XCTUnwrap(sourceView(window)).contentOffset
        XCTAssertFalse(native.textContainer.widthTracksTextView)
        XCTAssertGreaterThan(native.contentSize.width, native.bounds.width * 2)
        state.navigation.query = ""
        await state.navigation.search(inSource: true)
        try await waitUntil({
            guard let current = self.sourceView(window), current === native else { return false }
            return current.attributedText.attribute(.backgroundColor, at: target.location, effectiveRange: nil) == nil
        }, diagnostics: { self.diagnostics(window) })
        XCTAssertEqual(native.contentOffset.x, offset.x, accuracy: 2, "Clearing Find must retain horizontal reading position")
        XCTAssertEqual(native.contentOffset.y, offset.y, accuracy: 2)
        state.navigation.closeFind()
        await Task.yield()
        XCTAssertTrue(sourceView(window) === native, "Closing Find must retain the native source viewport")
        XCTAssertFalse(native.textContainer.widthTracksTextView, "Find must honor Wrap Lines off after closing")
        XCTAssertEqual(native.contentOffset.x, offset.x, accuracy: 2)
        XCTAssertEqual(Data(native.attributedText.string.utf8), Data(text.utf8))
        // The retained renderer must continue to honor subsequent Wrap Lines changes.
        state.wrapLines = true
        try await waitUntil { native.textContainer.widthTracksTextView && abs(native.contentOffset.x) < 2 }
        XCTAssertTrue(sourceView(window) === native)
        XCTAssertEqual(Data(native.attributedText.string.utf8), Data(text.utf8))
    }

    func testBoundedSourceFindUsesUnicodeRangesAndPreservesOriginalCRLFAndIndentation() async throws {
        let text = (0..<620).map { line in
            [170, 480].contains(line) ? "\t\(line): \(needle)  \r\n" : "\t\(line): literal \\\"α\\\" and two trailing spaces  \r\n"
        }.joined()
        XCTAssertTrue(SourceLayout.needsBoundedLayout(text))
        let state = FindFixtureState(text: text, markdown: false, source: true), previous = previousWindow()
        let window = try await host(state)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await waitUntil { self.sourceView(window) != nil }
        state.navigation.isFinding = true; state.navigation.query = "farneedle 👩🏽‍💻 café"
        await state.navigation.search(inSource: true)
        XCTAssertEqual(state.navigation.matches.count, 2)
        try await assertSourceTarget(state, in: window)
        let firstOffset = try XCTUnwrap(sourceView(window)).contentOffset.y
        XCTAssertGreaterThan(firstOffset, 1_000)
        state.navigation.move(1, inSource: true)
        try await assertSourceTarget(state, in: window)
        XCTAssertGreaterThan(try XCTUnwrap(sourceView(window)).contentOffset.y, firstOffset + 1_000)
        state.navigation.move(-1, inSource: true)
        try await assertSourceTarget(state, in: window)
        state.navigation.move(-1, inSource: true)
        try await assertSourceTarget(state, in: window)
        XCTAssertEqual(state.navigation.selected, 1)
    }
}
#endif
