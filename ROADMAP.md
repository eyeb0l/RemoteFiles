# RemoteFiles roadmap

The preview stays read only. These are deliberate future decisions, not hidden or placeholder controls.

## After the first real usage session

- Physical iPhone over cellular/Tailscale acceptance, accessibility and Instruments profiling.
- Complete physical acceptance of relative Markdown links, back reading position and original Save to Files; the implementation and automated checks are described in [document links](docs/DOCUMENT_LINKS.md), [original export](docs/ORIGINAL_EXPORT.md), and [acceptance](docs/AUTOMATED_ACCEPTANCE.md). Image Share continues to export display pixels; Save Original to Files preserves the original bytes.
- Broader **verified** SSH key formats and optional passphrase conveniences.
- Richer sorting and advanced symlink behavior.
- Cached parsed-document eviction and stronger scroll restoration across app termination.
- Upstream the small Citadel cancellation hooks and remove vendoring when a verified release contains them.

## Separate write-capable iteration

Editing and uploads need conflict detection and safe replacement before transfer queues or recursive operations. No remote writes are implemented in this preview.

## Later possibilities

File Provider; deliberate offline pinning/sync; server-side search; jump hosts; FTP/FTPS or other protocols; an optional terminal handoff; deeper Tailscale discovery/onboarding; dedicated iPad layouts. A VPN, companion Mac service, accounts, analytics, monetisation, backend, and App Store release preparation are outside this preview.

Private-key export, automatic key installation, Mermaid, mathematical notation, raw HTML rendering, generic download management, and background SSH transfers are deferred.
