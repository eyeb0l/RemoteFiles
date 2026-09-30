# Textual provenance and local patches

Vendored from https://github.com/gonzalezreal/textual at commit
`01b51875a5406eefc95f52a058cb059e7bc94dc4` (the original preview pin).
The MIT license is retained. The Markdown parser and visual rendering policies are retained.

Local changes:

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
