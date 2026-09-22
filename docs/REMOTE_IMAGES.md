# Remote Markdown images

Markdown image resources now use the document's existing authenticated SSH transport.
The renderer requests a resource through `RemoteResourceResolving`; it never opens
image URLs through URLSession, a web view, or Textual's default attachment loaders.

`RemoteDocumentLocation` includes the complete connection profile and remote document
path. For `/Users/iris/wardrobe/data/ui-audit-2026-09-21/audit.md`, all of these resolve
to the same resource:

- `01-wardrobe-before.png`
- `./01-wardrobe-before.png`
- `images/../01-wardrobe-before.png`
- `/Users/iris/wardrobe/data/ui-audit-2026-09-21/01-wardrobe-before.png`

Nested paths such as `images/foo.png` and percent-encoded Unicode/spaces work.
Absolute **remote** paths are supported inside the same directory tree because the
existing audit uses them. They never mean files on the phone.

## Resource boundary

Automatic image access is deliberately narrower than manually browsing the account:
the document's directory and its descendants. Parent traversal out of that tree,
network-path URLs, URL schemes (including HTTP, file and data), query/fragment
references, control characters and backslashes are rejected before transport.
Percent escapes are decoded exactly once. SFTP REALPATH canonicalizes both the root
and target; symlinks escaping the canonical root are rejected before opening bytes.

This is a client resource policy on a trusted SSH server, not a server-side filesystem
jail or protection against a malicious server changing paths during an operation.
Manually browsing other account-readable folders remains allowed. Linked local
Markdown documents are not implemented yet; they can use this same resolver/address
model in a later navigation change.

## Loading and cache policy

- Foundation parses Markdown; its attributed image runs become image blocks interleaved
  with native Textual text segments. No regex Markdown parser. Images occupy their own
  row, including images embedded in prose; selection is per text segment.
- Text rows mount eagerly so Textual can populate its initially empty layout. Image
  geometry requests bytes only within 300 points of the viewport. Leaving that region releases the row's decoded image; its measured
  height is retained to avoid collapsing content above the reader.
- Equal normalized references within a connection/document root share one in-flight
  transfer. Each consumer has independent cancellation; the final cancellation retires
  the flight. Leaving the document cancels its view-owned tasks. Two transfers run at
  most; remaining visible requests wait cancellably.
- Transfers reuse `SFTPRemoteFileService`'s authenticated session and own SFTP child
  channels. Only the referenced file is opened: no sibling enumeration/prefetch.
- Source bytes stream to disk in at most 256 KiB chunks, with a **128 MiB** per-file
  receive-time limit (also checked against FSTAT). A resource operation allows up to
  180 seconds; existing text operation deadlines are unchanged.
- Disk cache: **256 MiB** completed-file LRU, **5-minute** freshness, **24-hour** retention
  cleanup on insertion. At most two bounded partial transfers add up to 256 MiB transient
  disk usage. Failed/cancelled partials are removed; old orphan files expire during cleanup.
  Cache filenames hash the entire profile, canonicalized lexical path and document root;
  different accounts/identities/endpoints do not share entries. This is `Library/Caches`,
  excluded from backup, with complete iOS file protection.
- Decoded image cache: **32 MiB** explicit LRU. Rows/viewer also retain their currently
  displayed thumbnail. Background/disconnect clears decoded caches and cancels flights.
- ImageIO downsamples from the disk URL, disables full-source caching, and decodes away
  from MainActor. Inline thumbnails have a **1600-pixel** longest edge; full-screen uses
  **3072 pixels**. Sources over 400 million pixels are rejected to limit decoder exposure.
  Animated formats display their first frame. SVG/PDF are not image previews.
- Retry invalidates the cached resource before re-fetching. Document Refresh clears image
  caches and rebuilds image rows after the document reload, even if Markdown is unchanged.

The downsampling follows Apple's [Image and Graphics Best Practices](https://devstreaming-cdn.apple.com/videos/wwdc/2018/219mybpx95zm9x/219/219_image_and_graphics_best_practices.pdf):
create a non-caching source, then `CGImageSourceCreateThumbnailAtIndex` with a bounded
pixel size, orientation transform and immediate thumbnail decode.

## Interaction

Failure is local to the image: filename, reason, **Tap to retry**, and **Open file**.
Open file presents the focused image viewer and retries the same safely resolved
resource; it cannot bypass path restrictions. Images open full-screen on tap, with
native scroll/pinch zoom and Share. **Share exports the displayed downsampled image**,
not the potentially enormous original source. The system share sheet is shown only
on an explicit tap; nothing is sent automatically.

## Verification

- 40 core tests passed, zero failures, with the independent real OpenSSH fixture.
  New cases cover normalization/escaped traversal, same-directory absolute paths,
  parsed image ordering, profile isolation, dedup, consumer/final cancellation,
  disk budget, decoder bounds/corrupt data, real streaming/session reuse, byte caps,
  and a symlink escaping the resource root.
- A **73,533,330-byte PNG** decoded to **1600 × 800**, **5,120,000 decoded bytes**
  in the core acceptance test. This is the thumbnail allocation, not peak process RSS.
- The physical iPhone loaded the existing Wardrobe audit over the real Mac's SFTP
  connection, rendered its screenshot inline, opened it full-screen, pinched to zoom,
  and opened Share. The device test passed in 21.736 seconds at 15:39:22 local time.
  [Inline image](screenshots/audit-inline-image.png), [zoom viewer](screenshots/audit-image-zoom.png).

Generate disposable large/missing/duplicate/nested fixtures with
`python3 scripts/generate-image-fixture.py`. They are ignored under `.test-server`;
no 70 MB binary is committed. Run `scripts/test-openssh.sh swift test` for the core
checks. Physical tests remain opt-in using `TEST_RUNNER_REMOTEFILES_REAL_SERVER=1`;
`testAuditRemoteInlineImages` uses the saved audit recent, and
`testRelativeLargeAndMissingImages` uses the dedicated fixture connection.

- Final device core tests passed: **34 passed, 6 host-fixture cases skipped**, zero failures.
  Evidence: `/private/tmp/remotefiles-images-device-core.xcresult`.
- The final physical fixture test passed in **115.167 seconds** at 15:44:56,
  including the real 73.5 MB SFTP transfer, nested/duplicate images, missing-file
  actions and full-screen rendering. This is total automation time, not download
  latency or a peak-memory measurement. [Failure actions](screenshots/image-missing-retry.png),
  [large-image viewer](screenshots/image-large-viewer.png).
  The disposable **Image checks** connection and ignored fixtures are retained for repeat testing.

Local evidence: `/private/tmp/remotefiles-large-images.xcresult`,
`/private/tmp/remotefiles-images-final-core.log`,
`/private/tmp/remotefiles-audit-images.xcresult`, and the corresponding build/test logs.

Final installed-build audit rerun: **passed at 15:52:53**, including inline image, zoom and Share. Evidence: `/private/tmp/remotefiles-images-final-audit2.xcresult`. An earlier repeat scrolled past the target while it loaded; the test now stops at the filename placeholder, consistent with viewport cancellation.

## Text-only rendering regression (22 September, evening)

The image integration's `LazyVStack` could retain Textual's initial empty row at
zero height, leaving image-free Markdown blank even though Source was available.
Text rows now mount in a `VStack`; image downloads remain gated by viewport
geometry and retain their cancellation/cache behavior.

The new physical-device README regression test failed before the fix and passed
after it, checking actual rendered heading text, Source → Rendered, and Refresh.
[Fixed README in dark mode](screenshots/readme-rendering-fixed.png).
Evidence: `/private/tmp/remotefiles-blank-before.xcresult` and
`/private/tmp/remotefiles-blank-after.xcresult`. The latter bundle also contains an
audit test that could not find its required saved recent, before opening a document.

Final physical-device rerun: **3 tests passed, zero failures**. Verified README
initial rendering / Source toggle / Refresh (17.771 s), nested/duplicate and missing
images plus the 73.5 MB image and full-screen viewer (146.912 s), and the real
`READER_PERFORMANCE.md` text document (13.969 s). These are automation durations.
Evidence: `/private/tmp/remotefiles-blank-final.xcresult`. The fixed signed Release
build is installed and was relaunched normally after testing.
