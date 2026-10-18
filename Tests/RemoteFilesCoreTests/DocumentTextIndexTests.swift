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
}
