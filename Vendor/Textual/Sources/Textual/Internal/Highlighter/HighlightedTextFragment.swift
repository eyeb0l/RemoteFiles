import SwiftUI

// MARK: - Overview
//
// HighlightedTextFragment displays syntax-highlighted code using a two-phase approach.
// Tokenization runs asynchronously and is keyed by content, while highlighting runs
// synchronously on token or environment changes (theme, color scheme, dynamic type).
//
// The presentationIntent is preserved after highlighting so pasteboard formatters can
// reconstruct the block structure when copying code.

struct HighlightedTextFragment: View {
  @Environment(\.overflowReadinessTracking) private var overflowReadinessTracking
  @Environment(\.textEnvironment) private var textEnvironment

  @State private var model = Model()

  private let content: AttributedSubstring
  private let languageHint: String?
  private let theme: StructuredText.HighlighterTheme

  init(
    _ content: AttributedSubstring,
    languageHint: String?,
    theme: StructuredText.HighlighterTheme
  ) {
    self.content = content
    self.languageHint = languageHint
    self.theme = theme
  }

  var body: some View {
    let readiness = overflowReadinessTracking
      ? OverflowContentReadiness(ready: model.tokenizationComplete && model.highlightedCode != nil)
      : OverflowContentReadiness()
    TextFragment(navigationMarked(model.highlightedCode ?? AttributedString(content)))
      .foregroundStyle(theme.foregroundColor)
      .environment(\.navigationRevealGeometryReady, model.tokenizationComplete && model.highlightedCode != nil)
      .transformPreference(OverflowContentReadyKey.self) { $0.merge(readiness) }
      .task(id: content) {
        await model.tokenize(
          content: content,
          languageHint: languageHint
        )
      }
      .onChange(of: Tuple(model.tokens, textEnvironment)) { _, newValue in
        model.highlight(
          tokens: newValue.values.0,
          presentationIntent: content.presentationIntent,
          using: theme,
          environment: newValue.values.1
        )
      }
  }

  // Highlighting rebuilds the attributed string from lossless tokens. Preserve
  // only the caller's active navigation range and its contrast colors, leaving
  // the syntax theme and pasteboard presentation intent intact elsewhere.
  private func navigationMarked(_ highlighted: AttributedString) -> AttributedString {
    let marked = content.runs.filter { $0[TextualNavigationTarget.self] != nil }
    guard !marked.isEmpty, highlighted.characters.elementsEqual(content.characters) else { return highlighted }
    var result = highlighted
    for run in marked {
      let start = content.characters.distance(from: content.startIndex, to: run.range.lowerBound)
      let length = content.characters.distance(from: run.range.lowerBound, to: run.range.upperBound)
      let lower = result.characters.index(result.startIndex, offsetBy: start)
      let upper = result.characters.index(lower, offsetBy: length)
      result[lower..<upper][TextualNavigationTarget.self] = run[TextualNavigationTarget.self]
      result[lower..<upper].backgroundColor = run.backgroundColor
      result[lower..<upper].foregroundColor = run.foregroundColor
    }
    return result
  }
}

extension HighlightedTextFragment {
  @MainActor @Observable final class Model {
    var tokenizationComplete = false
    var tokens: [CodeToken] = []
    var highlightedCode: AttributedString?

    func tokenize(content: AttributedSubstring, languageHint: String?) async {
      tokenizationComplete = false
      defer { tokenizationComplete = true }
      let code = String(content.characters[...])
      tokens = [CodeToken(content: code, type: .plain)]

      if let tokenizer = CodeTokenizer.shared, let languageHint {
        tokens = await tokenizer.tokenize(code: code, language: languageHint)
      }
    }

    func highlight(
      tokens: [CodeToken],
      presentationIntent: PresentationIntent?,
      using theme: StructuredText.HighlighterTheme,
      environment: TextEnvironmentValues
    ) {
      var attributes = AttributeContainer()
      // Re-apply the presentation intent for pasteboard formatters
      attributes.presentationIntent = presentationIntent
      ForegroundColorProperty(theme.foregroundColor)
        .apply(in: &attributes, environment: environment)
      var highlightedCode = AttributedString()

      for token in tokens {
        var content = AttributedString(token.content)
        var tokenAttributes = attributes

        if let tokenProperties = theme.tokenProperties[token.type] {
          tokenProperties.apply(in: &tokenAttributes, environment: environment)
        }

        content.mergeAttributes(tokenAttributes)
        highlightedCode.append(content)
      }

      self.highlightedCode = highlightedCode
    }
  }
}
