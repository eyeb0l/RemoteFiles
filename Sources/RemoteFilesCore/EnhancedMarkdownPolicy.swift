import Foundation

/// Selects the offline rich renderer without changing ordinary Markdown or its source bytes.
public enum EnhancedMarkdownPolicy {
    public static let maximumSourceBytes = 2 * 1024 * 1024
    public static let maximumImages = 128

    // Keep this list aligned with the semantic HTML allowlist in markdown-renderer.js.
    private static let htmlTags: Set<String> = [
        "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "code",
        "ul", "ol", "li", "strong", "b", "em", "i", "s", "del", "sup", "sub", "kbd", "samp",
        "var", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col",
        "div", "span", "details", "summary", "dl", "dt", "dd", "abbr", "mark", "a", "img"
    ]

    /// Uses the same CommonMark parser as the native reader to distinguish real notation
    /// from examples in fenced, indented and inline code, including nested list/quote blocks.
    /// Call off the main actor along with Markdown preparation.
    public static func requiresEnhancedRendering(_ source: String) -> Bool {
        guard source.utf8.count <= maximumSourceBytes,
              source.contains("$") || source.contains("<") || source.contains("\\") || source.localizedCaseInsensitiveContains("mermaid"),
              let document = try? AttributedString(markdown: source,
                  options: .init(appliesSourcePositionAttributes: true)) else { return false }
        var prose = Array(source.utf16)
        for run in document.runs {
            var isCode = run.inlinePresentationIntent?.contains(.code) == true
            for intent in run.presentationIntent?.components ?? [] {
                if case .codeBlock(let language) = intent.kind {
                    if language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid" { return true }
                    isCode = true
                }
            }
            let isHTML = run.inlinePresentationIntent?.contains(.inlineHTML) == true ||
                run.inlinePresentationIntent?.contains(.blockHTML) == true
            if isHTML, !isCode, isSupportedHTML(String(document[run.range].characters)) { return true }
            guard isCode || isHTML, let position = run.markdownSourcePosition,
                  let sourceRange = Range(position, in: source) else { continue }
            // Foundation may include a synthetic final newline in a block's source position.
            // Range conversion retains UTF-16 offsets; clamp before touching the original buffer.
            let range = NSRange(sourceRange, in: source)
            guard range.location < prose.count else { continue }
            for index in range.location..<min(NSMaxRange(range), prose.count) { prose[index] = 0 }
        }
        return containsMath(prose)
    }

    private static func isSupportedHTML(_ html: String) -> Bool {
        let bytes = Array(html.utf8)
        var index = 0
        while index < bytes.count, bytes[index] <= 32 { index += 1 }
        guard index < bytes.count, bytes[index] == 60 else { return false }
        index += 1
        if index < bytes.count, bytes[index] == 47 { index += 1 }
        let start = index
        while index < bytes.count, (65...90).contains(bytes[index]) || (97...122).contains(bytes[index]) || (48...57).contains(bytes[index]) {
            index += 1
        }
        guard index > start, index < bytes.count,
              bytes[index] <= 32 || bytes[index] == 47 || bytes[index] == 62 else { return false }
        return htmlTags.contains(String(decoding: bytes[start..<index], as: UTF8.self).lowercased())
    }

    /// Single pass over original delimiters after code/HTML ranges have been masked.
    /// A masked range cannot join two otherwise unrelated dollar expressions.
    private static func containsMath(_ text: [UInt16]) -> Bool {
        var dollar: Int?, doubleDollar: Int?, parentheses: Int?, brackets: Int?
        var index = 0
        func whitespace(_ value: UInt16) -> Bool {
            guard let scalar = UnicodeScalar(value) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while index < text.count {
            let value = text[index], next = index + 1 < text.count ? text[index + 1] : 0
            if value == 0 {
                dollar = nil; doubleDollar = nil; parentheses = nil; brackets = nil
                index += 1; continue
            }
            if value == 10 || value == 13 { dollar = nil; parentheses = nil; index += 1; continue }
            if value == 92 {
                if next == 41, let start = parentheses, index > start { return true }
                if next == 93, let start = brackets, index > start { return true }
                if next == 40 { parentheses = index + 2 }
                if next == 91 { brackets = index + 2 }
                index += min(2, text.count - index); continue
            }
            if value == 36 {
                if let start = dollar, index > start,
                   !whitespace(text[index - 1]), !(48...57).contains(next) { return true }
                dollar = nil
                if next == 36 {
                    if let start = doubleDollar, index > start { return true }
                    doubleDollar = index + 2; index += 2; continue
                }
                if next != 0, !whitespace(next) { dollar = index + 1 }
            }
            index += 1
        }
        return false
    }

    /// Resources are executable app code. Document text is passed separately as a JS argument.
    public static func rendererScripts() throws -> [String] {
        try ["marked", "dompurify", "katex", "mermaid", "markdown-renderer"].map { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }
}
