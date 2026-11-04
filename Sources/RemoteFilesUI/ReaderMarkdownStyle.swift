import SwiftUI
import Textual

/// How rendered Markdown looks in the reader: restrained headings, roomier prose, and quotes and
/// code that sit on the page without boxes around them.
struct ReaderMarkdownStyle: StructuredText.Style {
    let inlineStyle: InlineStyle = .default
    let headingStyle = ReaderHeadingStyle()
    let paragraphStyle = ReaderParagraphStyle()
    let blockQuoteStyle = ReaderBlockQuoteStyle()
    let codeBlockStyle = ReaderCodeBlockStyle()
    let listItemStyle: StructuredText.DefaultListItemStyle = .default
    let unorderedListMarker: StructuredText.SymbolListMarker = .disc
    let orderedListMarker: StructuredText.DecimalListMarker = .decimal
    let tableStyle: StructuredText.DefaultTableStyle = .default
    let tableCellStyle: StructuredText.DefaultTableCellStyle = .default
    let thematicBreakStyle: StructuredText.DividerThematicBreakStyle = .divider
}

extension StructuredText.Style where Self == ReaderMarkdownStyle {
    static var reader: Self { .init() }
}

struct ReaderHeadingStyle: StructuredText.HeadingStyle {
    private static let fontScales: [CGFloat] = [1.65, 1.38, 1.18, 1.06, 1, 0.94]
    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, 6)
        configuration.label
            .textual.fontScale(Self.fontScales[level - 1])
            .textual.lineSpacing(.fontScaled(0.12))
            .textual.blockSpacing(.fontScaled(top: level == 1 ? 1.2 : 1.5, bottom: 0.5))
            .fontWeight(level <= 2 ? .bold : .semibold)
    }
}

struct ReaderParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.3))
            .textual.blockSpacing(.fontScaled(top: 0.8))
    }
}

struct ReaderBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.secondary)
            .textual.lineSpacing(.fontScaled(0.3))
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Capsule().fill(.quaternary).frame(width: 3)
            }
    }
}

struct ReaderCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        Overflow {
            configuration.label
                .textual.lineSpacing(.fontScaled(0.35))
                .textual.fontScale(0.86)
                .fixedSize(horizontal: false, vertical: true)
                .monospaced()
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
        }
        .background(.fill.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .textual.blockSpacing(.fontScaled(top: 0.9, bottom: 0))
    }
}
