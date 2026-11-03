# RemoteFiles roadmap

RemoteFiles is a read-only SFTP browser. This page separates work that remains to be done from features already available. It is a list of possibilities and outstanding checks, not a release schedule.

<a id="after-the-first-real-usage-session"></a>
## Acceptance still needed

Automated and Simulator results do not establish behavior on every physical device or server. Remaining checks include off-site cellular use, Instruments profiling, file protection while locked, physical iPad windowing, a production bastion, and a changed server key. Network interruption, Wi-Fi/cellular handoff, accessibility, downloads, keys and offline use otherwise [passed on the iPhone](docs/REAL_SERVER_ACCEPTANCE.md#31-october-2026-iphone-session) on 31 October 2026, which also found transfers that don't notice a dead network and an offline link limit. The [manual acceptance guide](docs/MANUAL_ACCEPTANCE.md) and [dated status record](PREVIEW_STATUS.md) provide context and distinguish completed checks from outstanding ones.

Complete iPad acceptance of relative Markdown links and restoring reading position; on the iPhone these and Save Original to Files passed. [Document links](docs/DOCUMENT_LINKS.md) and [original export](docs/ORIGINAL_EXPORT.md) describe the implementation and recorded checks. Image Share exports display pixels; Save Original to Files preserves the original bytes.

<a id="implemented-navigation-and-routing"></a>
<a id="later-possibilities"></a>
Citadel is maintained locally with its cancellation and safety fixes. Upstream review
does not block RemoteFiles; see [dependency maintenance](docs/CITADEL_UPSTREAM.md).

## Improvements under consideration

- More verified private-key protection formats and hardware-backed security-key identities. OpenSSH RSA/ECDSA imports and optional biometric unlock are already available; see [key support](docs/KEY_SUPPORT.md).
- Physical-device layout and memory acceptance of reading history. Layout-independent text/block anchors cover Markdown, Source (including plain text) and static HTML; remote and offline PDFs save their page position; offline copies share the connected reader's history; inactive reader-content eviction is implemented. Standalone images fit their view and have no position to save. See [reader behavior](docs/READER.md).
- Updating saved search indexes while the app is closed. Indexes set to **Update Automatically** update only while the app is open and connected; see [folder search](docs/FOLDER_BROWSING.md#updating-automatically).
- Offline synchronization, File Provider, multiple jump hops, other protocols such as FTP/FTPS, optional terminal handoff, deeper Tailscale onboarding and additional iPad multiwindow workflows. Keyboard shortcuts, arrow-key selection in folder lists and Escape to close Find are available; see [iPad workspace](docs/IPAD.md#keyboard-shortcuts).
- Physical-device acceptance of multi-gigabyte downloads and of resuming after iOS ends a background transfer. Managed downloads continue interrupted files from their received bytes while the remote file is unchanged; on the iPhone this [passed](docs/REAL_SERVER_ACCEPTANCE.md#2-november-2026-download-resume) after Airplane Mode and a force quit. See [downloads](docs/DOWNLOADS.md#resuming-interrupted-downloads).

<a id="separate-write-capable-iteration"></a>
## Newly implemented

- Downloads accept files up to 4 GiB and hold up to 16 GiB in total, always leaving 1 GiB of device storage free. See [downloads](docs/DOWNLOADS.md).
- **Update Automatically** keeps a saved search index current: opening its folder updates it in the background, while the app is open and connected, once it is more than 15 minutes old. See [folder search](docs/FOLDER_BROWSING.md#updating-automatically).
- **Update Index** refreshes a saved search index by reading only new files and files whose size or modification date changed, and drops removed files. See [folder search](docs/FOLDER_BROWSING.md#updating-an-index).
- Retry continues interrupted downloads from the bytes already received when the remote file's size, modification time and final received bytes are unchanged. See [downloads](docs/DOWNLOADS.md#resuming-interrupted-downloads).
- Offline copies have Find, Headings, the image zoom viewer and shared reading positions for text and PDFs. See [offline files](docs/OFFLINE_FILES.md#offline-reader).
- PDF search results open at their matching page, and remote PDFs remember their page position. See [reader behavior](docs/READER.md) and [folder search](docs/FOLDER_BROWSING.md).
- Private-key export through Files, with device authentication and a separate confirmation; imported encryption is preserved. See [key support](docs/KEY_SUPPORT.md).
- Opt-in public-key installation while saving a direct connection, using the existing reviewed installer. See [public-key installation](docs/PUBLIC_KEY_INSTALLATION.md).
- Locally rendered Mermaid, mathematical notation and static HTML inside Markdown. Standalone HTML keeps its [static preview](docs/HTML_PREVIEWS.md).
- A persistent [download queue](docs/DOWNLOADS.md) with progress, cancellation, retry and Files export, plus system-managed continuation of active SSH transfers in the background.

These features still need physical-device acceptance; see [the dated status record](PREVIEW_STATUS.md) for validation.

## Remote editing and uploads

Editing and uploads would require a separate write-capable iteration with conflict detection and safe replacement. Remote browsing does not write files. The separately confirmed [public-key installation](docs/PUBLIC_KEY_INSTALLATION.md) feature can update `authorized_keys` on a compatible server.

A VPN, companion Mac service, accounts, analytics, monetisation, backend and App Store release preparation are outside this preview.
