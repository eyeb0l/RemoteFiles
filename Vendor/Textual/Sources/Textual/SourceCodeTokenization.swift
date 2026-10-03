import Foundation

/// A lossless source token produced by the same bundled Prism grammar as Markdown code blocks.
public struct SourceCodeToken: Hashable, Sendable {
  public let content: String
  public let type: StructuredText.HighlighterTheme.TokenType
}

/// Tokenizes source without interpreting it as Markdown, executing it, or loading resources.
public enum SourceCodeTokenization {
  public static func tokens(for source: String, language: String) async -> [SourceCodeToken] {
    guard let tokenizer = CodeTokenizer.shared else {
      return [SourceCodeToken(content: source, type: .plain)]
    }
    return await tokenizer.tokenize(code: source, language: language).map {
      SourceCodeToken(content: $0.content, type: $0.type)
    }
  }
}
