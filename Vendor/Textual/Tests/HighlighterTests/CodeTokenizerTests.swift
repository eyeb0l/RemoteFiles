import Foundation
import Testing

@testable import Textual

struct CodeTokenizerTests {
  @Test
  @available(watchOS, unavailable)
  func tokenize() async {
    // given
    let tokenizer = CodeTokenizer()

    // when
    let tokens: [CodeToken] =
      if let tokenizer {
        await tokenizer.tokenize(
          code: "let greeting = \"Hello, world!\"",
          language: "swift"
        )
      } else {
        []
      }

    // then
    #expect(tokenizer != nil)
    #expect(
      tokens == [
        .init(content: "let", type: .keyword),
        .init(content: " greeting ", type: .plain),
        .init(content: "=", type: .operator),
        .init(content: " ", type: .plain),
        .init(content: "\"Hello, world!\"", type: .string),
      ]
    )
  }

  @Test
  @available(watchOS, unavailable)
  func tokenizeUnsupportedLanguage() async {
    // given
    let tokenizer = CodeTokenizer()

    // when
    let tokens: [CodeToken] =
      if let tokenizer {
        await tokenizer.tokenize(
          code: "let greeting = \"Hello, world!\"",
          language: "unsupported"
        )
      } else {
        []
      }

    // then
    #expect(tokenizer != nil)
    #expect(
      tokens == [
        .init(content: "let greeting = \"Hello, world!\"", type: .plain)
      ]
    )
  }
}

extension CodeTokenizerTests {
  @Test @MainActor
  func concurrentFirstUseFromMainActorPreservesCode() async throws {
    let tokenizer = try #require(CodeTokenizer())
    let code = "let city = \"東京\" // café"
    let outputs = await withTaskGroup(of: [CodeToken].self) { group in
      for _ in 0..<8 {
        group.addTask { await tokenizer.tokenize(code: code, language: "swift") }
      }
      var results: [[CodeToken]] = []
      for await tokens in group { results.append(tokens) }
      return results
    }
    #expect(outputs.count == 8)
    for tokens in outputs {
      #expect(tokens.map(\.content).joined() == code)
      #expect(tokens.contains { $0.type == .keyword })
    }
  }
}
