#if os(iOS)
import WebKit
import RemoteFilesCore

/// Only app-owned code runs, in WebKit's isolated client world. DOM ordinals and
/// numeric geometry leave that world; document text, IDs and URLs never do.
@MainActor enum HTMLReadingAnchor {
    static func capture(in view: WKWebView) async throws -> SavedReadingPosition.Anchor? {
        let result = try await evaluate(common + captureScript, in: view)
        guard let value = result as? [String: Any],
              let kind = value["kind"] as? String,
              let ordinal = value["ordinal"] as? Int,
              let character = value["character"] as? Int,
              let fraction = value["fraction"] as? Double,
              let viewportY = value["viewportY"] as? Double else { return nil }
        let anchor = SavedReadingPosition.Anchor(kind: kind, ordinal: ordinal, character: character,
                                                fraction: fraction, viewportY: viewportY)
        return valid(anchor) ? anchor : nil
    }

    static func restore(_ anchor: SavedReadingPosition.Anchor, in view: WKWebView) async throws -> Bool {
        guard let point = try await target(for: anchor, in: view) else { return false }
        try Task.checkCancellation()
        view.scrollView.setContentOffset(point, animated: false)
        return true
    }

    /// Resolving geometry never scrolls in the web process. A coordinator can
    /// check its generation and user-interaction state after the await before
    /// applying this point, so a stale evaluation cannot move a newer reader.
    static func target(for anchor: SavedReadingPosition.Anchor, in view: WKWebView) async throws -> CGPoint? {
        guard valid(anchor) else { return nil }
        let result = try await evaluate(common + restoreScript, arguments: [
            "kind": anchor.kind, "ordinal": anchor.ordinal, "character": anchor.character,
            "fraction": anchor.fraction, "viewportY": anchor.viewportY
        ], in: view)
        guard let value = result as? [String: Any],
              let x = value["x"] as? Double, let y = value["y"] as? Double,
              let scrollX = value["scrollX"] as? Double, let scrollY = value["scrollY"] as? Double,
              let viewportWidth = value["viewportWidth"] as? Double,
              [x, y, scrollX, scrollY, viewportWidth].allSatisfy(\.isFinite), viewportWidth > 0 else { return nil }
        let scale = view.bounds.width / CGFloat(viewportWidth)
        guard scale.isFinite, scale > 0 else { return nil }
        let scroll = view.scrollView
        // CSS pixels change with pageZoom and viewport scaling. Apply the DOM's
        // relative delta to UIKit's offset, preserving its adjusted inset origin.
        let proposed = CGPoint(x: scroll.contentOffset.x + CGFloat(x - scrollX) * scale,
                               y: scroll.contentOffset.y + CGFloat(y - scrollY) * scale)
        guard proposed.x.isFinite, proposed.y.isFinite else { return nil }
        let inset = scroll.adjustedContentInset
        return CGPoint(
            x: min(max(-inset.left, proposed.x), max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)),
            y: min(max(-inset.top, proposed.y), max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)))
    }

    // WebKit can be suspended or its process can stop responding during teardown.
    // A timeout releases the waiting task (and its renderer) without waiting for
    // WebKit's callback. A late callback holds only this emptied completion box.
    private static func evaluate(_ script: String, arguments: [String: Any] = [:], in view: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            let evaluation = Evaluation(continuation)
            evaluation.timeout = Task {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                evaluation.finish(.failure(EvaluationError.timedOut))
            }
            view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) {
                evaluation.finish($0)
            }
        }
    }
    private enum EvaluationError: Error { case timedOut }
    private final class Evaluation {
        var continuation: CheckedContinuation<Any, Error>?
        var timeout: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<Any, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Any, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(with: result)
        }
    }

    private static func valid(_ anchor: SavedReadingPosition.Anchor) -> Bool {
        ["html-text", "html-block"].contains(anchor.kind) && (0..<20_000).contains(anchor.ordinal) &&
        (0...2_097_152).contains(anchor.character) && anchor.fraction.isFinite &&
        (0...1).contains(anchor.fraction) && anchor.viewportY.isFinite && abs(anchor.viewportY) <= 100_000
    }

    // Count hidden nodes too: media queries must not change the identity of later
    // visible text. Iterative traversal, bounded ancestry and a fixed number of
    // hit tests avoid recursive or per-character work on adversarial documents.
    // Outside these limits callers keep their coordinate fallback. Nothing is
    // cached on the page or held alive after the evaluation completes.
    private static let common = #"""
    const root = document.body;
    if (!root) return null;
    const texts = [], elements = [], textIDs = new WeakMap(), elementIDs = new WeakMap();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    let node, visited = 0;
    while (visited < 20000 && (node = walker.nextNode())) {
        visited++;
        if (node.nodeType === Node.TEXT_NODE) {
            textIDs.set(node, texts.length); texts.push(node);
        } else {
            elementIDs.set(node, elements.length); elements.push(node);
        }
    }
    const width = document.documentElement.clientWidth, height = window.innerHeight;
    const finiteRect = r => r && Number.isFinite(r.top) && Number.isFinite(r.left) &&
        Number.isFinite(r.height) && Number.isFinite(r.width) && r.height > 0 && r.width > 0;
    function visible(element) {
        let depth = 0;
        for (let e = element; e; e = e.parentElement) {
            if (++depth > 128) return false;
            const style = getComputedStyle(e);
            if (style.display === 'none' || style.visibility !== 'visible' ||
                Number(style.opacity) === 0 || style.position === 'fixed' || style.position === 'sticky') return false;
        }
        return true;
    }
    function blockFor(element) {
        for (let e = element, depth = 0; e && e !== root && depth < 128; e = e.parentElement, depth++) {
            if (/^(IMG|SVG|VIDEO|CANVAS|TABLE|PRE)$/.test(e.tagName.toUpperCase())) return e;
        }
        return null;
    }
    function textRect(text, offset) {
        if (!text || !text.length || offset < 0 || offset >= text.length) return null;
        // Never persist a location in the middle of a UTF-16 surrogate pair.
        if (offset > 0 && text.data.charCodeAt(offset) >= 0xDC00 && text.data.charCodeAt(offset) <= 0xDFFF &&
            text.data.charCodeAt(offset - 1) >= 0xD800 && text.data.charCodeAt(offset - 1) <= 0xDBFF) offset--;
        const first = text.data.charCodeAt(offset);
        const length = first >= 0xD800 && first <= 0xDBFF && offset + 1 < text.length ? 2 : 1;
        const range = document.createRange();
        range.setStart(text, offset); range.setEnd(text, Math.min(text.length, offset + length));
        const rect = range.getBoundingClientRect();
        return finiteRect(rect) ? { rect, offset } : null;
    }
    """#

    private static let captureScript = #"""
    if (width <= 0 || height <= 0) return null;
    let bestText = null, bestBlock = null;
    const xs = [Math.min(21, width / 2), width * .25, width * .5, width * .75, Math.max(1, width - 21)];
    const ys = [1, 8, 24, 48, 96, 192].filter(y => y < height);
    for (const y of ys) for (const x of xs) {
        const hit = document.elementFromPoint(x, y);
        if (!hit || !visible(hit)) continue;
        const special = blockFor(hit);
        let block = special || hit;
        // Ordinary containers supply a block fallback for large blank areas.
        // Inline text remains preferable whenever its line is equally close.
        if (block !== root && elementIDs.has(block)) {
            const rect = block.getBoundingClientRect();
            if (finiteRect(rect) && rect.bottom > 0 && rect.top < height) {
                const viewportY = Math.max(0, rect.top);
                const score = viewportY;
                const area = rect.width * rect.height;
                if (!bestBlock || score < bestBlock.score || (score === bestBlock.score && area < bestBlock.area)) {
                    bestBlock = { kind: 'html-block', ordinal: elementIDs.get(block), character: 0,
                        fraction: Math.max(0, Math.min(1, -rect.top / rect.height)), viewportY, score, area,
                        special: !!special };
                }
            }
        }
        // SVG text and wide preformatted/table content follow their containing
        // block proportionally instead of claiming a stable reflowed prose line.
        if (special) continue;
        const caret = document.caretRangeFromPoint(x, y);
        if (!caret || caret.startContainer.nodeType !== Node.TEXT_NODE) continue;
        const text = caret.startContainer;
        if (!textIDs.has(text) || !visible(text.parentElement) || blockFor(text.parentElement)) continue;
        const value = textRect(text, Math.min(caret.startOffset, text.length - 1));
        if (!value) continue;
        const rect = value.rect;
        if (rect.bottom <= 0 || rect.top >= height || rect.right < 0 || rect.left > width) continue;
        // caretRangeFromPoint can choose distant text through a blank region.
        if (Math.abs(Math.max(rect.top, Math.min(y, rect.bottom)) - y) > 24) continue;
        const score = Math.max(0, rect.top);
        if (!bestText || score < bestText.score || (score === bestText.score && rect.left < bestText.left)) {
            bestText = { kind: 'html-text', ordinal: textIDs.get(text), character: value.offset,
                fraction: 0, viewportY: rect.top, score, left: rect.left };
        }
    }
    const selected = bestText && (!bestBlock || bestText.score <= bestBlock.score + (bestBlock.special ? 0 : 24))
        ? bestText : bestBlock;
    if (!selected) return null;
    return { kind: selected.kind, ordinal: selected.ordinal, character: selected.character,
        fraction: selected.fraction, viewportY: selected.viewportY };
    """#

    private static let restoreScript = #"""
    let targetY;
    if (kind === 'html-text') {
        const text = texts[ordinal];
        if (!text || !visible(text.parentElement) || blockFor(text.parentElement)) return null;
        const value = textRect(text, character);
        if (!value) return null;
        targetY = window.scrollY + value.rect.top - viewportY;
    } else if (kind === 'html-block') {
        const element = elements[ordinal];
        if (!element || !visible(element)) return null;
        const rect = element.getBoundingClientRect();
        if (!finiteRect(rect)) return null;
        targetY = window.scrollY + rect.top + rect.height * fraction - viewportY;
    } else return null;
    if (!Number.isFinite(targetY)) return null;
    const scrolling = document.scrollingElement || document.documentElement;
    const maxY = Math.max(0, scrolling.scrollHeight - window.innerHeight);
    const maxX = Math.max(0, scrolling.scrollWidth - document.documentElement.clientWidth);
    const viewportWidth = window.visualViewport && window.visualViewport.width > 0
        ? window.visualViewport.width : document.documentElement.clientWidth;
    return { x: Math.max(0, Math.min(maxX, window.scrollX)), y: Math.max(0, Math.min(maxY, targetY)),
        scrollX: window.scrollX, scrollY: window.scrollY, viewportWidth };
    """#
}
#endif
