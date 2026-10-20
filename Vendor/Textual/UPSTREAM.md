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
- `Internal/Helpers/RenderingWarmUp.swift`: a public, nonisolated
  `StructuredText.prepareRendering(shouldContinue:)` lets the app move first-display
  Swift runtime lookups off the main thread. On the caller's thread it resolves the body
  types and `View`/`ViewModifier` conformances of the default block views, styles and
  interaction modifiers, checks stored property types for `DynamicProperty`, converts a
  one-character string through the SwiftUI and Textual attribute scopes, and reflects four
  body fonts into the existing lock-isolated provider cache. It creates no views, evaluates
  no bodies, reads no environment and performs no I/O; repeated calls only hit runtime
  caches. Types missing from its lists are simply resolved on first display as before.
  Focused tests are in `Tests/HighlighterTests/RenderingWarmUpTests.swift`.
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

- `OverflowGeometryCache.swift`: wait for a replacement viewport/selection model
  before starting the bounded five-second reading-anchor correction window.
  Attachment waiting has its own ten-second limit. Previously the correction
  deadline ran while SwiftUI was still mounting large rendered content, so a
  slow Source-to-Rendered transition could discard the logical anchor and retain
  a pixel offset for different block heights. The reader regression includes an
  intentionally delayed attachment and keeps the original prose-character test.
  A resolvable attached anchor starts that correction window even while its
  asynchronous region is unready; it must not first consume the attachment wait
  and then start another correction budget. A controlled attached/unready-region
  regression retains the separate delayed-attachment and prose-character checks.

- `TextSelectionCoordinator.swift`, `TextSelectionModel.swift`: `hasActiveSelection`
  is a stored observable flag instead of a computed scan of the observed model
  list. Models register from UIKit representable updates in the middle of SwiftUI
  updates; observing that list let a registration fire an `Overflow` region's
  one-shot observation mid-update, SwiftUI dropped the invalidation, and the later
  deselection went unobserved, so an offscreen code block stayed mounted
  indefinitely (reproduced 3 in 25 relaunched runs under CPU load, and on CI).
  The list is now `@ObservationIgnored`; the flag changes only when a selection
  starts, ends or its model is released (previously a released selected model kept
  the computed value stale without notifying observers).
  `TextSelectionCoordinatorTests` covers registration, moving and releasing a
  selection without SwiftUI.

Before/after evidence and limitations are recorded in
`../../docs/READER_PERFORMANCE.md`. Keep this fork small and return to the pinned
upstream package when an equivalent verified fix is available.
