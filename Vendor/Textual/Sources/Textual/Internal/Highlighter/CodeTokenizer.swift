import Foundation
import os

#if canImport(JavaScriptCore)
  import JavaScriptCore
#endif

// MARK: - Overview
//
// CodeTokenizer wraps Prism.js via JavaScriptCore for syntax highlighting. The actor
// ensures thread-safe access to the JavaScript context.
//
// The tokenizer gracefully degrades when JavaScriptCore is unavailable, when the
// Prism bundle is missing, or when tokenization fails. In all cases, it returns
// a single plain token containing the entire code string.

struct CodeToken: Hashable, Sendable {
  let content: String
  let type: StructuredText.HighlighterTheme.TokenType
}

#if canImport(JavaScriptCore)
  actor CodeTokenizer {
    /// Keep rendered Markdown code fences within the same work budget as the
    /// app's standalone source highlighter. The byte check happens before the
    /// string crosses the JavaScriptCore bridge.
    static let maximumCodeBytes = 256 * 1024
    static let maximumTokenCount = 16_000

    // A synchronous actor initializer runs on its caller. Defer the expensive
    // JavaScriptCore/Prism setup until actor-isolated tokenization requests it.
    private lazy var context: JSContext? = makeContext()
    private let logger = Logger(category: .codeTokenizer)

    static let shared = CodeTokenizer()

    init?() {}

    private func makeContext() -> JSContext? {
      guard let context = JSContext() else {
        logger.error("JavascriptCore is not available.")
        return nil
      }

      guard
        let bundleURL = Bundle.textual?.url(
          forResource: "prism-bundle",
          withExtension: "js"
        ),
        let script = try? String(contentsOf: bundleURL, encoding: .utf8)
      else {
        logger.error("Prism JavaScript bundle is missing.")
        return nil
      }

      context.evaluateScript(script)
      return context
    }

    func tokenize(code: String, language: String) -> [CodeToken] {
      guard code.utf8.count <= Self.maximumCodeBytes else {
        return [CodeToken(content: code, type: .plain)]
      }
      guard
        let context,
        let tokenizeCode = context.objectForKeyedSubscript("tokenizeCode"),
        let result = tokenizeCode.call(withArguments: [
          code, language, Self.maximumTokenCount, code.utf16.count,
        ]),
        !result.isNull && !result.isUndefined,
        let array = result.toArray() as? [[String: String]],
        array.count <= Self.maximumTokenCount
      else {
        logger.error("Tokenization failed.")
        return [CodeToken(content: code, type: .plain)]
      }

      var tokens: [CodeToken] = []
      tokens.reserveCapacity(array.count)
      for token in array {
        guard let content = token["content"], let type = token["type"] else {
          return [CodeToken(content: code, type: .plain)]
        }
        tokens.append(CodeToken(content: content, type: .init(rawValue: type)))
      }
      guard tokens.map(\.content).joined() == code else {
        logger.error("Tokenization produced a lossy result.")
        return [CodeToken(content: code, type: .plain)]
      }
      return tokens
    }
  }
#else
  actor CodeTokenizer {
    static let maximumCodeBytes = 256 * 1024
    static let maximumTokenCount = 16_000

    private let logger = Logger(category: .codeTokenizer)

    static let shared = CodeTokenizer()

    init?() {
      logger.error("JavascriptCore is not available in this platform.")
      return nil
    }

    func tokenize(code: String, language: String) -> [CodeToken] {
      [CodeToken(content: code, type: .plain)]
    }
  }
#endif

extension Logger.Textual.Category {
  fileprivate static let codeTokenizer = Self(rawValue: "codeTokenizer")
}
