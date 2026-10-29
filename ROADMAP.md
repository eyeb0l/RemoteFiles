# RemoteFiles roadmap

RemoteFiles is a read-only SFTP browser. This page separates work that remains to be done from features already available. It is a list of possibilities and outstanding checks, not a release schedule.

<a id="after-the-first-real-usage-session"></a>
## Acceptance still needed

Automated and Simulator results do not establish behavior on every physical device or server. Remaining checks include physical iPhone use over cellular/Tailscale, accessibility and Instruments profiling; physical iPad windowing; a production bastion; and offline use on a locked device and a real server. The [manual acceptance guide](docs/MANUAL_ACCEPTANCE.md) and [dated status record](PREVIEW_STATUS.md) provide context and distinguish completed checks from outstanding ones.

Complete physical acceptance of relative Markdown links, restoring reading position and Save Original to Files. [Document links](docs/DOCUMENT_LINKS.md) and [original export](docs/ORIGINAL_EXPORT.md) describe the implementation and recorded checks. Image Share exports display pixels; Save Original to Files preserves the original bytes.

<a id="implemented-navigation-and-routing"></a>
<a id="later-possibilities"></a>
Citadel is maintained locally with its cancellation and safety fixes. Upstream review
does not block RemoteFiles; see [dependency maintenance](docs/CITADEL_UPSTREAM.md).

## Improvements under consideration

- More verified private-key protection formats and hardware-backed security-key identities. OpenSSH RSA/ECDSA imports and optional biometric unlock are already available; see [key support](docs/KEY_SUPPORT.md).
- Extend reading history to PDF and standalone image previews. Layout-independent text/block anchors cover Markdown, Source (including plain text) and static HTML; inactive reader-content eviction is implemented. Physical-device layout and memory acceptance remain outstanding. See [reader behavior](docs/READER.md).
- Automatic or incremental search-index refresh and opening PDF search results at the matching page. [Folder search](docs/FOLDER_BROWSING.md) already supports explicit persistent local indexes, bounded PDF text and on-device OCR, plus case, whole-word and file-type filters. Saved indexes are snapshots and must be rebuilt to reflect remote changes.
- Offline synchronization, File Provider, multiple jump hops, other protocols such as FTP/FTPS, optional terminal handoff, deeper Tailscale onboarding, and additional iPad keyboard and multiwindow workflows.
- Private-key export, automatic key installation, Mermaid, mathematical notation, rendering raw HTML embedded in Markdown, generic download management and background SSH transfers. Standalone HTML already has a [static preview](docs/HTML_PREVIEWS.md).

<a id="separate-write-capable-iteration"></a>
## Remote editing and uploads

Editing and uploads would require a separate write-capable iteration with conflict detection and safe replacement. Remote browsing does not write files. The separately confirmed [public-key installation](docs/PUBLIC_KEY_INSTALLATION.md) feature can update `authorized_keys` on a compatible server.

A VPN, companion Mac service, accounts, analytics, monetisation, backend and App Store release preparation are outside this preview.
