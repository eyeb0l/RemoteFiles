# Offline files and folders

[Documentation](README.md) · [RemoteFiles](../README.md)

Choose **Keep Offline** in a file’s **Document actions** menu, or long-press a regular file in its folder. The app saves its original bytes and filename on this device. The save shows byte progress and a Cancel action; only one offline file or folder save runs at a time.

For a folder, choose **Folder actions → Keep Folder Offline**, or long-press its row. The setup sheet shows its path, explains the limits, and offers **Include Hidden Files**, initially matching the folder’s Show Hidden Files choice. **Save Folder Offline** saves all selected regular files, subfolders and empty directories. Symbolic links and special files are skipped and counted; links are never traversed. A resolved link chosen explicitly as the root uses its canonical target, which must remain within the connection’s starting folder.

Saved folders appear as folders in **Offline Files**. Open one to browse its saved hierarchy and preview or share individual originals entirely locally. Choose **Update Offline Folder** or **Remove Offline Folder** from its context menu, swipe actions, or **Saved folder actions**. Update repeats the original hidden-file choice and replaces the entire snapshot, including additions and deletions. A failed read, cancellation or limit never publishes a partial tree and leaves the previous snapshot readable. A folder update is a complete local commit, not a point-in-time snapshot of a server being edited concurrently.

Individually pinned files and overlapping folder snapshots are independent copies. Removing a folder never removes an individually saved copy of the same file or another pinned folder. Members of a folder are updated/removed as a group. All copies count towards the shared storage/file limits; there is no automatic deduplication or synchronization.

Open **Offline Files** from the library, even without a connection. Each copy shows the connection label, original path, byte count and saved date. The offline reader identifies the copy as offline; it never silently substitutes saved bytes for an online reader. Copies survive app relaunch, disconnects, connection edits and connection deletion. Demo has its own separate offline library. Saved-file counts and actions update across open windows when a copy is added, refreshed or removed.

Long-press a saved file (or swipe its row) to **Update Offline Copy** or **Remove Offline Copy**. Updating explicitly uses the network. It requires the saved connection to retain the same host, port, account, SSH key, starting folder and jump-host configuration; changing its display name is fine. If that route changed or was deleted, the old copy stays readable: save a new copy from the current connection. Removing a copy never deletes anything on the server. There is no automatic synchronization or background SSH transfer.

## Local previews and sharing

Markdown, UTF-8 text/code, static HTML/SVG, images, PDF, audio and video reuse the existing preview policies and native media controls. Text previews remain limited to 2 MiB; images use bounded downsampling, and codec support depends on the device. Unsupported/binary files can still be saved and shared. **Share Original** shares the saved original bytes and filename, including files too large for a text preview.

Resolved links keep their selected filename for sharing and their canonical source format for previews.

Tapping a relative Markdown link opens an already saved document locally. Within a saved folder, sibling, nested and parent paths resolve from the source document’s saved directory and stay inside that same snapshot. Overlapping folders and individual copies never substitute for its members. Individually saved documents can link to other individually saved copies from the same connection and saved route (host, account, key, starting folder and jump host). These links still work after disconnect, relaunch or connection deletion. Paths decode percent escapes once and preserve Unicode filename bytes.

Same-document heading links (`#details`) and Markdown file links with a heading fragment (`notes.md#details`) reveal the heading. Back restores the previous reader’s position during navigation. Missing headings, unsaved/hidden/skipped targets, unsupported types, query strings and paths outside a saved folder show an alert and keep the current document. Absolute paths and unsafe URL schemes remain blocked. If an open source copy is updated or removed, reopen it from Offline Files before following file links; an older reader does not silently navigate into a replacement snapshot. Opening another document uses the latest committed local copy and verifies it through the normal lease checks. Following a link never saves a missing file or starts SFTP.

Markdown images remain readable placeholders. No SFTP resolver or remote image loader is given to the offline reader. Static HTML/SVG retain their resource blocking; media assets forbid external references. Explicitly tapped, policy-approved HTTP/HTTPS links may still open the browser. Offline copies do not yet have Find, a heading-list menu, the image zoom viewer or reading positions saved across launches.

## Storage and lifecycle

- At most **100 files**, **128 MiB per file**, and **512 MiB of committed originals**. Receive-time and actual-file checks enforce the byte limits, including unknown or stale server size metadata. Files are not evicted automatically.
- At most **32 saved folder snapshots**. Each traversal is bounded to **16 levels**, **256 directories**, **10,000 entries** and **10 minutes**. Reaching any limit fails the save; the UI does not present a truncated folder as complete. Regular-file read failures also fail the save, while the explicit hidden/link/special-file exclusions are shown in the saved folder.
- Copies live under Application Support in `Offline-v1`, outside disposable preview caches. The directory is excluded from backups, uses owner-only permissions, and requests iOS **Complete** file protection on directories, originals and the index. These are device-local copies, not iCloud/Files synchronization. Protection while locked requires physical-device acceptance; a simulator is not proof of Data Protection behavior.
- A download must finish and validate within the original exporter’s 180-second deadline before publication. It uses canonical connection-root confinement, rechecks stable root/target paths after opening, and reads metadata from the open handle. Because portable SFTP v3 has no atomic descriptor-relative no-follow open, a namespace controlled by a concurrent adversary still requires a server-side jail or immutable root. Atomic index replacement publishes a complete file; failure, cancellation or interruption leaves the last committed copy intact. Backgrounding and disconnect cancel saves and drain their private transfer output. A cancelled future-backed transport keeps its slot until it actually stops. A busy request from another window returns without waiting for that drain; local quota, storage and concurrency errors do not mark a healthy SSH connection disconnected.
- Folder downloads pin the originally selected canonical root and file paths; a detected redirect fails the snapshot instead of following it. Traversal has its own requests so cancellation cannot cancel a coalesced foreground folder load. Unpublished originals remain private until every member is complete and validated; one atomic index replacement commits the tree. Interrupted staging is discarded at startup. Quotas include existing standalone files and other saved folders, while allowing the old snapshot to coexist temporarily with its replacement.
- Each copy stores a SHA-256 digest. Opening verifies regular-file type, size and digest before producing a local lease. The lease also retains the saved date and filename of those exact bytes across a concurrent refresh. The index is capped at 2 MiB before publication; a corrupt index fails closed and preserves existing files rather than silently resetting the library. Recognized abandoned transfer/lease output is cleaned when the store starts.
- Backgrounding preserves the offline library/reader navigation, while releasing protected preview resources and stopping playback. Returning to the app reopens the saved file locally; it does not reconnect or resume playback automatically.
- Up to four live local leases keep a preview/share valid while a pin is updated or removed. Temporary disk overhead is bounded separately: one in-progress replacement and up to four leased prior versions can coexist with committed originals. Native playback can retain its existing bounded local playback copy until stopped. Uninstalling the app removes its offline library.

## Verification

`OfflineFileTests` covers original bytes, relaunch, digest/symlink rejection, atomic refresh and index failure, count/byte/reader limits, cancellation with late writers, and removal during refresh. Shared stores are keyed by standardized absolute paths so directory creation, protection and URL directory hints cannot split one library between actors. `AppModelLifecycleTests` covers background cancellation, retained offline presentation, cross-window updates and Demo isolation, connection deletion and changed-route refresh rejection. The UI pin/disconnect/relaunch/remove flow runs against synthetic Demo data on iPhone and iPad; it also checks that the remote original remains readable after removing its local copy.

`OfflineFolderTests` adds recursive/empty/hidden folder cases, atomic refresh and failed replacement, shared quotas, traversal deadlines, late workers, store-driven cancellation/removal during unresponsive listings, independent single-file ownership, redirected listings/downloads and corrupt membership. Hosted model checks cover multiwindow folder updates, changed connection routes, connection deletion and background/Demo lifecycle. The folder UI journey pins Reports, disconnects, opens a nested document, backgrounds, relaunches and removes the snapshot. Real OpenSSH checks exercise canonical-root enforcement and local reads after disconnect.

Offline-link regressions cover saved-route isolation, snapshot membership, parent/nested/encoded paths, distinct Unicode byte names, missing/excluded targets, changed/removed sources, relaunch and cancellation. Demo UI journeys exercise local and linked headings, nested document navigation, Back and error recovery after disconnect.

Physical-device locked-file protection and real-server/network-loss acceptance remain separate from simulator results.

## Simulator examples

| iPhone library | iPhone saved reader | iPad saved reader |
| --- | --- | --- |
| <img src="screenshots/offline/iphone-library.png" width="220" alt="Offline library with a dated saved copy"> | <img src="screenshots/offline/iphone-reader.png" width="220" alt="Saved Markdown reader on iPhone"> | <img src="screenshots/offline/ipad-reader.png" width="320" alt="Saved Markdown reader in an iPad sheet"> |

Synthetic Demo files only; screenshots do not establish physical-device acceptance.

### Saved folder snapshots

| iPhone saved hierarchy | iPhone nested offline reader | iPad nested offline reader |
| --- | --- | --- |
| <img src="screenshots/offline-folders/iphone-folder.png" width="220" alt="Saved Reports folder with a 2026 subfolder and Markdown files"> | <img src="screenshots/offline-folders/iphone-reader.png" width="220" alt="A nested Quarterly review opened from the saved folder after disconnect"> | <img src="screenshots/offline-folders/ipad-reader.png" width="300" alt="Nested saved document in the iPad offline library sheet"> |

### Links between saved documents

Following `Heading notes.md#details` from another saved document after disconnect:

| iPhone linked heading | iPad linked heading |
| --- | --- |
| <img src="screenshots/offline-folders/iphone-link.png" width="220" alt="Offline Heading notes reader revealing the linked Details heading on iPhone"> | <img src="screenshots/offline-folders/ipad-link.png" width="300" alt="Offline Details heading reached through a saved document link in the iPad sheet"> |
