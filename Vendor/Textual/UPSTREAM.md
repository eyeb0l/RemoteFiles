# Textual provenance and local patches

Vendored from https://github.com/gonzalezreal/textual at commit
`01b51875a5406eefc95f52a058cb059e7bc94dc4` (the original preview pin).
The MIT license is retained. The Markdown parser and visual rendering policies are retained.

Local changes:

- `StructuredText.swift`: a direct `AttributedString` initializer renders an
  already prepared document without a parsing state transition. Attribute-only
  navigation updates and refreshed text retain the same rendering subtree,
  avoiding an intermediate empty layout that can reset the reader's scroll.

- `NavigationTarget.swift`, `TextBuilder.swift`, `TextFragment.swift` and
  `BlockContent.swift`: a public UUID attribute and one-shot reveal modifier let
  the reader navigate to a selected range using its resolved text geometry.
  A noninteractive iOS bridge reveals the range through nested scroll views;
  offscreen code/table placeholders are staged into view before exact reveal.
  Other platforms retain normal rendering. `HighlightedTextFragment.swift`
  preserves the active target and its contrast colors across lossless code
  tokenization. No link, selection or gesture behavior is replaced.

- `SourceCodeTokenization.swift`: a small public, lossless token API exposes the
  existing actor-isolated Prism tokenizer to the app's source reader. It does not
  add grammars, execute source files, or interpret them as Markdown. The app owns
  filename detection, colors, cancellation, cache limits and plain-text fallback.
- `CodeTokenizer.swift`: constructing the shared actor is cheap; JavaScriptCore
  context creation, bundled Prism loading and evaluation are deferred to a lazy
  actor-isolated property accessed during tokenization. The synchronous actor
  initializer previously ran that work on the main-actor caller. Initialization
  still happens once, actor access stays serialized, and a missing context or
  resource still returns plain tokens.
- `BlockContent.swift`: type erase at the existing heterogeneous block boundary
  with explicit `AnyView` returns. This avoids a nested `ConditionalContent`
  metadata tree spanning all Markdown block implementations on first display;
  the selected view, formatting and block identifiers remain the same.
- Accessibility: headings carry the heading trait; decorative unordered-list
  markers are hidden from assistive technologies. The transparent UIKit text
  selection overlay is hidden from accessibility so VoiceOver reads the underlying
  text and links without a duplicate editable-field hint. Table cells combine
  plain content with column-header and row/column context; linked cells retain
  their child link targets. Header cells carry the heading trait. These changes target the iOS reader; selection gestures remain
  on the existing overlay. Actual iOS VoiceOver regressions use the production
  package through `../../scripts/test-voiceover.sh`.
- Package manifest: omit the snapshot-testing dependency and upstream full test
  target from the app distribution. Retain focused upstream tokenizer tests in
  a dependency-free `HighlighterTests` target.

Before/after evidence and limitations are recorded in
`../../docs/READER_PERFORMANCE.md`. Keep this fork small and return to the pinned
upstream package when an equivalent verified fix is available.
