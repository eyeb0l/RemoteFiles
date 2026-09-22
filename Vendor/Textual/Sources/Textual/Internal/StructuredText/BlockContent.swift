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
        return AnyView(MathBlock(content))
      case .paragraph:
        return AnyView(Paragraph(content))
      case .header(let level):
        return AnyView(Heading(content, level: level))
      case .orderedList:
        return AnyView(OrderedList(intent: intent, content: content))
      case .unorderedList:
        return AnyView(UnorderedList(intent: intent, content: content))
      case .codeBlock(let languageHint) where languageHint?.lowercased() == "math":
        return AnyView(MathCodeBlock(content))
      case .codeBlock(let languageHint):
        return AnyView(CodeBlock(content, languageHint: languageHint))
      case .blockQuote:
        return AnyView(BlockQuote(intent: intent, content: content))
      case .thematicBreak:
        return AnyView(ThematicBreak(content))
      case .table(let columns):
        return AnyView(Table(intent: intent, content: content, columns: columns))
      default:
        return AnyView(Paragraph(content))
      }
    }
  }
}
