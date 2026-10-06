# HTML previews

HTML and HTM files default to Rendered and have a Source switch, matching the
Markdown/SVG reader. Rendered displays static document structure, inline CSS,
headings, lists and tables using a nonpersistent WebKit view. Its default styling
adapts to the device appearance and gives documents a mobile viewport. Authored
inline styles are retained. Rendered scroll position is retained when switching
modes. Source remains the original UTF-8 text with the existing HTML grammar,
selection, Copy Source and Save Original to Files actions.

The text transport still enforces the 2 MiB preview cap and UTF-8/control-byte
validation. HTML embedded inside Markdown remains inert text; only standalone
HTML files enter this renderer.

This is the user-selected static document preview. Document JavaScript is
disabled, a leading Content Security Policy disables executable/embedded content,
all automatic resource requests are blocked, and the data store is ephemeral.
Linked CSS, images, fonts and scripts are not fetched over SFTP or the web.
Only explicit taps on allowed absolute HTTP/HTTPS links open externally; other
navigation and form submission remain inactive. Internal fragment links can
scroll within the current preview. The original HTML is never rewritten for
copying or export; renderer-only metadata/styles wrap the displayed copy.

An entry file containing an empty root element and a module script, such as the
React entry in the supplied screenshot, has no static page to display. The view
explains that it needs JavaScript and a running website rather than presenting a
blank preview as success. No development server is started or guessed.

Explore Demo contains Preview.html with synthetic styled text, Unicode, lists
and a table. Hosted WebKit tests check actual DOM/styles and visible pixels,
blocked document scripts/resources, and script-only entries. The UI journey
checks Rendered → Source → Copy Source → Rendered → Refresh.

## Verification, 6 October 2026

The final code passed 17 unique focused Simulator checks on iPhone 18 Pro /
iOS 27.0: ten document-policy checks, three HTML WebKit checks, three existing
bounded-source/SVG checks and the new HTML UI journey. The combined run passed
15; two hosted checks were interrupted by the Simulator shutting down and passed
when rerun after booting it again. The final UI screenshots were inspected for
styled content and the original highlighted source.

The loading checks caught and corrected a hidden-WebKit loading delay. The
renderer remains visible beneath its loading indicator. It also tracks the
requested WKNavigation and performs app-owned DOM inspection in an isolated
content world. WebKit removes document script elements in static mode, so the
empty-page explanation uses the original source to detect script-dependent pages.

Evidence in the XcodeBuildMCP RemoteFiles-4cb9c1492648 result-bundles workspace:
`test_sim_2026-10-06T21-06-34-040Z_pid8837_ea92f1b7.xcresult` and
`test_sim_2026-10-06T21-10-28-626Z_pid8837_1a487b37.xcresult` (two clean reruns).
The signed physical-device Debug build passed signature verification. Build log:
`/private/tmp/RemoteFiles-html-device-build.log`. HTML interaction was checked in
Simulator; no physical-device HTML interaction is claimed by these tests.

The update was installed on the paired iPhone 17 Pro and launched normally.
A separate process check confirmed PID 64188 running from the new installed
app bundle. Installation/launch are verified separately from Simulator HTML
interaction.
