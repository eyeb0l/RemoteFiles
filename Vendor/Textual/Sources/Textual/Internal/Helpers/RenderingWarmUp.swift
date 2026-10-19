import SwiftUI

// MARK: - Overview
//
// The first structured-text display makes SwiftUI resolve the body type of each Textual view
// and check its protocol conformances. The Swift runtime caches every result process-wide, but
// a cold lookup scans the conformance records of all loaded images, which SwiftUI otherwise
// does on the main actor during the first layout.
//
// Warm-up performs the same type-level lookups ahead of time on the caller's thread. It never
// creates a view, evaluates a body, reads the environment, or changes rendering. Block views
// are type erased, so they are listed here explicitly; a missing entry only leaves that lookup
// to the first display.

extension StructuredText {
  /// Resolves runtime type metadata and conformances used by the first structured-text display.
  ///
  /// Call from a background task before showing ``StructuredText``. The work is idempotent and
  /// cheap once the runtime caches are populated. `shouldContinue` is checked between types.
  ///
  /// - Returns: The number of view types prepared, stopping early when `shouldContinue`
  ///   returns `false`.
  @discardableResult
  nonisolated public static func prepareRendering(shouldContinue: () -> Bool = { true }) -> Int {
    var prepared = 0
    for type in RenderingWarmUp.viewTypes {
      guard shouldContinue() else { return prepared }
      RenderingWarmUp.prepare(type)
      prepared += 1
    }
    for type in RenderingWarmUp.modifierTypes {
      guard shouldContinue() else { return prepared }
      RenderingWarmUp.prepare(type)
      prepared += 1
    }
    guard shouldContinue() else { return prepared }
    RenderingWarmUp.prepareStoredPropertyTypes(RenderingWarmUp.storedPropertyTypes)
    guard shouldContinue() else { return prepared }
    RenderingWarmUp.prepareAttributeScopes()
    guard shouldContinue() else { return prepared }
    RenderingWarmUp.prepareFontReflection()
    return prepared
  }
}

enum RenderingWarmUp {
  typealias Selection = ModifiedContent<
    ModifiedContent<StructuredText.BlockContent<AttributedString>, TextSelectionInteraction>,
    TextSelectionCoordination
  >

  static var viewTypes: [any View.Type] {
    [
      StructuredText.self,
      WithAttachments<Selection>.self,
      StructuredText.BlockContent<AttributedString>.self,
      StructuredText.BlockContent<AttributedSubstring>.self,
      StructuredText.BlockVStack<ForEach<Range<Int>, Int, StructuredText.Block>>.self,
      StructuredText.Block.self,
      StructuredText.Paragraph.self,
      StructuredText.Heading.self,
      StructuredText.OrderedList.self,
      StructuredText.UnorderedList.self,
      StructuredText.CodeBlock.self,
      StructuredText.BlockQuote.self,
      StructuredText.ThematicBreak.self,
      StructuredText.Table.self,
      StructuredText.TableCell.self,
      TextFragment<AttributedString>.self,
      WithInlineStyle<TextFragment<AttributedString>>.self,
      HighlightedTextFragment.self,
      AttachmentView.self,
      StructuredText.ResolvedParagraphStyle<StructuredText.DefaultParagraphStyle>.self,
      StructuredText.ResolvedHeadingStyle<StructuredText.DefaultHeadingStyle>.self,
      StructuredText.ResolvedBlockQuoteStyle<StructuredText.DefaultBlockQuoteStyle>.self,
      StructuredText.ResolvedCodeBlockStyle<StructuredText.DefaultCodeBlockStyle>.self,
      StructuredText.ResolvedListItemStyle<StructuredText.DefaultListItemStyle>.self,
      StructuredText.ResolvedUnorderedListMarker<StructuredText.SymbolListMarker>.self,
      StructuredText.ResolvedOrderedListMarker<StructuredText.DecimalListMarker>.self,
      StructuredText.ResolvedTableStyle<StructuredText.DefaultTableStyle>.self,
      StructuredText.ResolvedTableStyle<StructuredText.OverflowTableStyle>.self,
      StructuredText.ResolvedTableCellStyle<StructuredText.DefaultTableCellStyle>.self,
      StructuredText.ResolvedThematicBreakStyle<StructuredText.DividerThematicBreakStyle>.self,
    ]
  }

  static var modifierTypes: [any ViewModifier.Type] {
    var types: [any ViewModifier.Type] = [
      TextSelectionInteraction.self,
      TextSelectionCoordination.self,
      TextSelectionBackground.self,
      AttachmentOverlay.self,
      FontScaleModifier.self,
    ]
    #if TEXTUAL_ENABLE_LINKS
      types.append(TextLinkInteraction.self)
    #endif
    #if os(iOS)
      types.append(NavigationBlockReveal.self)
    #endif
    return types
  }

  /// Types stored by Textual views and styles. SwiftUI checks each stored property type of a
  /// view for `DynamicProperty` before its first update.
  static var storedPropertyTypes: [Any.Type] {
    var types: [Any.Type] = [
      AttributedString.self, AttributedSubstring.self, AttributedString?.self,
      PresentationIntent.IntentType?.self, [PresentationIntent.TableColumn].self,
      Int.self, CGFloat?.self, CGPoint.self, [CGRect].self, AnyView.self, UUID?.self,
      Set<AnyAttachment>.self, (any MarkupParser)?.self, (any TextLayoutCollection).self,
      OverflowGeometryCache.self, OverflowGeometryCache?.self, DynamicColor.self,
      StructuredText.HighlighterTheme.self, StructuredText.TableCell.Identifier.self,
      FontScaled<CGFloat>.self, FontScaled<StructuredText.BlockSpacing>.self,
      StructuredText.HeadingStyleConfiguration.self, StructuredText.BlockStyleConfiguration.self,
      StructuredText.ListItemStyleConfiguration.self, StructuredText.TableStyleConfiguration.self,
      StructuredText.TableCellStyleConfiguration.self, StructuredText.CodeBlockStyleConfiguration.self,
      StructuredText.UnorderedListMarkerConfiguration.self,
      StructuredText.OrderedListMarkerConfiguration.self,
      StructuredText.DefaultHeadingStyle.self, StructuredText.DefaultParagraphStyle.self,
      StructuredText.DefaultBlockQuoteStyle.self, StructuredText.DefaultCodeBlockStyle.self,
      StructuredText.DefaultListItemStyle.self, StructuredText.SymbolListMarker.self,
      StructuredText.DecimalListMarker.self, StructuredText.DefaultTableStyle.self,
      StructuredText.OverflowTableStyle.self, StructuredText.DefaultTableCellStyle.self,
      StructuredText.DividerThematicBreakStyle.self,
    ]
    #if TEXTUAL_ENABLE_TEXT_SELECTION
      types += [TextSelectionModel.self, TextSelectionCoordinator?.self]
    #endif
    return types
  }

  static func prepareStoredPropertyTypes(_ types: [Any.Type]) {
    for type in types { _ = isDynamicProperty(type) }
  }

  /// Checks the type's own conformance, then its body type. Conditional conformances of the
  /// body's generic wrappers recursively check each nested view and modifier type.
  @inline(never)
  static func prepare(_ type: any View.Type) {
    _ = isView(type)
    _ = isView(bodyType(type))
  }

  @inline(never)
  static func prepare(_ type: any ViewModifier.Type) {
    _ = isViewModifier(type)
    _ = isView(bodyType(type))
  }

  /// Text resolution converts attributed runs through these scopes on first display.
  static func prepareAttributeScopes() {
    var sample = AttributedString("A")
    sample.inlinePresentationIntent = .stronglyEmphasized
    _ = try? NSAttributedString(sample, including: \.swiftUI)
    _ = try? NSAttributedString(sample, including: \.textual)
  }

  /// Font scaling reflects SwiftUI's font providers; the lock-isolated provider cache stores
  /// the same values the first display would compute.
  static func prepareFontReflection() {
    for font in [Font.body, .body.monospaced(), .body.bold(), .body.italic()] {
      _ = font.provider()
    }
  }

  // Opened through existentials so lookups use the runtime, not specialized static metadata.
  @inline(never)
  private static func bodyType<V: View>(_: V.Type) -> Any.Type { V.Body.self }

  @inline(never)
  private static func bodyType<M: ViewModifier>(_: M.Type) -> Any.Type { M.Body.self }

  @inline(never)
  private static func isView(_ type: Any.Type) -> Bool { type is any View.Type }

  @inline(never)
  private static func isDynamicProperty(_ type: Any.Type) -> Bool {
    type is any DynamicProperty.Type
  }

  @inline(never)
  private static func isViewModifier(_ type: Any.Type) -> Bool { type is any ViewModifier.Type }
}
