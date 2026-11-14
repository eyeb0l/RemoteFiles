import Foundation

public enum DocumentKind: Equatable, Sendable {
    case markdown, plainText, html, svg, image, pdf, video, audio, certificate, protectedCertificate, unsupported

    /// Never text: these have no Source, Find or copy route, and no search reads them.
    public var isCertificateFile: Bool { self == .certificate || self == .protectedCertificate }
}

public enum DocumentPreview: Equatable, Sendable {
    /// `hiddenKeys` counts the private keys `PrivateKeyRedaction` hid in the text.
    case text(String, markdown: Bool, hiddenKeys: Int = 0)
    /// The file is nothing but private keys, so none of its text is kept.
    case privateKey
    case empty
    case unsupportedFileType
    case unsupportedEncodingOrBinary
    case tooLarge

    /// Whether the reader may hold on to the bytes this came from. A hidden key is still in the
    /// original bytes, and text the app couldn't decode can't be checked for one.
    public var allowsKeepingOriginalBytes: Bool {
        switch self {
        case .text(_, _, let hiddenKeys): return hiddenKeys == 0
        case .empty: return true
        case .privateKey, .unsupportedFileType, .unsupportedEncodingOrBinary, .tooLarge: return false
        }
    }
}

/// The reader's local policy. The transport must also enforce the limit while receiving bytes.
public enum DocumentPolicy {
    public static let previewByteLimit = 2 * 1_024 * 1_024

    static let searchTextExtensions: Set<String> = [
        "txt", "text", "log", "json", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "conf", "config",
        "env", "properties", "csv", "tsv", "xml", "html", "htm", "css", "scss", "less", "svg", "sql",
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "php", "java", "kt",
        "kts", "js", "jsx", "ts", "tsx", "sh", "bash", "zsh", "fish", "ps1", "r", "lua", "dart",
        "vue", "svelte", "graphql", "gql", "gitignore", "gitattributes", "editorconfig", "lock",
        "rst", "adoc", "diff", "patch", "ipynb", "proto", "tf", "tfvars", "cfg", "bat", "mk",
    ]

    static let searchExcludedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp", "pdf",
        "mp4", "m4v", "mov", "3gp", "3g2", "mp3", "m4a", "m4b", "aac", "wav", "wave", "aif",
        "aiff", "aifc", "caf", "flac", "ac3", "eac3",
        "pem", "crt", "cer", "der", "p7b", "p7c", "csr", "p12", "pfx"
    ]

    /// Told apart by their content, since `.cer` and `.crt` are commonly either PEM or DER.
    static let certificateExtensions: Set<String> = ["pem", "crt", "cer", "der", "p7b", "p7c", "csr"]
    /// Password-protected PKCS #12 containers, which are never opened.
    static let protectedCertificateExtensions: Set<String> = ["p12", "pfx"]

    public static func kind(filename: String) -> DocumentKind {
        let name = RemotePath.components(of: filename).last.map(String.init)?.lowercased() ?? ""
        let suffix = name.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if ["md", "markdown"].contains(suffix) { return .markdown }
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp"].contains(suffix) { return .image }
        if suffix == "pdf" { return .pdf }
        if ["mp4", "m4v", "mov", "3gp", "3g2"].contains(suffix) { return .video }
        if ["mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "ac3", "eac3"].contains(suffix) { return .audio }
        if suffix == "svg" { return .svg }
        if ["html", "htm"].contains(suffix) { return .html }
        // Ahead of the dotfile rule, which would otherwise show `.server.pem` as text. A file
        // that is only named `pem` has no extension, so it stays a text candidate.
        if name.contains(".") {
            if certificateExtensions.contains(suffix) { return .certificate }
            if protectedCertificateExtensions.contains(suffix) { return .protectedCertificate }
        }

        // Extensionless names (including dotfiles) are candidates; byte validation remains mandatory.
        if !name.contains(".") || RemotePath.isHidden(name) || searchTextExtensions.contains(suffix) { return .plainText }
        return .unsupported
    }

    public static func decode(_ data: Data, filename: String, maxBytes: Int = previewByteLimit) -> DocumentPreview {
        guard data.count <= max(0, maxBytes) else { return .tooLarge }
        guard !data.isEmpty else { return .empty }
        let kind = kind(filename: filename)
        guard kind == .plainText || kind == .markdown || kind == .html || kind == .svg else { return .unsupportedFileType }
        // NUL and other non-whitespace C0 controls are a deliberate binary signal even in valid UTF-8.
        guard !data.contains(where: { ($0 < 0x20 && ![0x09, 0x0A, 0x0D].contains($0)) || $0 == 0x7F }),
              var text = String(data: data, encoding: .utf8) else { return .unsupportedEncodingOrBinary }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        guard !text.isEmpty else { return .empty }
        // Every text route comes through here, so a key is gone before any view, cache or index
        // sees it, and before a search clips the text to its budget.
        let redacted = PrivateKeyRedaction.redact(text)
        if redacted.isOnlyKeys { return .privateKey }
        return .text(redacted.text, markdown: kind == .markdown, hiddenKeys: redacted.hiddenKeys)
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

    /// Relative link actions are retained only for an explicitly injected remote navigation handler.
    /// Full confinement and file validation happen after the user taps, using the server's canonical root.
    public static func isRelativeDocumentLink(_ url: URL) -> Bool {
        guard url.baseURL == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == nil, parts.host == nil, parts.user == nil, parts.password == nil,
              let path = parts.percentEncodedPath.removingPercentEncoding,
              !RemotePath.isAbsolute(path), !RemotePath.hasBackslash(path),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !RemotePath.startsWithDoubledSeparator(url.absoluteString) else { return false }
        // Keep fragments/queries actionable so the navigation policy can explain their limitation.
        return !path.isEmpty || parts.fragment != nil || parts.query != nil
    }

    /// Foundation is the same CommonMark/GFM parser used by Textual. This performs only
    /// attributed-output policy/formatting, never Markdown syntax parsing or resource loading.
    /// Invoke away from the main actor for substantial reports.
    ///
    /// Throws `MarkdownLimitError` for a document whose structure costs far more than its size
    /// suggests; the reader then offers its source instead.
    public static func prepareMarkdown(_ source: String, preserveImages: Bool = false, preserveDocumentLinks: Bool = false) throws -> AttributedString {
        try MarkdownLimits.checkSource(source)
        var document = try AttributedString(markdown: source)
        let runs = Array(document.runs)
        try MarkdownLimits.checkStructure(runs)
        // Each kept image becomes a view of its own and divides the text around it.
        var extraImages = preserveImages ? max(0, runs.count { $0.imageURL != nil } - MarkdownLimits.maximumImages) : 0
        // Replace image runs before handing content to Textual, so its default image loader never
        // receives a URL. Keep readable alt text, including for relative/data/file image URLs.
        for run in runs.reversed() {
            let isExtraImage = run.imageURL != nil && extraImages > 0
            if isExtraImage { extraImages -= 1 }
            if run.imageURL != nil && (!preserveImages || isExtraImage) {
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
            } else if let link = run.link, !allowsExternalLink(link),
                      !(preserveDocumentLinks && isRelativeDocumentLink(link)) {
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


public enum MarkdownLimitError: Error, Equatable, Sendable {
    case tooManyMarkers, tableTooWide, tooDeeplyNested, tooManyRuns
}

/// Bounds on what one Markdown document may ask of the parser and the renderer. A file within the
/// preview's byte limit can still nest hundreds of blocks, give a table thousands of columns or
/// change formatting every few bytes, and each of those costs far more than ordinary writing.
public enum MarkdownLimits {
    /// Images shown from one document; later ones become their alternative text.
    public static let maximumImages = 128
    /// Block levels around any text. The renderer builds a view inside a view for each, and a few
    /// hundred overflow its stack. Ten nested lists use about twenty.
    public static let maximumDepth = 32
    /// Stretches of text that differ in formatting or block. Each costs the parser about ten
    /// microseconds and 700 bytes; a megabyte and a half of ordinary formatted prose has about 100,000.
    public static let maximumRuns = 200_000
    /// Line breaks and formatting characters, counted before parsing: no run begins without one,
    /// so this bounds the parse itself, which cannot be interrupted once started.
    public static let maximumMarkers = 250_000
    /// Vertical bars on one line. Parsing a table row costs the square of its columns.
    public static let maximumBarsPerLine = 256

    static func checkSource(_ source: String) throws {
        var markers = 0, bars = 0, previous: UInt8 = 0
        for byte in source.utf8 {
            defer { previous = byte }
            switch byte {
            case 0x0A where previous == 0x0D: // The line feed of CRLF ends the same line.
                continue
            case 0x0A, 0x0D: // Line feed or carriage return, both line endings in Markdown
                markers += 1; bars = 0
            case 0x7C: // |
                markers += 1; bars += 1
                if bars > maximumBarsPerLine { throw MarkdownLimitError.tableTooWide }
            case 0x2A, 0x5F, 0x60, 0x5B, 0x7E, 0x3C: // * _ ` [ ~ <
                markers += 1
            default: continue
            }
            if markers > maximumMarkers { throw MarkdownLimitError.tooManyMarkers }
        }
    }

    static func checkStructure(_ runs: [AttributedString.Runs.Run], maximumRuns: Int = maximumRuns) throws {
        guard runs.count <= maximumRuns else { throw MarkdownLimitError.tooManyRuns }
        for run in runs where (run.presentationIntent?.components.count ?? 0) > maximumDepth {
            throw MarkdownLimitError.tooDeeplyNested
        }
    }
}

public struct MarkdownPart: Identifiable, Sendable {
    public enum Content: Sendable { case text(AttributedString), image(reference: String, alt: String) }
    public let id: Int
    public let content: Content
}

public extension DocumentPolicy {
    static func remoteMarkdownParts(_ source: String) throws -> [MarkdownPart] {
        let document = try prepareMarkdown(source, preserveImages: true, preserveDocumentLinks: true)
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
