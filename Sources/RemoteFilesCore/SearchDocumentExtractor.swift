import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Vision

public struct SearchTextSegment: Codable, Sendable, Equatable {
    public let text: String
    /// One-based PDF page number; source text and images have no page number.
    public let page: Int?
    public init(text: String, page: Int? = nil) { self.text = text; self.page = page }
}

public struct SearchExtraction: Sendable {
    public let segments: [SearchTextSegment]
    public let isTruncated: Bool
    public init(segments: [SearchTextSegment], isTruncated: Bool = false) {
        self.segments = segments; self.isTruncated = isTruncated
    }
}

public struct SearchExtractionOptions: Sendable, Equatable, Codable {
    /// Read embedded PDF text. With OCR enabled, pages without included text are recognized.
    public var includePDF: Bool
    /// Recognize images and PDF pages; when includePDF is false, all PDF pages use OCR.
    public var includeOCR: Bool
    public var maxPages: Int
    public var maxTextBytes: Int
    public init(includePDF: Bool = false, includeOCR: Bool = false, maxPages: Int = 20, maxTextBytes: Int = 262_144) {
        self.includePDF = includePDF; self.includeOCR = includeOCR
        self.maxPages = maxPages; self.maxTextBytes = maxTextBytes
    }
}

public enum SearchExtractionError: Error, Sendable {
    case unsupported, invalidDocument, imageTooLarge, deadlineExceeded
}

/// Extracts searchable text locally without following document links or writing originals to disk.
/// The caller also bounds transferred bytes. Framework parsing is synchronous: cancellation and
/// deadlines are checked between stages and before publishing, and active Vision requests cancel.
public enum SearchDocumentExtractor {
    private static let maximumTextBytes = 262_144
    private static let maximumPages = 100
    private static let rasterDimension = 2_048

    public static func supports(filename: String, options: SearchExtractionOptions) -> Bool {
        switch DocumentPolicy.kind(filename: filename) {
        case .plainText, .markdown, .html, .svg: return true
        case .pdf: return options.includePDF || options.includeOCR
        case .image: return options.includeOCR
        default: return false
        }
    }

    public static func extract(_ data: Data, filename: String, options: SearchExtractionOptions,
                               deadline: ContinuousClock.Instant) async throws -> SearchExtraction {
        try Task.checkCancellation()
        guard data.count <= DocumentPolicy.previewByteLimit else { throw RemoteFileError.tooLarge(DocumentPolicy.previewByteLimit) }
        guard supports(filename: filename, options: options) else { throw SearchExtractionError.unsupported }
        let textLimit = min(max(0, options.maxTextBytes), maximumTextBytes)
        switch DocumentPolicy.kind(filename: filename) {
        case .pdf:
            try check(deadline)
            return try await extractPDF(data, options: options, textLimit: textLimit, deadline: deadline)
        case .image:
            try check(deadline)
            let (image, multipleFrames) = try image(data)
            try check(deadline)
            let text = try await recognize(image, textLimit: textLimit, deadline: deadline)
            return SearchExtraction(segments: text.value.isEmpty ? [] : [.init(text: text.value)],
                                    isTruncated: multipleFrames || text.truncated)
        default:
            let result: SearchExtraction
            switch DocumentPolicy.decode(data, filename: filename) {
            case .text(let text, _):
                let clipped = prefix(text, byteLimit: textLimit)
                result = SearchExtraction(segments: clipped.value.isEmpty ? [] : [.init(text: clipped.value)], isTruncated: clipped.truncated)
            case .empty: result = SearchExtraction(segments: [])
            default: throw SearchExtractionError.unsupported
            }
            try Task.checkCancellation()
            return result
        }
    }

    private static func extractPDF(_ data: Data, options: SearchExtractionOptions, textLimit: Int,
                                   deadline: ContinuousClock.Instant) async throws -> SearchExtraction {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
            throw SearchExtractionError.invalidDocument
        }
        try check(deadline)
        let pages = min(document.pageCount, min(max(0, options.maxPages), maximumPages))
        var remaining = textLimit, segments: [SearchTextSegment] = []
        var truncated = pages < document.pageCount
        for index in 0..<pages {
            try check(deadline)
            guard remaining > 0 else { truncated = true; break }
            guard let page = document.page(at: index) else { throw SearchExtractionError.invalidDocument }
            let characters = options.includePDF ? page.numberOfCharacters : 0
            try check(deadline)
            // Selecting a bounded prefix avoids materializing an entire PDF page's text.
            let selected = min(characters, remaining)
            let embedded = selected > 0 ? page.selection(for: NSRange(location: 0, length: selected))?.string ?? "" : ""
            try check(deadline)
            var text = prefix(embedded, byteLimit: remaining)
            text.truncated = text.truncated || characters > selected
            if embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, options.includeOCR {
                let raster = try render(page)
                try check(deadline)
                text = try await recognize(raster, textLimit: remaining, deadline: deadline)
            }
            try check(deadline)
            if !text.value.isEmpty {
                segments.append(.init(text: text.value, page: index + 1))
                remaining -= text.value.utf8.count
            }
            truncated = truncated || text.truncated
        }
        try check(deadline)
        return SearchExtraction(segments: segments, isTruncated: truncated)
    }

    private static func image(_ data: Data) throws -> (CGImage, Bool) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw SearchExtractionError.invalidDocument }
        let w = width.doubleValue, h = height.doubleValue
        guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 32_768, h <= 32_768, w * h <= 40_000_000 else {
            throw SearchExtractionError.imageTooLarge
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: rasterDimension
        ] as CFDictionary) else { throw SearchExtractionError.invalidDocument }
        return (image, CGImageSourceGetCount(source) > 1)
    }

    private static func render(_ page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        guard let reference = page.pageRef, bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw SearchExtractionError.invalidDocument
        }
        let scale = min(CGFloat(rasterDimension) / bounds.width, CGFloat(rasterDimension) / bounds.height)
        guard scale.isFinite, scale > 0 else { throw SearchExtractionError.invalidDocument }
        let quarterTurn = abs(page.rotation % 180) == 90
        let width = max(1, min(rasterDimension, Int(ceil((quarterTurn ? bounds.height : bounds.width) * scale))))
        let height = max(1, min(rasterDimension, Int(ceil((quarterTurn ? bounds.width : bounds.height) * scale))))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SearchExtractionError.invalidDocument
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.fill(target)
        context.concatenate(reference.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { throw SearchExtractionError.invalidDocument }
        return image
    }

    private final class Recognition: @unchecked Sendable {
        let request = VNRecognizeTextRequest()
    }

    private static func recognize(_ image: CGImage, textLimit: Int,
                                  deadline: ContinuousClock.Instant) async throws -> (value: String, truncated: Bool) {
        try await withOCRFallback(deadline: deadline) { level in
            try await recognize(image, textLimit: textLimit, deadline: deadline, level: level)
        }
    }

    /// Some virtualized hosts cannot compile Vision's accurate model. The distinct fast
    /// model gets one attempt inside the original budget, never after cancellation.
    static func withOCRFallback<T>(deadline: ContinuousClock.Instant,
                                   recognize: (VNRequestTextRecognitionLevel) async throws -> T) async throws -> T {
        try check(deadline)
        do { return try await recognize(.accurate) }
        catch {
            if error is CancellationError { throw error }
            try check(deadline)
            return try await recognize(.fast)
        }
    }

    static func recognize(_ image: CGImage, textLimit: Int, deadline: ContinuousClock.Instant,
                          level: VNRequestTextRecognitionLevel) async throws -> (value: String, truncated: Bool) {
        try check(deadline)
        guard textLimit > 0 else { return ("", true) }
        let recognition = Recognition()
        recognition.request.recognitionLevel = level
        recognition.request.usesLanguageCorrection = false
        // Automatic script detection may compile additional language models beyond the search
        // deadline. Recognize up to three supported device languages, with English as fallback.
        let supportedLanguages = try recognition.request.supportedRecognitionLanguages()
        var languages = Locale.preferredLanguages.compactMap { preferred in
            supportedLanguages.first { $0.caseInsensitiveCompare(preferred) == .orderedSame }
                ?? supportedLanguages.first { $0.split(separator: "-").first == preferred.split(separator: "-").first }
        }
        if languages.isEmpty, supportedLanguages.contains("en-US") { languages = ["en-US"] }
        var seenLanguages: Set<String> = []
        languages = languages.filter { seenLanguages.insert($0).inserted }
        recognition.request.recognitionLanguages = Array(languages.prefix(3))
        // Prefer supported CPU stages for this bounded, one-image-at-a-time operation.
        // Vision's internal models still require the cancellation and deadline checks below.
        for (stage, devices) in try recognition.request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                recognition.request.setComputeDevice(cpu, for: stage)
            }
        }
        try check(deadline)
        let duration = ContinuousClock.now.duration(to: deadline).components
        let seconds = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        let timeout = DispatchWorkItem { [weak recognition] in recognition?.request.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + min(seconds, 86_400), execute: timeout)
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try check(deadline)
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([recognition.request]) }
            catch { try check(deadline); throw error }
            try check(deadline)
            var text = "", truncated = false
            for observation in recognition.request.results ?? [] {
                try check(deadline)
                guard let candidate = observation.topCandidates(1).first?.string, !candidate.isEmpty else { continue }
                let separator = text.isEmpty ? "" : "\n"
                let clipped = prefix(separator + candidate, byteLimit: textLimit - text.utf8.count)
                text += clipped.value
                if clipped.truncated { truncated = true; break }
            }
            return (text, truncated)
        } onCancel: {
            recognition.request.cancel()
        }
    }

    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw SearchExtractionError.deadlineExceeded }
    }

    private static func prefix(_ text: String, byteLimit: Int) -> (value: String, truncated: Bool) {
        guard text.utf8.count > byteLimit else { return (text, false) }
        // Drop incomplete UTF-8 trailing bytes; never introduce a replacement character.
        var bytes = Array(text.utf8.prefix(max(0, byteLimit)))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return (value, true) }
            bytes.removeLast()
        }
        return ("", true)
    }
}
