# Relative document links

Only a user tap in rendered Markdown starts a remote document navigation request.
`DocumentPolicy` retains relative link actions for the injected reader handler;
unsafe schemes, absolute remote paths and scheme-relative URLs lose their actions.
HTTP/HTTPS links keep the existing explicit external-open behavior.

Relative paths resolve from the canonical source document directory. SFTP resolves
both the connection's starting directory and source document with REALPATH before
lexical resolution. `..` may reach a parent within that starting directory, but
cannot leave it. Percent escapes decode exactly once. Unicode and spaces are
preserved. The target is canonicalized again and must be a regular file within
the canonical starting directory. Symlinks outside it fail before navigation.
Markdown, supported UTF-8 text/source, images and PDFs are valid destinations.

Linked entries carry their canonical navigation root. Text reads and refreshes
recheck the target against that root through `readDocumentFile`, so replacing an
already opened target with an escaping symlink cannot make a subsequent refresh
read outside the boundary. Media keeps its existing, stricter parent-directory
resource-download policy. Automatic Markdown image paths remain confined to the
source document's own directory tree; enabling document parent links does not
widen image access.

Heading fragments (`#heading`) and queries (`?download=1`) are deliberately not
implemented. Tapping these relative links explains the limitation and tells the
reader to use a plain file link. Missing files, unsupported types and confinement
failures show an alert while retaining the current document. A second link,
Cancel, navigation away, session change or backgrounding cancels an in-flight
request; request IDs and session checks prevent late publication from a transport
that completes after cancellation.

Every reader route owns separate Rendered and Source scroll coordinates.
`ScrollPosition` and `onScrollGeometryChange` restore those coordinates after
push/back, mode changes and content remounts. Restoration waits for the rendered
text geometry instead of treating Textual's initial empty layout as the saved
position. Returning to an unchanged reader does not refetch its text; Refresh or
a new connection session still reloads it. A user scroll takes over restoration
if an updated document has become shorter.

## Automated acceptance

- `DocumentNavigationTests` covers normalized parent/nested paths, exact-once
  percent decoding, Unicode, root confinement, unsafe references, actionable
  fragment/query errors, missing Demo files, cancellation, and unchanged image
  boundaries.
- `DocumentReadingPositionTests` uses the production `DocumentContentView` in a
  hosted iOS `NavigationStack`, reads actual native scroll offsets, and verifies
  push/back, independent modes and a fresh content subtree. It also checks the
  short document’s actual native parent-link hit map after mount, push/back and
  remount and a paragraph layout shift on the same overlay. UIKit receives the
  current Textual layout during overlay updates, with resolved origins included
  in layout equality.
- The Demo `Navigation guide.md` contains unique reading markers and links near
  its end. `Open nested note` opens `Reports/Linked notes.md`; its parent link
  resolves back within `/Projects`. Additional links cover fragments, missing
  files, an escaping parent and an unsupported archive without a real server.
- SFTP integration checks canonical in-root links, an escaping symlink, configured
  root aliases, and target replacement before a confined reread. The host fixture
  also changes bytes after explicit disconnect and requires a new SSH connection.
- Ordinary demo UI tests check nested/parent links, native Back marker coordinates,
  actionable errors retaining the reader, and native export picker cancellation.

Physical iPhone/VoiceOver gestures, rotor and Braille acceptance remain a human
step. Simulator structural/speech evidence must be reported separately.
