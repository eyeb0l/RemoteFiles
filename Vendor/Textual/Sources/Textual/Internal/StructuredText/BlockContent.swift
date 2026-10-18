import SwiftUI

extension StructuredText {
  struct BlockContent<Content: AttributedStringProtocol>: View {
    private let parent: PresentationIntent.IntentType?
    private let content: Content

    init(parent: PresentationIntent.IntentType? = nil, content: Content) {
      self.parent = parent
      self.content = content
    }

    var body: some View {
      let runs = content.blockRuns(parent: parent)

      BlockVStack {
        ForEach(runs.indices, id: \.self) { index in
          let run = runs[index]
          Block(intent: run.intent, content: content[run.range])
        }
      }
    }
  }
}

extension StructuredText {
  struct Block: View {
    @Environment(\.navigationRevealID) private var navigationRevealID
    private let intent: PresentationIntent.IntentType?
    private let content: AttributedSubstring

    init(intent: PresentationIntent.IntentType?, content: AttributedSubstring) {
      self.intent = intent
      self.content = content
    }

    // Erase at the heterogeneous block boundary to avoid eagerly instantiating
    // nested ConditionalContent metadata for every possible block implementation.
    var body: AnyView {
      switch intent?.kind {
      case .paragraph where content.isMathBlock:
        return AnyView(MathBlock(content).modifier(NavigationBlockReveal(target: navigationTarget, isFinal: true)))
      case .paragraph:
        return AnyView(Paragraph(content))
      case .header(let level):
        return AnyView(Heading(content, level: level))
      case .orderedList:
        return AnyView(OrderedList(intent: intent, content: content))
      case .unorderedList:
        return AnyView(UnorderedList(intent: intent, content: content))
      case .codeBlock(let languageHint) where languageHint?.lowercased() == "math":
        return AnyView(MathCodeBlock(content).modifier(NavigationBlockReveal(target: navigationTarget, isFinal: true)))
      case .codeBlock(let languageHint):
        return AnyView(CodeBlock(content, languageHint: languageHint).modifier(NavigationBlockReveal(target: navigationTarget, isFinal: false)))
      case .blockQuote:
        return AnyView(BlockQuote(intent: intent, content: content))
      case .thematicBreak:
        return AnyView(ThematicBreak(content))
      case .table(let columns):
        return AnyView(Table(intent: intent, content: content, columns: columns).modifier(NavigationBlockReveal(target: navigationTarget, isFinal: false)))
      default:
        return AnyView(Paragraph(content))
      }
    }

    private var navigationTarget: UUID? {
      guard let navigationRevealID else { return nil }
      return content.runs.lazy.compactMap { $0[TextualNavigationTarget.self] }.first { $0 == navigationRevealID }
    }
  }
}
