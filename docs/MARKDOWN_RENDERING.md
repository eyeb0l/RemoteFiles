# Rich Markdown

Markdown containing Mermaid code fences, mathematical notation or raw HTML uses
an offline WebKit renderer. Ordinary Markdown keeps the native reader. Both routes
preserve the original source for Source, Copy Source and Save Original to Files.
Renderer selection uses the native CommonMark parser: examples inside inline,
indented and fenced code stay native, and type names such as `Array<String>` are
not treated as HTML. A real `mermaid` fence still selects diagram rendering.
Explore Demo → Rich Markdown.md contains examples.

- **Diagrams:** fenced `mermaid` blocks render with bundled Mermaid. Flowcharts,
  sequence diagrams and the other diagram types included in Mermaid are available.
- **Mathematics:** `$…$` and `\(…\)` render inline; `$$…$$` and `\[…\]` render display
  equations. KaTeX converts notation to native MathML. Code spans (including
  multiline spans) and ordinary code fences stay literal. Double-dollar expressions can also share a paragraph with
  surrounding prose. Invalid or unsupported notation displays its original text
  with a preview-unavailable explanation.
- **Embedded HTML:** semantic HTML such as headings, tables, lists, emphasis,
  details/summary, superscripts and subscripts renders within the document.
  Document styles, forms, frames, scripts and event handlers are removed. The app's
  typography controls presentation; this is not a website runtime.
- **Task lists:** completed and pending tasks retain read-only `☑` and `☐` markers;
  interactive HTML form controls remain blocked.

Rendered scroll position survives Source/Rendered switches. Rich text follows
the system Dynamic Type body size, including accessibility sizes. Changes update
the existing preview immediately without reloading the document or its images. Headings and Find
can reveal ordinary rendered text. Find still uses the native Markdown text index:
formula source, diagram labels and text introduced only by HTML may not have a
matching rendered selection. Source remains available for exact notation search.

Relative links use the same document navigation policy as ordinary Markdown.
Images load lazily through the existing authenticated SFTP/offline resolver,
which confines resources to the document folder and checks canonical paths.
Tapping an image opens the native image viewer and its Share action. Images with
web/data/file URL sources are not fetched. At most 128 images are considered in
one rich document.

## Structure limits

A Markdown file within the 2 MiB preview cap can still cost far more than its size
suggests, so a document past any of these limits is not rendered, natively or richly.
The reader shows **Rendered Preview Unavailable**, and **Source** shows the text as usual,
with **Find** working there. Such a document has no headings list:

- **Nesting:** more than 32 block levels around any text, such as a quote inside a quote
  32 times. The renderer builds a view inside a view for each level, and a few hundred
  overflow its stack. Ten nested lists use about twenty levels.
- **Table width:** more than 256 vertical bars on one line. Parsing a table row costs the
  square of its columns: 20,000 columns in 120 KB took 16 seconds on a Mac mini.
- **Formatting density:** more than 250,000 line breaks and formatting characters
  (`*`, `_`, `` ` ``, `[`, `|`, `~`, `<`), counted before parsing, or more than 200,000
  differently formatted stretches of text after it. A megabyte and a half of ordinary
  formatted prose has about 100,000; 2 MiB of `*a* ` has a million, which took 11 seconds
  and 750 MiB to parse.

The table width and the character count are checked before the parser runs, because a parse cannot
be interrupted once started. Images after the first 128 in a document become their
alternative text, in both renderers.

The reader parses a document once. The rendered parts, the headings list, the text Find searches,
the links it confirms before opening and the choice between the native and rich renderers all come
from that parse, and a document refused after parsing is not parsed again to show why. Leaving the
reader stops preparation between its steps; the parse itself runs to its end. Within the limits the
costliest documents take about 3 to 4 seconds and up to 300 MiB to prepare on a Mac, and one refused
only after parsing up to about 5 seconds and 460 MiB; ordinary documents take a fraction of that.
See [Markdown preparation](READER_PERFORMANCE.md#markdown-preparation-one-parse-14-november-2026).

## Offline rendering and limits

The app bundles Marked, DOMPurify, KaTeX and Mermaid, with versions, hashes and
licenses under [MarkdownRenderer](../Sources/RemoteFilesCore/Resources/MarkdownRenderer/UPSTREAM.md).
No CDN, font download, browser account, or running web server is involved.
Libraries execute in an app-owned isolated WebKit world; document JavaScript is
disabled. DOMPurify applies a semantic allowlist before HTML reaches the live DOM.
Content Security Policy, an all-resource content blocker, denied navigation and a
nonpersistent data store provide independent boundaries. Only explicit HTTP/HTTPS
link taps open the system browser. Generated SVG is sanitized again before display.

Mermaid is 5.5 MB of script, so it's injected only when the document's text contains the word `mermaid`.

The existing 2 MiB preview cap applies. Each document renders at most 32 Mermaid
diagrams of at most 32 KiB each, with 250 edges per diagram. Mermaid initialization
and frontmatter directives are rejected so a document cannot override renderer
security or inject a theme. At most 128 mathematical expressions of 16 KiB each
render; macro expansion is capped at 500 and user dimensions at 20 em. KaTeX trust
is disabled, including external image/HTML commands. A document that exceeds the
rendering deadline shows a Source fallback. These bounds protect the reader; they
do not promise rendering every diagram accepted by an unrestricted desktop Mermaid
installation.

Standalone HTML retains its separate [static preview](HTML_PREVIEWS.md).

## Verification

`EnhancedMarkdownPolicyTests` checks semantic renderer selection, literal code
examples, the quick pre-check against the search it guards, and bundled resources.
`DocumentTextIndexTests` checks that the single parse gives the parts, headings, Find
results, links to confirm and renderer choice that separate parses gave, on this
repository's documentation, the demo documents and cases for each preparation rule.
Hosted `EnhancedMarkdownDisplayTests` checks Mermaid SVG geometry, MathML, block
and inline HTML, literal multiline code, read-only task states, heading reveal, malicious scripts/resources,
readable invalid notation, size/expression budgets and live Dynamic Type layout. Simulator results do not
establish physical-device acceptance.
