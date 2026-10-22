# RemoteFiles roadmap

The preview stays read only. These are deliberate future decisions, not hidden or placeholder controls.

## After the first real usage session

- Physical iPhone over cellular/Tailscale acceptance, accessibility and Instruments profiling.
- Complete physical acceptance of relative Markdown links, back reading position and original Save to Files; the implementation and automated checks are described in [document links](docs/DOCUMENT_LINKS.md), [original export](docs/ORIGINAL_EXPORT.md), and [acceptance](docs/AUTOMATED_ACCEPTANCE.md). Image Share continues to export display pixels; Save Original to Files preserves the original bytes.
- Additional verified private-key protection formats and hardware-backed security-key identities; OpenSSH RSA/ECDSA imports and optional biometric unlock are now implemented.
- Cached parsed-document eviction and layout-independent reading anchors (cross-launch Rendered/Source pixel positions are now saved for unchanged text).
- Upstream the small Citadel cancellation hooks and remove vendoring when a verified release contains them.

## Separate write-capable iteration

Editing and uploads need conflict detection and safe replacement before transfer queues or recursive operations. No remote writes are implemented in this preview.

## Implemented navigation and routing

[Single jump-host connections](docs/JUMP_HOSTS.md) and an [adaptive iPad workspace](docs/IPAD.md) are implemented. Physical bastion and iPad windowing acceptance remain separate.

[Folder search](docs/FOLDER_BROWSING.md#searching-file-contents) includes bounded client-side UTF-8 content search with source-line snippets. Server-side indexing, PDF/OCR search and persistent content indexes remain future work.

[Offline files and folder snapshots](docs/OFFLINE_FILES.md) are implemented with an explicit local library and manual updates. Physical locked-device and real-server offline acceptance remain separate.

## Later possibilities

File Provider; offline synchronization; server-side search; multiple jump hops; FTP/FTPS or other protocols; an optional terminal handoff; deeper Tailscale discovery/onboarding; additional iPad keyboard and multiwindow workflows. A VPN, companion Mac service, accounts, analytics, monetisation, backend, and App Store release preparation are outside this preview.

Private-key export, automatic key installation, Mermaid, mathematical notation, raw HTML rendering, generic download management, and background SSH transfers are deferred.
