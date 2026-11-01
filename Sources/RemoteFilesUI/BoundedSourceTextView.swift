import SwiftUI
import RemoteFilesCore

enum SourceLayout {
    /// A two-axis SwiftUI Text creates one enormous layout surface for long lines.
    /// Bound both long lines and tall documents with TextKit's viewport layout.
    static func needsBoundedLayout(_ text: String) -> Bool {
        if text.utf8.count >= 64 * 1024 { return true }
        var width = 0, lines = 1
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" { width = 0; lines += 1 }
            else { width += scalar.value > 0xFFFF ? 2 : 1 }
            if width > 512 || lines > 512 { return true }
        }
        return false
    }
}

#if os(iOS)
import UIKit

/// Width-constrained, selectable original source. Wrapping is visual only: no
/// characters, escapes, indentation or newlines are inserted into the document.
struct BoundedSourceTextView: UIViewRepresentable {
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17
    let text: String
    let highlighted: AttributedString?
    let readingPosition: DocumentReadingPosition?
    var reveal: ReaderTextReveal? = nil
    var wrapLines = true
    var revealPending = true
    var onReveal: ((UUID) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SourceTextView {
        let view = SourceTextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isSelectable = true
        view.dataDetectorTypes = []; view.backgroundColor = .clear
        view.textContainerInset = .init(top: 20, left: 20, bottom: 20, right: 20)
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = wrapLines
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = "Bounded source text"
        view.accessibilityLabel = "Source text"
        view.delegate = context.coordinator
        view.pendingOffset = readingPosition?.source ?? .zero
        view.anchor = readingPosition?.sourceAnchor
        view.restoreAnchor = view.anchor != nil
        return view
    }
    func updateUIView(_ view: SourceTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.position = readingPosition
        coordinator.wrapLines = wrapLines
        view.onPosition = { point, anchor in
            readingPosition?.source = point
            readingPosition?.sourceAnchor = anchor
        }
        if view.textContainer.widthTracksTextView != wrapLines {
            if view.anchor != nil { view.restoreAnchor = true }
            view.textContainer.widthTracksTextView = wrapLines
            if wrapLines { view.setContentOffset(CGPoint(x: 0, y: view.contentOffset.y), animated: false) }
        }
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label])
        // UITextView clamps an effectively infinite container back to its viewport.
        // Short unwrapped source uses its finite natural width; large/long source
        // never reaches this path and keeps the existing width-bounded layout.
        view.unwrappedWidth = wrapLines ? nil : ceil(result.boundingRect(
            with: CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width) + 2
        if let width = view.unwrappedWidth {
            view.textContainer.size = CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        }
        if let highlighted {
            var offset = 0
            for run in highlighted.runs {
                let count = String(highlighted[run.range].characters).utf16.count
                if let color = run.foregroundColor {
                    result.addAttribute(.foregroundColor, value: UIColor(color), range: NSRange(location: offset, length: count))
                }
                offset += count
            }
        }
        // Refresh identity must remain literal even for canonically equivalent Unicode.
        if let reveal, reveal.inSource, NSMaxRange(reveal.target.range) <= result.length {
            result.addAttributes([.backgroundColor: UIColor.systemYellow, .foregroundColor: UIColor.black], range: reveal.target.range)
        }
        if view.attributedText.string.utf8.elementsEqual(text.utf8), view.attributedText.isEqual(to: result) {
            revealIfNeeded(view, coordinator: coordinator)
            return
        }
        let selected = view.selectedRange, offset = view.contentOffset
        coordinator.applying = true
        if view.anchor != nil { view.restoreAnchor = true }
        view.attributedText = result
        // UITextView replaces container geometry when assigning attributed text.
        // Reapply the finite width after that assignment, before resolving a match.
        if let width = view.unwrappedWidth {
            view.textContainer.size = CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        }
        if let manager = view.textLayoutManager, let range = manager.textContentManager?.documentRange {
            manager.invalidateLayout(for: range)
        }
        if selected.location + selected.length <= result.length { view.selectedRange = selected }
        if view.pendingOffset == nil { view.setContentOffset(offset, animated: false) }
        coordinator.applying = false
        revealIfNeeded(view, coordinator: coordinator)
    }
    private func revealIfNeeded(_ view: SourceTextView, coordinator: Coordinator) {
        guard revealPending, reveal?.inSource == true else {
            view.pendingReveal = nil; view.revealDeadline = nil; view.revealCompletion = nil
            return
        }
        guard revealPending, let reveal, reveal.inSource, coordinator.revealID != reveal.id,
              NSMaxRange(reveal.target.range) <= view.attributedText.length else { return }
        coordinator.revealID = reveal.id
        view.pendingOffset = nil
        view.restoreAnchor = false
        view.anchor = nil
        view.pendingReveal = reveal.target.range
        view.revealDeadline = Date().addingTimeInterval(5)
        view.revealCompletion = { [weak view] point in view?.captureReadingAnchor(); readingPosition?.source = point; onReveal?(reveal.id) }
        view.setNeedsLayout()
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var position: DocumentReadingPosition?
        var applying = false
        var revealID: UUID?
        var wrapLines = true
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            // VoiceOver and other non-touch scrolling do not set dragging flags.
            // captureReadingAnchor still excludes restoration and pending Find work.
            guard !applying else { return }
            (scrollView as? SourceTextView)?.captureReadingAnchor()
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !applying, scrollView.isDragging || scrollView.isDecelerating else { return }
            (scrollView as? SourceTextView)?.pendingOffset = nil
            (scrollView as? SourceTextView)?.restoreAnchor = false
            (scrollView as? SourceTextView)?.captureReadingAnchor()
        }
    }
}

final class SourceTextView: UITextView {
    var anchor: SavedReadingPosition.Anchor?
    var restoreAnchor = false
    var onPosition: ((CGPoint, SavedReadingPosition.Anchor?) -> Void)?
    private var lastWidth: CGFloat = 0
    private var anchorCorrectionScheduled = false
    private var anchorAttempts = 0
    func captureReadingAnchor() {
        guard !restoreAnchor, pendingOffset == nil, pendingReveal == nil else { return }
        let point = CGPoint(x: contentOffset.x + textContainerInset.left,
                            y: contentOffset.y + adjustedContentInset.top + 40)
        if contentOffset.y + adjustedContentInset.top <= 1 { anchor = nil }
        else if let position = closestPosition(to: point) {
            anchor = .init(kind: "source", character: offset(from: beginningOfDocument, to: position),
                           viewportY: Double(caretRect(for: position).minY - contentOffset.y))
        }
        onPosition?(CGPoint(x: max(0, contentOffset.x), y: max(0, contentOffset.y)), anchor)
    }
    var pendingOffset: CGPoint?
    var unwrappedWidth: CGFloat?
    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            var size = newValue
            if let unwrappedWidth { size.width = max(size.width, unwrappedWidth + textContainerInset.left + textContainerInset.right) }
            super.contentSize = size
        }
    }
    var pendingReveal: NSRange?
    var revealDeadline: Date?
    private var revealScheduled = false
    var revealCompletion: ((CGPoint) -> Void)?
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let handled = super.accessibilityScroll(direction)
        if handled {
            pendingOffset = nil; restoreAnchor = false
            // Also capture immediate accessibility scrolls when no animation runs.
            captureReadingAnchor()
        }
        return handled
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }
    override func layoutSubviews() {
        if lastWidth > 0, lastWidth != bounds.width, anchor != nil { restoreAnchor = true }
        lastWidth = bounds.width
        super.layoutSubviews()
        restoreUnwrappedContainer()
        guard window != nil, bounds.width > 0, bounds.height > 0, !attributedText.string.isEmpty else { return }
        if restoreAnchor { scheduleAnchorRestoration() }
        if !restoreAnchor, let target = pendingOffset {
            pendingOffset = nil
            setContentOffset(CGPoint(x: textContainer.widthTracksTextView ? 0 : min(max(0, target.x), max(0, contentSize.width - bounds.width)), y: min(max(0, target.y), max(0, contentSize.height - bounds.height + adjustedContentInset.bottom))), animated: false)
        }
        scheduleReveal()
    }
    private func scheduleAnchorRestoration() {
        guard !anchorCorrectionScheduled else { return }
        anchorCorrectionScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.anchorCorrectionScheduled = false
            guard self.restoreAnchor, let anchor = self.anchor, self.window != nil else { self.anchorAttempts = 0; return }
            guard !self.isDragging, !self.isDecelerating,
                  let position = self.position(from: self.beginningOfDocument, offset: anchor.character) else {
                self.restoreAnchor = false; self.anchorAttempts = 0; return
            }
            self.layoutIfNeeded()
            let rect = self.caretRect(for: position)
            guard rect.height > 0, rect.minY.isFinite else { self.restoreAnchor = false; return }
            let x = min(max(0, self.pendingOffset?.x ?? self.contentOffset.x),
                        max(0, self.contentSize.width - self.bounds.width))
            let y = min(max(0, rect.minY - anchor.viewportY),
                        max(0, self.contentSize.height - self.bounds.height + self.adjustedContentInset.bottom))
            let stable = abs(self.contentOffset.y - y) < 0.5
            self.setContentOffset(CGPoint(x: self.textContainer.widthTracksTextView ? 0 : x, y: y), animated: false)
            self.anchorAttempts += 1
            if (stable && self.anchorAttempts > 1) || self.anchorAttempts >= 60 {
                self.restoreAnchor = false; self.pendingOffset = nil; self.anchorAttempts = 0
                self.captureReadingAnchor()
            } else { self.scheduleAnchorRestoration() }
        }
    }

    private func restoreUnwrappedContainer() {
        guard !textContainer.widthTracksTextView, let width = unwrappedWidth,
              abs(textContainer.size.width - width) > 0.5 else { return }
        // UITextView's viewport layout may reset this width while fitting its
        // representable. Reapply it after that layout, before reading glyph rects.
        textContainer.size = CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        if let manager = textLayoutManager, let range = manager.textContentManager?.documentRange {
            manager.invalidateLayout(for: range)
            manager.ensureLayout(for: range)
        }
    }
    private func scheduleReveal() {
        guard pendingReveal != nil, !revealScheduled, window != nil else { return }
        revealScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.revealScheduled = false
            self.applyPendingReveal()
        }
    }
    private func applyPendingReveal() {
        guard window != nil, let range = pendingReveal else { return }
        guard let deadline = revealDeadline, Date() < deadline,
              !isDragging, !isDecelerating else {
            pendingReveal = nil; revealCompletion = nil; revealDeadline = nil
            return
        }
        layoutIfNeeded()
        restoreUnwrappedContainer()
        if !textContainer.widthTracksTextView, let manager = textLayoutManager,
           let documentRange = manager.textContentManager?.documentRange {
            // Only short source may be unwrapped. Materialize its horizontal
            // text range before asking UITextInput for offscreen glyph geometry.
            manager.ensureLayout(for: documentRange)
        }
        scrollRangeToVisible(range)
        guard let lower = position(from: beginningOfDocument, offset: range.location),
              let upper = position(from: lower, offset: range.length),
              let textRange = textRange(from: lower, to: upper) else { scheduleReveal(); return }
        let textRect = firstRect(for: textRange)
        guard !textRect.isNull, !textRect.isEmpty, textRect.minX.isFinite, textRect.minY.isFinite else { scheduleReveal(); return }
        if !textContainer.widthTracksTextView {
            // UITextView's range helper only reveals vertically on iOS. Use
            // its actual text geometry for the unwrapped horizontal axis too.
            let rect = textRect.insetBy(dx: -12, dy: -12)
            scrollRectToVisible(rect, animated: false)
            let x = min(max(0, rect.maxX - bounds.width), max(0, contentSize.width - bounds.width))
            setContentOffset(CGPoint(x: x, y: contentOffset.y), animated: false)
        }
        // UIKit can adjust its offset again while finishing the first TextKit
        // layout. Confirm the actual viewport on the following turn before
        // consuming this request or publishing the new reading position.
        let expected = contentOffset
        revealScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.revealScheduled = false
            guard self.pendingReveal == range else { self.scheduleReveal(); return }
            let currentRect = self.firstRect(for: textRange)
            if abs(self.contentOffset.x - expected.x) < 1, abs(self.contentOffset.y - expected.y) < 1,
               abs(currentRect.minX - textRect.minX) < 1, abs(currentRect.minY - textRect.minY) < 1 {
                self.pendingReveal = nil; self.revealDeadline = nil
                self.revealCompletion?(CGPoint(x: max(0, self.contentOffset.x), y: max(0, self.contentOffset.y)))
                self.revealCompletion = nil
            } else {
                self.scheduleReveal()
            }
        }
    }
}
#endif
