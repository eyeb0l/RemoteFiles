import SwiftUI

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
    let text: String
    let highlighted: AttributedString?
    let readingPosition: DocumentReadingPosition?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SourceTextView {
        let view = SourceTextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isSelectable = true
        view.dataDetectorTypes = []; view.backgroundColor = .clear
        view.textContainerInset = .init(top: 20, left: 20, bottom: 20, right: 20)
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = "Bounded source text"
        view.accessibilityLabel = "Source text"
        view.delegate = context.coordinator
        view.pendingOffset = readingPosition?.source ?? .zero
        return view
    }
    func updateUIView(_ view: SourceTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.position = readingPosition
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label])
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
        if view.attributedText.string.utf8.elementsEqual(text.utf8), view.attributedText.isEqual(to: result) { return }
        let selected = view.selectedRange, offset = view.contentOffset
        coordinator.applying = true
        view.attributedText = result
        if selected.location + selected.length <= result.length { view.selectedRange = selected }
        if view.pendingOffset == nil { view.setContentOffset(offset, animated: false) }
        coordinator.applying = false
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var position: DocumentReadingPosition?
        var applying = false
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !applying, (scrollView as? SourceTextView)?.pendingOffset == nil,
                  scrollView.isDragging || scrollView.isDecelerating else { return }
            position?.source = CGPoint(x: 0, y: max(0, scrollView.contentOffset.y))
        }
    }
}

final class SourceTextView: UITextView {
    var pendingOffset: CGPoint?
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let target = pendingOffset, !attributedText.string.isEmpty else { return }
        pendingOffset = nil
        setContentOffset(CGPoint(x: 0, y: min(max(0, target.y), max(0, contentSize.height - bounds.height))), animated: false)
    }
}
#endif
