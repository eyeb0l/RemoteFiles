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
- Extend reading history to standalone image previews and offline PDF copies. Layout-independent text/block anchors cover Markdown, Source (including plain text) and static HTML; remote PDFs save their page position; inactive reader-content eviction is implemented. Physical-device layout and memory acceptance remain outstanding. See [reader behavior](docs/READER.md).
- Automatic or incremental search-index refresh. [Folder search](docs/FOLDER_BROWSING.md) already supports explicit persistent local indexes, bounded PDF text and on-device OCR, plus case, whole-word and file-type filters. Saved indexes are snapshots and must be rebuilt to reflect remote changes.
- Offline synchronization, File Provider, multiple jump hops, other protocols such as FTP/FTPS, optional terminal handoff, deeper Tailscale onboarding, and additional iPad keyboard and multiwindow workflows.
- Byte-offset resume for interrupted SSH downloads, expanded transfer quotas, and physical-device background-transfer acceptance. Managed downloads restart interrupted files from the beginning.

<a id="separate-write-capable-iteration"></a>
## Newly implemented

- PDF search results open at their matching page, and remote PDFs remember their page position. See [reader behavior](docs/READER.md) and [folder search](docs/FOLDER_BROWSING.md).
- Private-key export through Files, with device authentication and a separate confirmation; imported encryption is preserved. See [key support](docs/KEY_SUPPORT.md).
- Opt-in public-key installation while saving a direct connection, using the existing reviewed installer. See [public-key installation](docs/PUBLIC_KEY_INSTALLATION.md).
- Locally rendered Mermaid, mathematical notation and static HTML inside Markdown. Standalone HTML keeps its [static preview](docs/HTML_PREVIEWS.md).
- A persistent [download queue](docs/DOWNLOADS.md) with progress, cancellation, retry and Files export, plus system-managed continuation of active SSH transfers in the background.

These features still need physical-device acceptance; see [the dated status record](PREVIEW_STATUS.md) for validation.

## Remote editing and uploads

Editing and uploads would require a separate write-capable iteration with conflict detection and safe replacement. Remote browsing does not write files. The separately confirmed [public-key installation](docs/PUBLIC_KEY_INSTALLATION.md) feature can update `authorized_keys` on a compatible server.

A VPN, companion Mac service, accounts, analytics, monetisation, backend and App Store release preparation are outside this preview.
