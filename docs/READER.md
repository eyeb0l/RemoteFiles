# Reader and preview behavior

[Documentation](README.md) · [RemoteFiles](../README.md)

Supported formats, navigation, export, and resource limits for the read-only reader.

## Reader scope

Markdown and UTF-8 text/config/code use a 2 MiB receive-time bound and explicit empty/binary/unsupported states. Standalone JPEG, PNG, HEIC/HEIF, GIF, TIFF, WebP and BMP images open with bounded SFTP caching and downsampled display; tap for full-screen zoom and Share. Animated images show their first frame. PDFs open in a native scrolling, zoomable reader. Common video and audio files open with playback and seeking controls after a bounded download. MP4/MOV/M4V/3GP video and MP3/M4A/AAC/WAV/AIFF/CAF/FLAC audio are recognized; codec compatibility depends on the device. Playback stops when leaving the preview or backgrounding. Image/PDF/audio/video transfers are capped at 128 MiB per file. See [audio and video previews](AUDIO_VIDEO.md) for the full format list and lifecycle policy. Markdown images load lazily through SFTP relative to the document directory, with bounded disk/pixel caches, retry, zoom and Share. Web/file/data image URLs never load. See [remote image policy](REMOTE_IMAGES.md). Tapped HTTP/HTTPS links may open externally; relative document links resolve within the canonical connection starting folder, and unsafe schemes remain disabled. Tables/code scroll within the rendered document. Markdown source and plain text remain read only. A failed refresh labels the previous content as previously loaded.

HTML/HTM files open with **Rendered** and **Source** modes. Rendered is a static,
local WebKit preview of document content and inline styles; scripts and linked
resources are not loaded. Script-only app entry pages explain why there is no
static content to display. Source keeps the original highlighted HTML and the
existing copy/export actions. See [HTML previews](HTML_PREVIEWS.md).

Source files and the Markdown **Source** tab have automatic syntax highlighting in light and dark appearances, using the filename to select the bundled grammar (including Swift, JavaScript/TypeScript, Python, JSON, YAML, shell, HTML/CSS and SQL). Plain source appears immediately; tokenization and color preparation happen off the main actor. Selection and **Copy Source** retain the original text. Unknown formats, sources above 256 KiB, and results above 16,000 tokens stay plain to bound rendering work; the existing 2 MiB text-preview limit is unchanged. Rendered Markdown code fences use the same 256 KiB / 16,000-token budget and fall back losslessly to plain code when either limit is reached. The tokenizer runs locally and loads no remote scripts. Its token cache holds at most two documents within an estimated 2 MiB budget and clears on disconnect/background or memory warning. Leaving the source view cancels publication of unfinished highlighting.

## Document navigation and original export

**Document actions → Find in Document** searches visible Markdown or plain text,
highlights the current result, and offers previous/next navigation. Source mode
searches the literal source; HTML/SVG offer **Find in Source**. Searches are local,
case/diacritic insensitive and capped at 1,000 results. **Headings** lists parsed
Markdown headings; same-document and relative-file `#heading` links jump to them.
Repeated headings use suffixes such as `details-1`.

Text readers remember separate Rendered and Source positions across launches.
History stores coordinates and a content fingerprint, never document contents,
for up to 200 connection/path pairs. Changed text starts at the top. Positions
save after scrolling pauses and when leaving the reader or backgrounding; Demo
does not write reading history. Pixel positions are approximate if the screen
size or text settings change.

When the scene becomes inactive or backgrounded, an opaque window-level privacy
cover sits above readers and presented sheets before the system captures an app
switcher snapshot. Returning active removes the cover without changing navigation,
reader position, or presentation state.

Rendered Markdown can open relative Markdown/text/image/PDF/audio/video links within the
connection’s canonical starting folder. Native Back keeps separate Rendered and
Source reading positions. Missing headings and unsupported query links show an actionable explanation.
See [document links](DOCUMENT_LINKS.md).

The reader’s **Save Original to Files** toolbar action streams the original file
(up to 128 MiB), preserving exact bytes and the selected filename/extension. It
works for files without a supported preview. Preparation can be cancelled; the
native Files picker saves a copy. Temporary exports expire after ten minutes
and are removed on dismissal, navigation away, disconnect or backgrounding.
See [original export](ORIGINAL_EXPORT.md).

## Offline copies

**Document actions → Keep Offline** saves an individual original for the library’s
**Offline Files** collection. Copies open without SFTP, show their saved date, and
update only on request. Folder context menus offer the same action. See
[offline files](OFFLINE_FILES.md) for limits, local preview differences and lifecycle.

## JSON and SVG previews

Source lines wrap visually by default; **Document actions → Wrap Lines** turns
wrapping off for horizontal scrolling and remembers your preference. Scroll
indicators flash when opening an unwrapped source view. Very long lines and
large documents always use a width-bounded, read-only TextKit view on iOS to
avoid an oversized layout surface; the actions menu explains this limit.
Selection, Copy Source and original export retain the original characters and
bytes. The 2 MiB text limit still applies, and
malformed JSON remains readable source rather than becoming an empty preview.

SVG files have **Rendered / Source** modes. Rendering supports a static subset
(paths, shapes, groups, gradients, local references and text) up to 512 KiB,
10,000 elements and 64 levels. Unsupported, malformed or overly complex SVGs
show a source-accessible explanation. Scripts, event handlers, animation,
embedded images, HTML and external resources are rejected. Only reserialized,
allowlisted SVG enters a nonpersistent WebKit view with content JavaScript
disabled, a restrictive content security policy, all-resource blocking and
external navigation denied. Source and Save Original do not use that rendering
copy. SVG rendering does not fetch images, stylesheets, fonts or other files.

Synthetic long-line JSON and SVG examples in Explore Demo support regression
checks. Private user attachments and screenshots are not bundled or committed.
