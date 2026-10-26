# RemoteFiles roadmap

RemoteFiles is a read-only SFTP browser. This page separates work that remains to be done from features already available. It is a list of possibilities and outstanding checks, not a release schedule.

<a id="after-the-first-real-usage-session"></a>
## Acceptance still needed

Automated and Simulator results do not establish behavior on every physical device or server. Remaining checks include physical iPhone use over cellular/Tailscale, accessibility and Instruments profiling; physical iPad windowing; a production bastion; and offline use on a locked device and a real server. The [manual acceptance guide](docs/MANUAL_ACCEPTANCE.md) and [dated status record](PREVIEW_STATUS.md) provide context and distinguish completed checks from outstanding ones.

Complete physical acceptance of relative Markdown links, restoring reading position and Save Original to Files. [Document links](docs/DOCUMENT_LINKS.md) and [original export](docs/ORIGINAL_EXPORT.md) describe the implementation and recorded checks. Image Share exports display pixels; Save Original to Files preserves the original bytes.

<a id="implemented-navigation-and-routing"></a>
<a id="later-possibilities"></a>
## Improvements under consideration

- More verified private-key protection formats and hardware-backed security-key identities. OpenSSH RSA/ECDSA imports and optional biometric unlock are already available; see [key support](docs/KEY_SUPPORT.md).
- Cached parsed-document eviction and layout-independent reading anchors. Rendered and Source positions are currently saved as pixel coordinates for unchanged text.
- Upstream the Citadel cancellation hooks and remove vendoring when a verified release contains them.
- Persistent search indexes, PDF/OCR search and additional search capabilities. [Folder search](docs/FOLDER_BROWSING.md) already supports bounded names and UTF-8 contents search, with optional server assistance and SFTP fallback.
- Offline synchronization, File Provider, multiple jump hops, other protocols such as FTP/FTPS, optional terminal handoff, deeper Tailscale onboarding, and additional iPad keyboard and multiwindow workflows.
- Private-key export, automatic key installation, Mermaid, mathematical notation, rendering raw HTML embedded in Markdown, generic download management and background SSH transfers. Standalone HTML already has a [static preview](docs/HTML_PREVIEWS.md).

<a id="separate-write-capable-iteration"></a>
## Remote editing and uploads

Editing and uploads would require a separate write-capable iteration with conflict detection and safe replacement. Remote browsing does not write files. The separately confirmed [public-key installation](docs/PUBLIC_KEY_INSTALLATION.md) feature can update `authorized_keys` on a compatible server.

A VPN, companion Mac service, accounts, analytics, monetisation, backend and App Store release preparation are outside this preview.
