import Foundation

/// A static SVG subset. Only this reserialized document can enter the image renderer;
/// the original source remains untouched for selection, copying and export.
public enum SVGPreviewPolicy {
    public static let byteLimit = 512 * 1024
    public static let elementLimit = 10_000
    public static let depthLimit = 64

    public enum Failure: Error, LocalizedError {
        case tooLarge, malformed, unsupported
        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "This SVG is too large to render. Use Source or save the original."
            case .malformed: return "This SVG could not be rendered. Use Source to inspect it."
            case .unsupported: return "This SVG uses features that cannot be safely rendered. Use Source to inspect it."
            }
        }
    }

    public static func prepare(_ source: String) throws -> String {
        guard source.utf8.count <= byteLimit else { throw Failure.tooLarge }
        try Task.checkCancellation()
        // Reject declarations before XMLParser can expand internal or external entities.
        let upper = source.uppercased()
        guard !upper.contains("<!DOCTYPE"), !upper.contains("<!ENTITY") else { throw Failure.unsupported }
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        let delegate = StaticSVGParser()
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.depth == 0, delegate.sawRoot else {
            throw delegate.failure ?? Failure.malformed
        }
        try Task.checkCancellation()
        return delegate.output
    }
}

private final class StaticSVGParser: NSObject, XMLParserDelegate {
    private static let elements: Set<String> = [
        "svg", "g", "defs", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "title", "desc", "linearGradient", "radialGradient", "stop", "clipPath", "mask"
    ]
    private static let attributes: Set<String> = [
        "id", "xmlns", "xmlns:xlink", "version", "viewBox", "preserveAspectRatio", "width", "height",
        "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "dx", "dy", "d", "points",
        "transform", "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-opacity",
        "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset",
        "opacity", "color", "clip-path", "clip-rule", "mask", "maskUnits", "maskContentUnits", "clipPathUnits",
        "gradientUnits", "gradientTransform", "spreadMethod", "offset", "stop-color", "stop-opacity",
        "fx", "fy", "fr", "font-family", "font-size", "font-weight", "font-style", "text-anchor",
        "dominant-baseline", "letter-spacing", "word-spacing", "href", "xlink:href", "style"
    ]
    private static let styleProperties: Set<String> = [
        "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap",
        "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "opacity", "color",
        "font-family", "font-size", "font-weight", "font-style", "text-anchor", "dominant-baseline",
        "letter-spacing", "word-spacing", "stop-color", "stop-opacity", "clip-path", "mask"
    ]
    var depth = 0
    var sawRoot = false
    var valid = true
    var failure: SVGPreviewPolicy.Failure?
    var output = ""
    private var count = 0

    private func reject(_ parser: XMLParser, _ reason: SVGPreviewPolicy.Failure = .unsupported) {
        valid = false; failure = reason; parser.abortParsing()
    }
    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private func fragment(_ value: String) -> Bool {
        value.range(of: #"^#[A-Za-z_][A-Za-z0-9_.:-]*$"#, options: .regularExpression) != nil
    }
    private func safeValue(_ value: String) -> Bool {
        // No CSS escapes/comments/functions except an exact local paint/clip reference.
        guard !value.contains("\\"), !value.contains("/*"), !value.contains("<"),
              !value.contains("@"), !value.contains(":"), !value.contains(";"),
              !value.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else { return false }
        if value.contains("(") || value.contains(")") {
            // Geometry transforms, RGB colors and local URL references are static.
            let pattern = #"^(?:(?:matrix|translate|scale|rotate|skewX|skewY|rgb|rgba)\([0-9eE+.,%\s-]+\)\s*)+$"#
            return value.range(of: pattern, options: .regularExpression) != nil ||
                value.range(of: #"^url\(#[A-Za-z_][A-Za-z0-9_.:-]*\)$"#, options: .regularExpression) != nil
        }
        return true
    }
    private func safeStyle(_ style: String) -> Bool {
        for declaration in style.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, Self.styleProperties.contains(pair[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  safeValue(pair[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        }
        return true
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard !Task.isCancelled else { reject(parser); return }
        count += 1; depth += 1
        guard count <= SVGPreviewPolicy.elementLimit, depth <= SVGPreviewPolicy.depthLimit else { reject(parser, .tooLarge); return }
        guard Self.elements.contains(name), (sawRoot || name == "svg"), !(depth == 1 && sawRoot) else { reject(parser); return }
        if depth == 1 { sawRoot = true }
        var clean = attributes
        if depth == 1 {
            guard attributes["xmlns"] == nil || attributes["xmlns"] == "http://www.w3.org/2000/svg" else { reject(parser); return }
            clean["xmlns"] = "http://www.w3.org/2000/svg"
            // Intrinsic pixel dimensions without a viewBox otherwise clip when the
            // bounded image viewport overrides width/height. Only the render copy changes.
            if attributes["viewBox"] == nil {
                func dimension(_ value: String?) -> Double? {
                    guard let value, let number = Double(value.hasSuffix("px") ? String(value.dropLast(2)) : value),
                          number.isFinite, number > 0, number <= 1_000_000 else { return nil }
                    return number
                }
                if let width = dimension(attributes["width"]), let height = dimension(attributes["height"]) {
                    clean["viewBox"] = "0 0 \(width) \(height)"
                }
            }
        }
        for (key, value) in attributes {
            // Inert accessibility/editor metadata does not affect the image.
            if key.hasPrefix("aria-") || key.hasPrefix("data-") || key == "role" { clean.removeValue(forKey: key); continue }
            guard Self.attributes.contains(key) else { reject(parser); return }
            let allowed: Bool
            switch key {
            case "xmlns": allowed = value == "http://www.w3.org/2000/svg"
            case "xmlns:xlink": allowed = value == "http://www.w3.org/1999/xlink"
            case "href", "xlink:href": allowed = fragment(value)
            case "style": allowed = safeStyle(value)
            default: allowed = safeValue(value)
            }
            guard allowed else { reject(parser); return }
        }
        output += "<" + name
        for key in clean.keys.sorted() { output += " " + key + "=\"" + escape(clean[key]!) + "\"" }
        output += ">"
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        output += "</" + name + ">"; depth -= 1
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { output += escape(string) }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { reject(parser, .malformed); return }
        output += escape(text)
    }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser); return nil }
}
