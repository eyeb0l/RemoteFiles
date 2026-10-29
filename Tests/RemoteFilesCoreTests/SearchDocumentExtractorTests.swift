import XCTest
import Foundation
import CoreGraphics
import CoreText
import ImageIO
@testable import RemoteFilesCore

final class SearchDocumentExtractorTests: XCTestCase {
    private func extract(_ data: Data, filename: String, options: SearchExtractionOptions = .init(),
                         deadline: ContinuousClock.Instant = .now + .seconds(30)) async throws -> SearchExtraction {
        try await SearchDocumentExtractor.extract(data, filename: filename, options: options, deadline: deadline)
    }

    private func draw(_ text: String, in context: CGContext, size: CGFloat = 32) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 150)
        CTLineDraw(line, context)
    }

    private func pdf(_ pages: [String], scanned: Bool = false) throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 700, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            if scanned {
                context.draw(try raster(text), in: box)
            } else {
                draw(text, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func raster(_ text: String, width: Int = 1400, height: Int = 600) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(text, in: context, size: 64)
        return try XCTUnwrap(context.makeImage())
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testTextKeepsLiteralSourceAndValidUTF8WithinByteLimit() async throws {
        let result = try await extract(Data("\u{FEFF}<script>東京🙂</script>".utf8), filename: "page.html", options: .init(maxTextBytes: 12))
        XCTAssertEqual(result.segments, [.init(text: "<script>東")])
        XCTAssertTrue(result.isTruncated)
        XCTAssertLessThanOrEqual(result.segments[0].text.utf8.count, 12)
        let empty = try await extract(Data(), filename: "empty.txt")
        XCTAssertTrue(empty.segments.isEmpty)
        XCTAssertFalse(empty.isTruncated)
    }

    func testInvalidUTF8AndBinaryAreRejected() async throws {
        for data in [Data([0xFF]), Data([0, 0x41])] {
            do { _ = try await extract(data, filename: "invalid.txt"); XCTFail("Invalid source must not be indexed") }
            catch SearchExtractionError.unsupported { }
        }
    }

    func testPDFAndImageExtractionRequireExplicitOptions() async throws {
        XCTAssertFalse(SearchDocumentExtractor.supports(filename: "report.PDF", options: .init()))
        XCTAssertTrue(SearchDocumentExtractor.supports(filename: "report.PDF", options: .init(includePDF: true)))
        XCTAssertTrue(SearchDocumentExtractor.supports(filename: "report.PDF", options: .init(includeOCR: true)))
        XCTAssertFalse(SearchDocumentExtractor.supports(filename: "scan.png", options: .init(includePDF: true)))
        XCTAssertTrue(SearchDocumentExtractor.supports(filename: "scan.png", options: .init(includeOCR: true)))
        XCTAssertFalse(SearchDocumentExtractor.supports(filename: "clip.mov", options: .init(includePDF: true, includeOCR: true)))
        do { _ = try await extract(try pdf(["Invoice"]), filename: "report.pdf"); XCTFail("PDF is opt-in") }
        catch SearchExtractionError.unsupported { }
    }

    func testPDFTextCarriesOneBasedPageNumbersAndPageLimit() async throws {
        let data = try pdf(["First page invoice", "Second page receipt", "Third page order"])
        let result = try await extract(data, filename: "report.pdf", options: .init(includePDF: true, maxPages: 2))
        XCTAssertEqual(result.segments.map(\.page), [1, 2])
        XCTAssertTrue(result.segments[0].text.contains("First page invoice"))
        XCTAssertTrue(result.segments[1].text.contains("Second page receipt"))
        XCTAssertTrue(result.isTruncated)
        let all = try await extract(data, filename: "report.pdf", options: .init(includePDF: true))
        XCTAssertEqual(all.segments.count, 3)
        XCTAssertFalse(all.isTruncated)
    }

    func testPDFTextBudgetAppliesAcrossPagesAndZeroLimitsArePartial() async throws {
        let data = try pdf(["Alpha", "Bravo", "Charlie"])
        let result = try await extract(data, filename: "report.pdf", options: .init(includePDF: true, maxTextBytes: 7))
        XCTAssertLessThanOrEqual(result.segments.reduce(0) { $0 + $1.text.utf8.count }, 7)
        XCTAssertEqual(result.segments.map(\.page), [1, 2])
        XCTAssertTrue(result.isTruncated)
        for options in [SearchExtractionOptions(includePDF: true, maxPages: 0), .init(includePDF: true, maxTextBytes: 0)] {
            let none = try await extract(data, filename: "report.pdf", options: options)
            XCTAssertTrue(none.segments.isEmpty)
            XCTAssertTrue(none.isTruncated)
        }
    }

    func testMalformedPDFAndImageFailWithoutOutput() async throws {
        for name in ["broken.pdf", "broken.png"] {
            do {
                _ = try await extract(Data("invalid document".utf8), filename: name, options: .init(includePDF: true, includeOCR: true))
                XCTFail("Malformed document must not become an empty successful extraction")
            } catch SearchExtractionError.invalidDocument { }
        }
    }

    func testOCRFindsTextInImageAndScannedPDFOnlyWhenEnabled() async throws {
        let image = try png(raster("SEARCHABLE INVOICE"))
        let recognized = try await extract(image, filename: "invoice.png", options: .init(includeOCR: true))
        XCTAssertTrue(recognized.segments.contains { $0.text.localizedCaseInsensitiveContains("INVOICE") })
        XCTAssertNil(recognized.segments.first?.page)
        let scanned = try pdf(["SEARCHABLE INVOICE"], scanned: true)
        let withoutOCR = try await extract(scanned, filename: "scan.pdf", options: .init(includePDF: true))
        XCTAssertTrue(withoutOCR.segments.isEmpty)
        let withOCR = try await extract(scanned, filename: "scan.pdf", options: .init(includeOCR: true))
        XCTAssertTrue(withOCR.segments.contains { $0.text.localizedCaseInsensitiveContains("INVOICE") && $0.page == 1 })
    }

    func testOCRRejectsExcessiveSourceDimensionsBeforeDecoding() async throws {
        let image = try png(raster("", width: 32_769, height: 1))
        do { _ = try await extract(image, filename: "wide.png", options: .init(includeOCR: true)); XCTFail() }
        catch SearchExtractionError.imageTooLarge { }
    }

    func testExpiredDeadlineStopsPDFButRetainsAlreadyReadBoundedText() async throws {
        let expired = ContinuousClock.now - .seconds(1)
        do {
            _ = try await extract(try pdf(["Invoice"]), filename: "report.pdf", options: .init(includePDF: true), deadline: expired)
            XCTFail("An expired search must not start PDF extraction")
        } catch SearchExtractionError.deadlineExceeded { }
        let text = try await extract(Data("needle".utf8), filename: "a.txt", deadline: expired)
        XCTAssertEqual(text.segments, [.init(text: "needle")])
    }

    func testCancellationDoesNotPublishExtractedText() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await extract(Data("needle".utf8), filename: "a.txt")
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
    }
}
