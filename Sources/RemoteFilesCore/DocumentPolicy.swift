import Foundation

public enum DocumentKind: Equatable, Sendable {
    case markdown, plainText, unsupported
}

public enum DocumentPreview: Equatable, Sendable {
    case text(String, markdown: Bool)
    case empty
    case unsupportedFileType
    case unsupportedEncodingOrBinary
    case tooLarge
}

/// The reader's local policy. The transport must also enforce the limit while receiving bytes.
public enum DocumentPolicy {
    public static let previewByteLimit = 2 * 1_024 * 1_024

    public static func kind(filename: String) -> DocumentKind {
        let name = filename.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        let suffix = name.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if ["md", "markdown"].contains(suffix) { return .markdown }
        let textExtensions: Set<String> = [
            "txt", "text", "log", "json", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "conf", "config",
            "env", "properties", "csv", "tsv", "xml", "html", "htm", "css", "scss", "less", "svg", "sql",
            "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "php", "java", "kt",
            "kts", "js", "jsx", "ts", "tsx", "sh", "bash", "zsh", "fish", "ps1", "r", "lua", "dart",
            "vue", "svelte", "graphql", "gql", "gitignore", "gitattributes", "editorconfig", "lock",
        ]
        // Extensionless names (including dotfiles) are candidates; byte validation remains mandatory.
        if !name.contains(".") || name.first == "." || textExtensions.contains(suffix) { return .plainText }
        return .unsupported
    }

    public static func decode(_ data: Data, filename: String, maxBytes: Int = previewByteLimit) -> DocumentPreview {
        guard data.count <= max(0, maxBytes) else { return .tooLarge }
        guard !data.isEmpty else { return .empty }
        let kind = kind(filename: filename)
        guard kind != .unsupported else { return .unsupportedFileType }
        // NUL and other non-whitespace C0 controls are a deliberate binary signal even in valid UTF-8.
        guard !data.contains(where: { ($0 < 0x20 && ![0x09, 0x0A, 0x0D].contains($0)) || $0 == 0x7F }),
              var text = String(data: data, encoding: .utf8) else { return .unsupportedEncodingOrBinary }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        guard !text.isEmpty else { return .empty }
        return .text(text, markdown: kind == .markdown)
    }

    /// Called only in response to the reader's link-tap action. No relative resource resolution.
    public static func allowsExternalLink(_ url: URL) -> Bool {
        guard url.baseURL == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        return true
    }

    /// Foundation is the same CommonMark/GFM parser used by Textual. This performs only
    /// attributed-output policy/formatting, never Markdown syntax parsing or resource loading.
    /// Invoke away from the main actor for substantial reports.
    public static func prepareMarkdown(_ source: String, preserveImages: Bool = false) throws -> AttributedString {
        var document = try AttributedString(markdown: source)
        // Replace image runs before handing content to Textual, so its default image loader never
        // receives a URL. Keep readable alt text, including for relative/data/file image URLs.
        for run in Array(document.runs).reversed() {
            if run.imageURL != nil && !preserveImages {
                // Foundation uses an object-replacement character for an image with no alt text.
                let alt = String(document[run.range].characters)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var replacement = AttributedString(alt.isEmpty ? "[Image preview unavailable]" : "[Image: \(alt) — preview unavailable]")
                replacement.setAttributes(run.attributes)
                replacement.imageURL = nil
                replacement.link = nil
                replacement.inlinePresentationIntent = .emphasized
                document.replaceSubrange(run.range, with: replacement)
            } else if let link = run.link, !allowsExternalLink(link) {
                document[run.range].link = nil
            }
        }

        // Foundation preserves GFM task markers as list-item text. Format the first marker in
        // each parsed item as a read-only checkbox; code spans and continuation paragraphs stay intact.
        var seenItems = Set<Int>()
        var markers: [(Range<AttributedString.Index>, String, AttributeContainer)] = []
        for run in document.runs {
            guard let intent = run.presentationIntent,
                  let item = intent.components.first(where: { if case .listItem = $0.kind { return true }; return false }),
                  seenItems.insert(item.identity).inserted,
                  run.inlinePresentationIntent?.contains(.code) != true else { continue }
            let characters = document[run.range].characters
            let prefix = String(characters.prefix(4))
            guard prefix == "[ ] " || prefix == "[x] " || prefix == "[X] " else { continue }
            let end = characters.index(characters.startIndex, offsetBy: 3)
            markers.append((run.range.lowerBound..<end, prefix == "[ ] " ? "☐" : "☑", run.attributes))
        }
        for (range, marker, attributes) in markers.reversed() {
            var replacement = AttributedString(marker)
            replacement.setAttributes(attributes)
            document.replaceSubrange(range, with: replacement)
        }
        return document
    }
}


public struct MarkdownPart: Identifiable, Sendable {
    public enum Content: Sendable { case text(AttributedString), image(reference: String, alt: String) }
    public let id: Int
    public let content: Content
}

public extension DocumentPolicy {
    static func remoteMarkdownParts(_ source: String) throws -> [MarkdownPart] {
        let document = try prepareMarkdown(source, preserveImages: true)
        var parts: [MarkdownPart] = []
        var start = document.startIndex
        for run in document.runs where run.imageURL != nil {
            if start < run.range.lowerBound {
                parts.append(.init(id: parts.count, content: .text(AttributedString(document[start..<run.range.lowerBound]))))
            }
            parts.append(.init(id: parts.count, content: .image(reference: run.imageURL!.absoluteString,
                alt: String(document[run.range].characters).replacingOccurrences(of: "\u{FFFC}", with: ""))))
            start = run.range.upperBound
        }
        if start < document.endIndex { parts.append(.init(id: parts.count, content: .text(AttributedString(document[start..<document.endIndex])))) }
        return parts
    }
}
