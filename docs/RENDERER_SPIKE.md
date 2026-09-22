# Renderer spike

Inspected on 22 September 2026. The selected renderer is [Textual](https://github.com/gonzalezreal/textual/tree/01b51875a5406eefc95f52a058cb059e7bc94dc4), pinned to commit `01b51875a5406eefc95f52a058cb059e7bc94dc4`. `DocumentContentView(text:markdown:source:)` is the app's only renderer integration boundary.

## Source findings and choices

- Textual uses Foundation's `AttributedString(markdown:)` parser and native SwiftUI text rendering. Its package requires Swift 6 and supports iOS 18 and later. RemoteFiles retains the requested iOS 27 deployment target.
- Its `StructuredText` parsing entry point runs on the main actor. RemoteFiles prepares the attributed document on a separate actor, then supplies the immutable result through Textual's `MarkupParser` protocol. This adapter does not implement Markdown syntax parsing. View recomputation and switching to Source reuse the prepared result; a changed source triggers preparation. A previous rendering remains visible while the new one is prepared, with an explicit message if preparation fails.
- `StructuredText` has native selection/copy support. The view enables `.textual.textSelection(.enabled)`.
- Textual's default code style uses its `Overflow` container. Tables explicitly use `.textual.tableStyle(.overflow(relativeWidth: 3))`. Its `Overflow` implementation provides a local horizontal scroll/selection region rather than widening the whole document. These are the library's documented selection-aware containers, not ad-hoc nested scroll views.
- Foundation supports headings, emphasis, inline code, code blocks, lists, blockquotes, tables, and thematic breaks. Foundation retains task markers as `[x]`/`[ ]` text. A small attributed-output formatting pass converts a marker at the start of a parsed list item into `☑`/`☐`; these are read-only checklist glyphs, not editing controls. Markers inside inline code stay literal.
- Syntax highlighting is supplied by Textual's bundled Prism implementation. RemoteFiles does not supply or execute document JavaScript. Mermaid, math extensions, and HTML rendering are not enabled.

Relevant upstream implementation: [`MarkupParser.swift`](https://github.com/gonzalezreal/textual/blob/01b51875a5406eefc95f52a058cb059e7bc94dc4/Sources/Textual/MarkupParser.swift), [`AttributedStringMarkdownParser.swift`](https://github.com/gonzalezreal/textual/blob/01b51875a5406eefc95f52a058cb059e7bc94dc4/Sources/Textual/MarkdownParser/AttributedStringMarkdownParser.swift), [`Overflow.swift`](https://github.com/gonzalezreal/textual/blob/01b51875a5406eefc95f52a058cb059e7bc94dc4/Sources/Textual/StructuredText/Style/Overflow.swift), and [`OverflowTableStyle.swift`](https://github.com/gonzalezreal/textual/blob/01b51875a5406eefc95f52a058cb059e7bc94dc4/Sources/Textual/StructuredText/Style/Default/OverflowTableStyle.swift).

## Resource and navigation policy

Textual's default attachment loader fetches URLs, so RemoteFiles does not use that default:

1. `DocumentPolicy.prepareMarkdown` replaces every parsed image run with readable alt text plus “preview unavailable”, removing the image URL and any enclosing link. Empty-alt images receive an explicit placeholder. This applies equally to HTTP, relative, file, and data URLs.
2. Both Textual image and emoji loaders are replaced by a loader which immediately throws and performs no I/O. This is a second boundary if future code ever reintroduces an attachment attribute.
3. Unsafe and relative link attributes are removed during preparation. The reader also overrides `openURL` to admit only absolute HTTP/HTTPS URLs with a nonempty host and no embedded credentials, in response to a link tap.
4. No base URL is supplied. Relative Markdown paths do not resolve to local files or remote SFTP resources. HTML remains inactive attributed text; there is no HTML renderer or document web view.

The plain-text/source branch uses `Text(verbatim:)`, monospaced Dynamic Type, native selection, and two-axis scrolling. It does not interpret code or HTML. UTF-8 validation rejects malformed byte sequences and non-whitespace C0 controls, and handles empty files and UTF-8 BOMs deliberately. Unsupported extensions and oversized input have separate policy results. The transport separately enforces the byte limit while receiving data.

## Fixtures and executed checks

`Fixtures/agent-report.md` includes all required Markdown features, a very wide code line and table, nested lists, Unicode/spaces, remote/relative/data images, allowed and blocked links, raw HTML, and a Mermaid fence. These are synthetic fixtures, never credentials or real server data.

Generate the larger fixture and server edge cases with:

```sh
python3 Fixtures/generate-fixtures.py /private/tmp/remotefiles-fixtures
```

The generator was executed successfully. It produced a **191,002-byte** report, a 1,000-entry directory, an empty folder/file, invalid UTF-8, valid-UTF-8 binary controls, an oversized file, hidden and Unicode names, and a relative symlink.

Seven `DocumentPolicyTests` passed on the host in an isolated Swift package. They cover file kinds, empty/BOM/binary/encoding cases, size boundaries, allowed/blocked URL schemes, parsed-image URL removal, preserved alt text, inactive HTML, required structural intents, and task-marker formatting. The initial test caught Foundation's U+FFFC representation for empty-alt images; that case was fixed and the complete seven-test suite passed again.

The root app's simulator build compiled this reader integration successfully. See `PREVIEW_STATUS.md` for final destination/build evidence and any later full-suite results.

An optimized **macOS command-line** preparation measurement on the 191,002-byte fixture returned 169,484 output characters. Eight runs took **91.55, 58.87, 57.28, 57.60, 59.11, 60.23, 59.17, and 58.91 ms**. This measures Foundation parsing plus the policy/formatting pass, not layout, frame time, network latency, or iPhone performance. The first run was cold within that process; subsequent runs were warm. This does not establish the app's cached-display target.

## Simulator interaction and remaining verification

The final signed simulator app was navigated through a demo project, symlink opening, rendered reading, vertical scrolling, Source, and back to Rendered. The optimized Release app also completed a first opening, back navigation, a warm reopening, and source switching. The [light reader capture](screenshots/reader.jpg) shows headings, prose, quotation styling, and task markers. The final app's [dark/accessibility-large capture](screenshots/reader-dark-large.jpg) was inspected: title and body remain legible in that configuration. These are demo-document results, not full-fixture or physical-device acceptance.

A 45-second Debug browse/read profile recorded a 577.84 ms cold-reader main-thread hang. Sampled stacks implicate SwiftUI type-conformance/view construction, Textual's first JavaScriptCore/Prism initialization, and block layout. Markdown preparation was sampled off the main thread before that interval. Inclusive sample counts overlap and do not allocate the whole wall duration. A later 45-second **Release** journey reproduced a **604.71 ms** cold-reader hang; no additional event above 250 ms appeared during the warm reopen. The cold-renderer performance gate remains **unpassed**, and warm cached display below 200 ms has not been established. See [PREVIEW_STATUS.md](../PREVIEW_STATUS.md) for exact traces, environment, and evidence limits.

Selection handles, clipboard contents after gesture selection or Copy Source, independent table/code panning, full realistic-fixture rendering, VoiceOver order, Reduce Motion, Reduce Transparency, and the full range of accessibility sizes remain to be verified. Physical-device interaction, real-network UI acceptance, and large-report/directory profiling remain distinct outstanding steps; the inspected screenshots do not establish those behaviors.
