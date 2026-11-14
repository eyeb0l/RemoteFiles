import Foundation
import XCTest
@testable import RemoteFilesCore

final class DocumentTextIndexTests: XCTestCase {
    func testHeadingsUseParsedStructureAndUniqueUnicodeSlugs() throws {
        let index = try DocumentTextIndex(text: "# **Hello** *world*!\n\n## Hello world!\n\nHello world!\n---\n\n### 東京 résumé\n\n```md\n# not a heading\n```\n", markdown: true)
        XCTAssertEqual(index.headings.map(\.title), ["Hello world!", "Hello world!", "Hello world!", "東京 résumé"])
        XCTAssertEqual(index.headings.map(\.id), ["hello-world", "hello-world-1", "hello-world-2", "東京-résumé"])
        XCTAssertEqual(index.headings.map(\.level), [1, 2, 2, 3])
        XCTAssertEqual(index.heading(fragment: "東京-résumé")?.title, "東京 résumé")
        XCTAssertNil(index.heading(fragment: "missing"))
    }

    func testRenderedSearchSkipsMarkupDestinationsAndReturnsExactUTF16Ranges() throws {
        let index = try DocumentTextIndex(text: "# Café\n\n🌍 Café **CAFE** [label](secret.md)\n\n![diagram](image.png)\n\nCafé", markdown: true)
        let matches = try index.matches("cafe", inSource: false)
        XCTAssertEqual(matches.targets.count, 4)
        XCTAssertFalse(matches.truncated)
        for target in matches.targets {
            guard case .text(let text) = index.parts.first(where: { $0.id == target.partID })?.content else { return XCTFail("Missing text part") }
            let found = (String(text.characters) as NSString).substring(with: target.range)
            XCTAssertTrue(["Café", "CAFE"].contains(found))
        }
        XCTAssertTrue(try index.matches("secret", inSource: false).targets.isEmpty)
        XCTAssertEqual(try index.matches("secret", inSource: true).targets.count, 1)
        XCTAssertEqual(try index.matches("🌍", inSource: false).targets.first?.range.length, 2)
    }

    /// Source is the only way to read a document the renderer refuses, so Find must still work there.
    func testARefusedDocumentKeepsSourceSearchAndOffersNothingRendered() throws {
        let text = "# Title\n\n" + String(repeating: ">", count: MarkdownLimits.maximumDepth) + " quoted needle\n\nAnother needle"
        XCTAssertThrowsError(try DocumentPolicy.remoteMarkdownParts(text))
        let index = try DocumentTextIndex(text: text, markdown: true)
        XCTAssertTrue(index.isSourceOnly)
        XCTAssertTrue(index.parts.isEmpty)
        XCTAssertNil(index.renderableParts, "A reader must not show the missing parts as an empty document")
        XCTAssertTrue(index.headings.isEmpty)
        XCTAssertNil(index.heading(fragment: ""))
        let inSource = try index.matches("NEEDLE", inSource: true)
        XCTAssertEqual(inSource.targets.map { (text as NSString).substring(with: $0.range) }, ["needle", "needle"])
        XCTAssertTrue(inSource.targets.allSatisfy { $0.partID == nil })
        XCTAssertTrue(try index.matches("needle", inSource: false).targets.isEmpty, "Nothing is rendered to search")

        let rendered = try DocumentTextIndex(text: "# Title\n\n> quoted needle", markdown: true)
        XCTAssertFalse(rendered.isSourceOnly)
        XCTAssertEqual(rendered.renderableParts?.count, rendered.parts.count)
        XCTAssertEqual(try DocumentTextIndex(text: "", markdown: true).renderableParts?.count, 0, "An empty document is rendered as empty")
        XCTAssertFalse(try DocumentTextIndex(text: text, markdown: false).isSourceOnly, "Plain text was never Markdown")
    }

    func testInlineImagesKeepOneHeadingAndRevealTheFirstAvailableTextPart() throws {
        let text = """
        # Before ![badge](badge.png) **After**

        ![unrelated](ordinary.png)

        # ![lead](lead.png) Leading

        # Trailing ![tail](tail.png)

        # ![standalone](only.png)

        # Before ![badge](badge.png) **After**
        """
        let index = try DocumentTextIndex(text: text, markdown: true)
        XCTAssertEqual(index.headings.map(\.title), ["Before badge After", "lead Leading", "Trailing tail", "Before badge After"])
        XCTAssertEqual(index.headings.map(\.id), ["before-badge-after", "lead-leading", "trailing-tail", "before-badge-after-1"])
        XCTAssertEqual(index.heading(fragment: "before-badge-after")?.title, "Before badge After")
        XCTAssertNil(index.heading(fragment: "standalone"), "Image-only headings have no selectable text geometry")
        for (heading, expected) in zip(index.headings, ["Before", "Leading", "Trailing", "Before"]) {
            guard case .text(let attributed) = index.parts.first(where: { $0.id == heading.target.partID })?.content else {
                return XCTFail("Heading target must belong to a text part")
            }
            XCTAssertEqual((String(attributed.characters) as NSString).substring(with: heading.target.range)
                .trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
        // Keep the index's split policy identical to the renderer's public preparation path.
        let expectedParts = try DocumentPolicy.remoteMarkdownParts(text)
        XCTAssertEqual(index.parts.count, expectedParts.count)
        for (actual, expected) in zip(index.parts, expectedParts) {
            XCTAssertEqual(actual.id, expected.id)
            switch (actual.content, expected.content) {
            case (.text(let lhs), .text(let rhs)): XCTAssertEqual(lhs, rhs)
            case (.image(let lhs, let lhsAlt), .image(let rhs, let rhsAlt)):
                XCTAssertEqual(lhs, rhs); XCTAssertEqual(lhsAlt, rhsAlt)
            default: XCTFail("Index and renderer parts must agree")
            }
        }
    }

    func testSearchIsLiteralBoundedAndDoesNotAlterSource() throws {
        let text = "e\u{301} [x] [x] [x]\n"
        let index = try DocumentTextIndex(text: text, markdown: false)
        let matches = try index.matches("[x]", inSource: true, limit: 2)
        XCTAssertEqual(matches.targets.count, 2); XCTAssertTrue(matches.truncated)
        XCTAssertEqual(matches.targets.first?.range, NSRange(location: 3, length: 3))
        XCTAssertTrue(try index.matches("", inSource: true).targets.isEmpty)
        XCTAssertTrue(try index.matches("missing", inSource: true).targets.isEmpty)
        XCTAssertEqual(Data(index.source.utf8), Data(text.utf8))
    }

    /// Leaving the reader cancels its preparation, which must stop rather than record the document
    /// as one the limits refused.
    func testCancelledPreparationThrowsInsteadOfRefusingTheDocument() async throws {
        let text = String(repeating: "# Heading\n\nText with *emphasis* and ![image](i.png).\n\n- [ ] task\n\n", count: 2_000)
        let results = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return (Result { try DocumentTextIndex(text: text, markdown: true) },
                    Result { try DocumentPolicy.prepareMarkdown(text, preserveImages: true, preserveDocumentLinks: true) },
                    Result { try DocumentPolicy.remoteMarkdownParts(text) })
        }.value
        XCTAssertThrowsError(try results.0.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertThrowsError(try results.1.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertThrowsError(try results.2.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        // Outside a cancelled task the same text prepares as usual.
        XCTAssertFalse(try DocumentTextIndex(text: text, markdown: true).isSourceOnly)
    }

    // MARK: - One parse gives what separate parses gave

    /// Documents of every shape the reader meets: this repository's own documentation, the demo's
    /// documents and small cases for each rule the preparation applies.
    private static var equivalenceCorpus: [(String, String)] {
        var corpus: [(String, String)] = [
            ("rich", DemoRemoteFileService.richMarkdown), ("navigation", DemoRemoteFileService.navigationGuide),
            ("linked", DemoRemoteFileService.linkedNotes), ("headings", DemoRemoteFileService.headingNotes),
            ("report", DemoRemoteFileService.report),
            ("empty", ""), ("blank", "\n\n  \n"), ("image only", "![only](only.png)"), ("bare image", "![](x.png)"),
            ("inline images", "# Before ![badge](badge.png) **After**\n\n![unrelated](ordinary.png)\n\n# ![lead](lead.png) Leading\n\n# Trailing ![tail](tail.png)\n\n# ![standalone](only.png)\n\n# Before ![badge](badge.png) **After**"),
            ("headings", "# **Hello** *world*!\n\n## Hello world!\n\nHello world!\n---\n\nSetext\n======\n\n### 東京 résumé\n\n```md\n# not a heading\n```\n\n# Hello world!-1\n\n# Hello world!"),
            ("tasks", "- [x] Complete\n- [ ] Pending\n- [X] Upper\n- `[x]` is literal code\n- [ ]\n- [ ]no space\n1. [ ] numbered\n   [ ] continuation\n\n  - [x] nested *task*\n\n> - [ ] quoted task"),
            ("links", "[Allowed](https://example.com) [Plain](http://example.com) [Relative](other.md) [Fragment](#heading) [Query](?q=1) [Unsafe](javascript:alert%281%29) [File](file:///etc/passwd) [Mail](mailto:a@example.com) <https://auto.example> [Shown https://bank.example](https://evil.example/) [Absolute](/etc/x.md) [Back](..\\x.md) [User](https://user:pw@example.com)"),
            ("images", "![External alt](https://example.invalid/x.png)\n![Local](file:///private/secret.png)\n![](data:image/png;base64,aGVsbG8=)\n\nText ![inline **bold** alt](a.png) more ![](b.png)\n\n[![linked image](c.png)](https://example.com)"),
            ("many images", (0..<(MarkdownLimits.maximumImages + 5)).map { "![alt \($0)](images/\($0).png)" + ($0 % 7 == 0 ? "\n\n# Heading \($0)" : " text ") }.joined(separator: "\n\n")),
            ("code", "Inline `Array<String>` and `$x$`.\n\n```\n$not math$ <div>\n```\n\n    indented <b>\n\n```mermaid\ngraph TD; A-->B\n```\n"),
            ("math", "Euler: $e^{i\\pi} + 1 = 0$ and \\(a\\) and $$x$$\n\n\\[ y \\]\n\nPrices $5 and $6 stay text. Escaped \\$ too."),
            ("html", "<details><summary>More</summary>\n\nHidden **text**\n\n</details>\n\nInline <kbd>Ctrl</kbd> and <unknown> tag.\n\n<script>alert(1)</script>"),
            ("tables", "| A | B |\n| :-- | --: |\n| `a|b` | **x** |\n| [l](https://example.com) | ![i](i.png) |\n\nText after"),
            ("nesting", "> quote\n> > deeper\n> > - list\n> >   1. ordered\n> >      > deepest **bold**\n\n" + (0..<10).map { String(repeating: "  ", count: $0) + "- item \($0)" }.joined(separator: "\n")),
            ("crlf", "# Title\r\n\r\nLine one\r\nline two\r\n\r\n- [ ] task\r\n"),
            ("unicode", "# Café 🌍\n\ne\u{301} combining, 👩‍👩‍👧 family, عربى, \u{FEFF}bom, tab\there.\n\n## Café 🌍\n\nReplacement \u{FFFC} character."),
            ("breaks", "Soft\nbreak and hard  \nbreak and backslash\\\nbreak.\n\n***\n\n---\n\nEnd"),
            ("footnotes and strikes", "Text~~struck~~ and ~single~ and footnote[^1].\n\n[^1]: The note.\n\n[ref]: https://example.com\n\nUse [ref] and [ref][]."),
            ("refused depth", "# Title\n\n" + String(repeating: ">", count: MarkdownLimits.maximumDepth) + " deep"),
            ("refused width", "|" + String(repeating: "a|", count: MarkdownLimits.maximumBarsPerLine)),
        ]
        // Ordinary long writing, generated with headings, tasks and images throughout.
        corpus.append(("long", (1...400).map { section in
            "## Section \(section)\n\nProse with **bold**, *emphasis*, `code` and a [link](https://example.com/\(section)).\n\n- [ ] task \(section)\n- item\n\n" + (section % 9 == 0 ? "![shot \(section)](shot\(section).png)\n\n" : "")
        }.joined()))
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = docs.appendingPathComponent("README.md")
        for url in [readme] + ((try? FileManager.default.contentsOfDirectory(at: docs.appendingPathComponent("docs"), includingPropertiesForKeys: nil)) ?? [])
        where url.pathExtension == "md" {
            if let text = try? String(contentsOf: url, encoding: .utf8) { corpus.append((url.lastPathComponent, text)) }
        }
        return corpus
    }

    func testOneParseGivesThePartsHeadingsFindResultsAndRendererOfSeparateParses() throws {
        let corpus = Self.equivalenceCorpus
        var refused = 0, enhanced = 0
        for (name, text) in corpus {
            let index = try DocumentTextIndex(text: text, markdown: true)
            let reference = try ReferenceMarkdownIndex(text)
            XCTAssertEqual(index.isSourceOnly, reference.parts == nil, name)
            if index.isSourceOnly { refused += 1 }
            XCTAssertEqual(index.requiresEnhancedRendering, reference.parts != nil && EnhancedMarkdownPolicy.requiresEnhancedRendering(text), name)
            if index.requiresEnhancedRendering { enhanced += 1 }
            guard let expected = reference.parts else { continue }
            Self.assertSameParts(index.parts, expected, name)
            // The public route the renderer had used gives the same parts too.
            Self.assertSameParts(try DocumentPolicy.remoteMarkdownParts(text), expected, name)
            XCTAssertEqual(index.headings, reference.headings, name)
            XCTAssertEqual(index.linksNeedingConfirmation, ExternalLinkPolicy.linksNeedingConfirmation(in: expected), name)
            XCTAssertEqual(index.heading(fragment: ""), reference.top, name)
            for query in ["e", "the", "Image", "☐", "é", "🌍", "[", " ", "preview unavailable"] {
                XCTAssertEqual(try index.matches(query, inSource: false).targets, reference.matches(query), "\(name): \(query)")
                XCTAssertEqual(try index.matches(query, inSource: true).targets.count, reference.sourceMatches(query, in: text), "\(name): \(query)")
            }
        }
        if FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs").path) {
            XCTAssertGreaterThan(corpus.count, 40, "The repository's documentation is part of the corpus")
        }
        XCTAssertEqual(refused, 2)
        XCTAssertGreaterThan(enhanced, 2, "Documents for the rich renderer are covered")
    }

    /// The renderer check needs source positions, which split runs; without them the document must be
    /// the one an ordinary parse gives, attribute for attribute.
    func testSourcePositionsLeaveNoTraceInThePreparedDocument() throws {
        for (name, text) in Self.equivalenceCorpus where (try? MarkdownLimits.checkSource(text)) != nil {
            var positioned = try AttributedString(markdown: text, options: .init(appliesSourcePositionAttributes: true))
            positioned.markdownSourcePosition = nil
            let plain = try AttributedString(markdown: text)
            XCTAssertEqual(positioned, plain, name)
            XCTAssertEqual(positioned.runs.count, plain.runs.count, name)
            if let prepared = try? DocumentPolicy.prepareMarkdown(text, preserveImages: true, preserveDocumentLinks: true,
                                                                  checkingEnhancedRendering: true).document {
                XCTAssertFalse(prepared.runs.contains { $0.markdownSourcePosition != nil }, name)
                XCTAssertEqual(prepared, try DocumentPolicy.prepareMarkdown(text, preserveImages: true, preserveDocumentLinks: true), name)
            }
        }
    }

    private static func assertSameParts(_ actual: [MarkdownPart], _ expected: [MarkdownPart], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, name, file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            XCTAssertEqual(lhs.id, rhs.id, name, file: file, line: line)
            switch (lhs.content, rhs.content) {
            case (.text(let lhs), .text(let rhs)): XCTAssertEqual(lhs, rhs, name, file: file, line: line)
            case (.image(let lhs, let lhsAlt), .image(let rhs, let rhsAlt)):
                XCTAssertEqual(lhs, rhs, name, file: file, line: line); XCTAssertEqual(lhsAlt, rhsAlt, name, file: file, line: line)
            default: XCTFail("\(name): part \(lhs.id) differs in kind", file: file, line: line)
            }
        }
    }
}

/// The reader's preparation as it was before parts, index and renderer check shared one parse, kept
/// verbatim as the reference the current one must match.
private struct ReferenceMarkdownIndex {
    var parts: [MarkdownPart]?
    var headings: [DocumentHeading] = []
    var rendered: [(Int, String)] = []
    var top: DocumentHeading? {
        guard let first = rendered.first, let character = first.1.first else { return headings.first { $0.id == "" } }
        return .init(id: "", title: "Top", level: 1, target: .init(partID: first.0, range: NSRange(location: 0, length: String(character).utf16.count)))
    }

    func matches(_ query: String) -> [DocumentTextTarget] {
        var targets: [DocumentTextTarget] = []
        for (part, text) in rendered {
            let string = text as NSString
            var start = 0
            while start < string.length, targets.count < 1_000 {
                let range = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: string.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                targets.append(.init(partID: part, range: range)); start = NSMaxRange(range)
            }
        }
        return targets
    }

    func sourceMatches(_ query: String, in source: String) -> Int {
        let string = source as NSString
        var start = 0, count = 0
        while start < string.length, count < 1_000 {
            let range = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: string.length - start))
            guard range.location != NSNotFound, range.length > 0 else { break }
            count += 1; start = NSMaxRange(range)
        }
        return count
    }

    private static func prepare(_ source: String) throws -> AttributedString {
        try MarkdownLimits.checkSource(source)
        var document = try AttributedString(markdown: source)
        let runs = Array(document.runs)
        try MarkdownLimits.checkStructure(runs)
        var extraImages = max(0, runs.count { $0.imageURL != nil } - MarkdownLimits.maximumImages)
        for run in runs.reversed() {
            let isExtraImage = run.imageURL != nil && extraImages > 0
            if isExtraImage { extraImages -= 1 }
            if run.imageURL != nil && isExtraImage {
                let alt = String(document[run.range].characters)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var replacement = AttributedString(alt.isEmpty ? "[Image preview unavailable]" : "[Image: \(alt) — preview unavailable]")
                replacement.setAttributes(run.attributes)
                replacement.imageURL = nil
                replacement.link = nil
                replacement.inlinePresentationIntent = .emphasized
                document.replaceSubrange(run.range, with: replacement)
            } else if let link = run.link, !DocumentPolicy.allowsExternalLink(link), !DocumentPolicy.isRelativeDocumentLink(link) {
                document[run.range].link = nil
            }
        }
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

    init(_ text: String) throws {
        guard let document = try? Self.prepare(text) else { parts = nil; return }
        var preparedParts: [MarkdownPart] = []
        var textSlices: [(id: Int, range: Range<AttributedString.Index>)] = []
        func appendText(_ range: Range<AttributedString.Index>) {
            guard !range.isEmpty else { return }
            let value = AttributedString(document[range]), id = preparedParts.count
            preparedParts.append(.init(id: id, content: .text(value)))
            textSlices.append((id, range))
            rendered.append((id, String(value.characters)))
        }
        var start = document.startIndex
        for run in document.runs where run.imageURL != nil {
            appendText(start..<run.range.lowerBound)
            preparedParts.append(.init(id: preparedParts.count, content: .image(reference: run.imageURL!.absoluteString,
                alt: String(document[run.range].characters).replacingOccurrences(of: "\u{FFFC}", with: ""))))
            start = run.range.upperBound
        }
        appendText(start..<document.endIndex)

        var usedIDs: Set<String> = []
        var nextSuffix: [String: Int] = [:]
        var currentID: Int?, currentLevel = 0, currentTitle = ""
        var currentTarget: DocumentTextTarget?
        var headings: [DocumentHeading] = []
        func finishHeading() {
            let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let target = currentTarget else { return }
            let base = DocumentTextIndex.slug(title)
            var suffix = nextSuffix[base, default: 0]
            var id = suffix == 0 ? base : "\(base)-\(suffix)"
            while usedIDs.contains(id) { suffix += 1; id = "\(base)-\(suffix)" }
            nextSuffix[base] = suffix + 1
            usedIDs.insert(id)
            headings.append(.init(id: id, title: title, level: currentLevel, target: target))
        }
        var sliceIndex = 0, sliceOffset = 0
        for run in document.runs {
            let value = String(document[run.range].characters)
            let heading = run.presentationIntent?.components.first(where: { if case .header = $0.kind { return true }; return false })
            if heading?.identity != currentID {
                finishHeading(); currentTitle = ""; currentTarget = nil
                currentID = heading?.identity
            }
            var runTarget: DocumentTextTarget?
            if run.imageURL == nil {
                while sliceIndex < textSlices.count, run.range.lowerBound >= textSlices[sliceIndex].range.upperBound {
                    sliceIndex += 1; sliceOffset = 0
                }
                if sliceIndex < textSlices.count {
                    runTarget = .init(partID: textSlices[sliceIndex].id, range: NSRange(location: sliceOffset, length: value.utf16.count))
                    sliceOffset += value.utf16.count
                }
            }
            if let heading, case .header(let level) = heading.kind {
                currentLevel = level
                currentTitle += value.replacingOccurrences(of: "\u{FFFC}", with: "")
                if let target = runTarget {
                    if let previous = currentTarget {
                        if previous.partID == target.partID, NSMaxRange(previous.range) == target.range.location {
                            currentTarget = .init(partID: previous.partID,
                                range: NSRange(location: previous.range.location, length: previous.range.length + target.range.length))
                        }
                    } else if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { currentTarget = target }
                }
            }
        }
        finishHeading()
        parts = preparedParts; self.headings = headings
    }
}
