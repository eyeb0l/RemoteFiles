# RemoteFiles roadmap

The preview stays read only. These are deliberate future decisions, not hidden or placeholder controls.

## After the first real usage session

- Physical iPhone over cellular/Tailscale acceptance, accessibility and Instruments profiling.
- Remote relative Markdown links and images with explicit resource policy.
- Image/PDF previews and single-file export through Share.
- Broader **verified** SSH key formats and optional passphrase conveniences.
- Richer sorting and advanced symlink behavior.
- Cached parsed-document eviction and stronger scroll restoration across app termination.
- Upstream the small Citadel cancellation hooks and remove vendoring when a verified release contains them.

## Separate write-capable iteration

Editing and uploads need conflict detection and safe replacement before transfer queues or recursive operations. No remote writes are implemented in this preview.

## Later possibilities

File Provider; deliberate offline pinning/sync; server-side search; jump hosts; FTP/FTPS or other protocols; an optional terminal handoff; deeper Tailscale discovery/onboarding; dedicated iPad layouts. A VPN, companion Mac service, accounts, analytics, monetisation, backend, and App Store release preparation are outside this preview.

Private-key export, automatic key installation, Mermaid, mathematical notation, raw HTML rendering, generic download management, and background SSH transfers are deferred.
