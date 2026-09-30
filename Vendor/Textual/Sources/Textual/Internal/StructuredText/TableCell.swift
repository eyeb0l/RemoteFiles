import SwiftUI

extension StructuredText {
  struct TableCell: View {
    @Environment(\.tableCellStyle) private var tableCellStyle

    private let content: AttributedSubstring
    private let identifier: TableCell.Identifier
    private let header: String

    init(_ content: AttributedSubstring, row: Int, column: Int, header: String) {
      self.content = content
      self.identifier = .init(row: row, column: column)
      self.header = header
    }

    var body: some View {
      let configuration = TableCellStyleConfiguration(
        label: .init(label),
        indentationLevel: indentationLevel,
        row: identifier.row,
        column: identifier.column
      )
      let resolvedStyle =
        tableCellStyle
        .resolve(configuration: configuration)
        .anchorPreference(key: BoundsKey.self, value: .bounds) { anchor in
          [identifier: anchor]
        }

      AnyView(resolvedStyle)
        // Linked text must retain its own accessible link targets.
        .accessibilityElement(children: content.runs.contains { $0.link != nil } ? .contain : .combine)
        .accessibilityLabel(identifier.row == 0 || header.isEmpty
          ? String(content.characters) : "\(header): \(String(content.characters))")
        .accessibilityValue("Row \(identifier.row + 1), column \(identifier.column + 1)")
        .accessibilityAddTraits(identifier.row == 0 ? .isHeader : [])
    }

    private var label: some View {
      WithInlineStyle(AttributedString(content)) {
        TextFragment($0)
      }
    }

    private var indentationLevel: Int {
      content.presentationIntent?.indentationLevel ?? 0
    }
  }
}

extension StructuredText.TableCell {
  struct Identifier: Hashable {
    let row: Int
    let column: Int
  }

  struct BoundsKey: PreferenceKey {
    static let defaultValue: [Identifier: Anchor<CGRect>] = [:]

    static func reduce(
      value: inout [Identifier: Anchor<CGRect>],
      nextValue: () -> [Identifier: Anchor<CGRect>]
    ) {
      value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
  }
}

extension StructuredText.TableCell {
  struct Spacing: Sendable, Hashable {
    let horizontal: CGFloat?
    let vertical: CGFloat?

    init(horizontal: CGFloat? = nil, vertical: CGFloat? = nil) {
      self.horizontal = horizontal
      self.vertical = vertical
    }
  }

  struct SpacingKey: PreferenceKey {
    static let defaultValue = Spacing()

    static func reduce(value: inout Spacing, nextValue: () -> Spacing) {
      value = nextValue()
    }
  }
}
