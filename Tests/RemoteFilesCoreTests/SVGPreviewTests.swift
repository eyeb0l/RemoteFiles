import Foundation
import XCTest
@testable import RemoteFilesCore

final class SVGPreviewTests: XCTestCase {
    func testStaticPathsGradientsTextAndStylesAreReserialized() throws {
        let source = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
        <defs><linearGradient id="paint"><stop offset="0" stop-color="#7047eb"/><stop offset="1" stop-color="#24b4aa"/></linearGradient></defs>
        <rect width="512" height="512" rx="80" fill="url(#paint)"/>
        <path d="M178 142l-74 58 42 65 38-23z" style="fill:#fff;stroke-width:2" transform="translate(1,2)"/>
        <text x="20" y="40">Safe &amp; local 東京</text></svg>
        """
        let result = try SVGPreviewPolicy.prepare(source)
        XCTAssertTrue(result.contains("url(#paint)"))
        XCTAssertTrue(result.contains("Safe &amp; local 東京"))
        XCTAssertTrue(result.contains("</rect>"))
        XCTAssertEqual(DocumentPolicy.kind(filename: "Icon.SVG"), .svg)
        XCTAssertEqual(DocumentPolicy.decode(Data(source.utf8), filename: "icon.svg"), .text(source, markdown: false))
        XCTAssertTrue(try SVGPreviewPolicy.prepare("<svg viewBox=\"0 0 1 1\"><circle r=\"1\"/></svg>").contains("xmlns=\"http://www.w3.org/2000/svg\""))
        XCTAssertTrue(try SVGPreviewPolicy.prepare("<svg width=\"512\" height=\"512px\"><rect width=\"512\" height=\"512\"/></svg>").contains("viewBox=\"0 0 512.0 512.0\""))
    }

    func testMalformedJSONRemainsExactReadableSourceAndLimitsStillApply() {
        let source = "{\n  \"prompt\": \"" + String(repeating: "synthetic sample ", count: 250) + "\n}"
        XCTAssertEqual(DocumentPolicy.decode(Data(source.utf8), filename: "malformed.json"), .text(source, markdown: false))
        XCTAssertEqual(DocumentPolicy.decode(Data(repeating: 0x61, count: DocumentPolicy.previewByteLimit + 1), filename: "large.svg"), .tooLarge)
        XCTAssertEqual(DocumentPolicy.decode(Data([0xFF, 0xFE]), filename: "invalid.svg"), .unsupportedEncodingOrBinary)
    }

    func testScriptExternalResourcesAndCSSCannotEnterRenderer() {
        let unsafe = [
            "<script>alert(1)</script>", "<rect onload=\"alert(1)\"/>",
            "<image href=\"https://example.invalid/pixel\"/>", "<image href=\"file:///private/data\"/>",
            "<use href=\"//example.invalid/icon.svg#x\"/>", "<use href=\"data:image/svg+xml,attack\"/>",
            "<use href=\"javascript:alert(1)\"/>", "<foreignObject><iframe/></foreignObject>",
            "<style>@import url(https://example.invalid/style)</style>",
            "<rect fill=\"url(https://example.invalid/image)\"/>",
            "<rect style=\"fill:url(https://example.invalid/image)\"/>",
            "<rect style=\"fill:u\\72l(https://example.invalid/image)\"/>",
            "<rect style=\"fill:red;animation:spin 1s\"/>", "<animate attributeName=\"href\"/>",
            "<a href=\"https://example.invalid\"><text>Open</text></a>",
            "<svg xmlns=\"http://www.w3.org/1999/xhtml\"/>"
        ]
        for markup in unsafe {
            let source = "<svg xmlns=\"http://www.w3.org/2000/svg\">" + markup + "</svg>"
            XCTAssertThrowsError(try SVGPreviewPolicy.prepare(source), markup)
            XCTAssertEqual(DocumentPolicy.decode(Data(source.utf8), filename: "unsafe.svg"), .text(source, markdown: false), "Source must remain readable")
        }
    }

    func testDeclarationsMalformedAndComplexDocumentsFailWithoutLosingSource() {
        for source in [
            "<!DOCTYPE svg [<!ENTITY attack SYSTEM 'file:///private/data'>]><svg>&attack;</svg>",
            "<?xml-stylesheet href='https://example.invalid/style'?><svg/>",
            "<svg><path></svg>", "<html/>", "<svg/><svg/>",
            "<svg>" + String(repeating: "<g>", count: SVGPreviewPolicy.depthLimit) + String(repeating: "</g>", count: SVGPreviewPolicy.depthLimit) + "</svg>",
            "<svg>" + String(repeating: "<path/>", count: SVGPreviewPolicy.elementLimit) + "</svg>",
            "<svg>" + String(repeating: " ", count: SVGPreviewPolicy.byteLimit) + "</svg>"
        ] { XCTAssertThrowsError(try SVGPreviewPolicy.prepare(source)) }
        XCTAssertNoThrow(try SVGPreviewPolicy.prepare("<svg><title>&lt;script&gt; inert</title><![CDATA[<script>also inert</script>]]></svg>"))
    }
}
