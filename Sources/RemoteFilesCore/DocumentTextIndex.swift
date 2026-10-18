import Foundation

/// Ranges use UTF-16, matching Foundation search and native text selection.
public struct DocumentTextTarget: Equatable, Sendable {
    public let partID: Int?
    public let range: NSRange
    public init(partID: Int?, range: NSRange) { self.partID = partID; self.range = range }
}

public struct DocumentHeading: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let level: Int
    public let target: DocumentTextTarget
}

public struct DocumentTextMatches: Sendable {
    public let targets: [DocumentTextTarget]
    public let truncated: Bool
}

/// Prepared once per text revision, away from the UI actor. Rendered searches use
/// visible Markdown characters rather than link destinations or formatting syntax.
public struct DocumentTextIndex: Sendable {
    public let source: String
    public let parts: [MarkdownPart]
    public let headings: [DocumentHeading]
    private let rendered: [(Int, String)]

    public init(text: String, markdown: Bool) throws {
        source = text
        guard markdown else { self.parts = []; self.headings = []; self.rendered = []; return }
        // Index the original structure before splitting images into their own views.
        // An inline image can divide one heading across several rendering parts.
        let document = try DocumentPolicy.prepareMarkdown(text, preserveImages: true, preserveDocumentLinks: true)
        var preparedParts: [MarkdownPart] = []
        var textSlices: [(id: Int, range: Range<AttributedString.Index>)] = []
        var rendered: [(Int, String)] = []
        func appendText(_ range: Range<AttributedString.Index>) {
            guard !range.isEmpty else { return }
            let value = AttributedString(document[range]), id = preparedParts.count
            preparedParts.append(.init(id: id, content: .text(value)))
            textSlices.append((id, range))
            rendered.append((id, String(value.characters)))
        }
        var start = document.startIndex
        for run in document.runs where run.imageURL != nil {
            try Task.checkCancellation()
            appendText(start..<run.range.lowerBound)
            preparedParts.append(.init(id: preparedParts.count, content: .image(reference: run.imageURL!.absoluteString,
                alt: String(document[run.range].characters).replacingOccurrences(of: "\u{FFFC}", with: ""))))
            start = run.range.upperBound
        }
        appendText(start..<document.endIndex)

        var headings: [DocumentHeading] = []
        var usedIDs: Set<String> = []
        var nextSuffix: [String: Int] = [:]
        var currentID: Int?
        var currentLevel = 0
        var currentTitle = ""
        var currentTarget: DocumentTextTarget?
        func finishHeading() {
            let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            // An image-only heading has no selectable text geometry to reveal.
            guard !title.isEmpty, let target = currentTarget else { return }
            let base = Self.slug(title)
            var suffix = nextSuffix[base, default: 0]
            var id = suffix == 0 ? base : "\(base)-\(suffix)"
            while usedIDs.contains(id) { suffix += 1; id = "\(base)-\(suffix)" }
            nextSuffix[base] = suffix + 1
            usedIDs.insert(id)
            headings.append(.init(id: id, title: title, level: currentLevel, target: target))
        }
        var sliceIndex = 0, sliceOffset = 0
        for run in document.runs {
            try Task.checkCancellation()
            let value = String(document[run.range].characters)
            let heading = run.presentationIntent?.components.first(where: {
                if case .header = $0.kind { return true }; return false
            })
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
                    runTarget = .init(partID: textSlices[sliceIndex].id,
                        range: NSRange(location: sliceOffset, length: value.utf16.count))
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
        parts = preparedParts; self.rendered = rendered; self.headings = headings
    }

    public func matches(_ query: String, inSource: Bool, limit: Int = 1_000) throws -> DocumentTextMatches {
        guard !query.isEmpty, limit > 0 else { return .init(targets: [], truncated: false) }
        var targets: [DocumentTextTarget] = []
        let texts: [(Int?, String)] = inSource ? [(nil, source)] : rendered.map { ($0.0, $0.1) }
        for (part, text) in texts {
            let string = text as NSString
            var start = 0
            while start < string.length {
                try Task.checkCancellation()
                let range = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: start, length: string.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                if targets.count == limit { return .init(targets: targets, truncated: true) }
                targets.append(.init(partID: part, range: range))
                start = NSMaxRange(range)
            }
        }
        return .init(targets: targets, truncated: false)
    }

    public func heading(fragment: String) -> DocumentHeading? {
        // URLComponents.fragment is already percent-decoded. Do not decode a second time.
        if fragment.isEmpty, let first = rendered.first, let character = first.1.first {
            return .init(id: "", title: "Top", level: 1,
                         target: .init(partID: first.0, range: NSRange(location: 0, length: String(character).utf16.count)))
        }
        return headings.first { $0.id == fragment }
    }

    public static func slug(_ title: String) -> String {
        String(title.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-" || $0 == "_" }
            .map { $0.isWhitespace ? "-" : $0 })
    }
}
