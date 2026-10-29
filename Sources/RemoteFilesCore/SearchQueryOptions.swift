import Foundation

/// Literal search controls shared by live searches and saved indexes. No regular expressions
/// or shell syntax are interpreted.
public struct SearchQueryOptions: Sendable, Equatable {
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var fileExtension: String

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, fileExtension: String = "") {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.fileExtension = fileExtension
    }

    public func accepts(_ entry: RemoteEntry) -> Bool {
        let suffix = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !suffix.isEmpty else { return true }
        guard entry.kind == .file else { return false }
        return (entry.name as NSString).pathExtension.lowercased() == suffix
    }

    public func range(in text: String, query: String) -> Range<String.Index>? {
        guard !query.isEmpty else { return nil }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var start = text.startIndex
        while start < text.endIndex, let found = text.range(of: query, options: options, range: start..<text.endIndex) {
            if !wholeWord || (Self.boundary(before: found.lowerBound, in: text) && Self.boundary(after: found.upperBound, in: text)) {
                return found
            }
            start = text.index(after: found.lowerBound)
        }
        return nil
    }

    private static func word(_ value: Character) -> Bool {
        value == "_" || value.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        }
    }
    private static func boundary(before index: String.Index, in text: String) -> Bool {
        index == text.startIndex || !word(text[text.index(before: index)])
    }
    private static func boundary(after index: String.Index, in text: String) -> Bool {
        index == text.endIndex || !word(text[index])
    }
}
