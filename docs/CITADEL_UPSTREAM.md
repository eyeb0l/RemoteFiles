# Citadel maintenance and optional release migration

RemoteFiles maintains its patched Citadel source locally. Upstream review is not a
prerequisite for development or releases. PR #145 was submitted as an optional
contribution; monitoring and further upstream work have been stopped. Keep the
vendored dependency and its local regression coverage. The migration checklist
below applies only if we choose to evaluate a suitable published release later.

Checked on **29 October 2026**: upstream's latest published release,
[0.12.1](https://github.com/orlandos-nl/Citadel/releases/tag/0.12.1), and `main`
both resolve to `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`, the original vendored
revision. Neither contains RemoteFiles' cancellation hooks. Vendoring remains
necessary; a submitted or merged pull request is not a verified release.

Upstream cancellation contribution: [Citadel #145](https://github.com/orlandos-nl/Citadel/pull/145).

The connection contract is to expose the direct socket and jump-host child
channel on their event loop before SSH negotiation (retaining every Happy Eyeballs
candidate socket), and to fail an unfinished
handshake promptly when its channel becomes inactive. Exec cancellation also
requires access to its child channel before the exec request, including a
channel whose creation finishes after the caller cancels. Closing an exec child
must leave the authenticated SSH connection usable for SFTP.

## Independent RemoteFiles validation (29 October 2026)

The local regression
`SFTPIntegrationTests.testCitadelJumpChannelCloseFinishesHandshakeWithoutClosingParent`
passes against the isolated OpenSSH fixture with the vendored close-future fix.
Restoring the original `channelInactive` implementation makes both assertions
fail at approximately ten seconds each; restoring the fix makes the test pass.
This detects retained authentication work that the application's detached
deadline wrapper can otherwise hide.

All six focused OpenSSH lifecycle tests (this new method plus the five listed
below) pass with zero skips. All 39 repository Python regressions pass. Project
regeneration and `git diff --check` pass. No dependencies or lockfiles changed;
Simulator and physical-device verification were not run for this local change.

## Contribution validation (29 October 2026)

Upstream contribution commit: `e5538af` (based on `0.12.1`). Apple Swift 6.4.2,
macOS arm64:

- All 14 added cancellation/output-bound regressions pass. They use embedded NIO
  channels and in-process loopback servers, with no external SSH configuration.
- Full upstream `swift test`: 49 methods, 44 passed, five existing external-SSH
  skips, zero failures. Skips were `Citadel2Tests.testConnectToOpenSSHServer`,
  `Citadel2Tests.testStdinStream`, `EndToEndTests.testJump`, and both integration
  methods in `RemotePortForwardTests`; their SSH environment was not configured.
- Five RemoteFiles isolated OpenSSH methods pass without skips: the four named
  cancellation tests below plus
  `testJumpHostVerifiesBothHostsAndUsesIndependentKeysThenReusesAndReconnects`.
- All 39 repository Python regressions pass; project regeneration produces no
  changes and `git diff --check` passes. No Simulator or physical-device run was
  performed for this contribution; release migration still requires full acceptance.

The upstream regressions exposed a bug in the original vendored patch:
NIOSSH consumes `channelInactive`, so a retained jump-handshake handler still
waited ten seconds after its channel closed. Both the contribution and vendored
copy now observe `channel.closeFuture`, capturing only the completion promise.
The prompt-close jump tests failed before this correction and pass afterward.
Exec closure can complete with empty output or a transport error; the caller owns
translation to cancellation. Tests verify the cancelled command is never executed
and that a subsequent command succeeds over the same parent connection.

## Other blockers to removing the vendored package

The complete patch provenance is in [Vendor/Citadel/UPSTREAM.md](../Vendor/Citadel/UPSTREAM.md).
A release containing only cancellation support is insufficient. The application
also relies on these changes, or verified replacements with equivalent behavior:

- Password-method discovery and `hasOfferedPassword`, distinguishing disabled
  password authentication from rejection and refusing discovery-only login for
  public-key installation.
- Directory-handle closure on success and failure; optional canonical-path
  resolution; pipelined `READDIR` with ordered draining, EOF/error handling and
  cancellation; retained-listing entry and metadata-byte limits.
- Rejection of zero-length and over-1-MiB SFTP frames, with matching decoder
  cumulation limits on both clients and servers.
- Handle-based `FSTAT` in `SFTPFile.readAttributes()`, so checks describe the
  opened file rather than a replacement at the same path.
- Validated OpenSSH RSA/ECDSA imports, strict public-data/padding validation,
  and RSA SHA-512/SHA-256 authentication without SHA-1 signatures.
- A combined stdout/stderr limit and exec-child closure on output overflow.
- `readSymbolicLink`, request wiring and the correct READLINK packet identifier,
  used by server search for read-only descriptor and namespace checks.

Citadel's manifest also uses the local `../swift-nio-ssh` package for its distinct
authentication and public-key encoding identifiers. That dependency has its own
[authentication and wire-format hardening](../Vendor/swift-nio-ssh/UPSTREAM.md).
Removing Citadel vendoring must preserve those changes and resolve one compatible
NIOSSH package. It does not authorize removing the independently patched Textual
or NIOSSH packages.

## Release migration gate

1. Record the published release URL, version and resolved commit. Inspect that
   exact tagged source to confirm the cancellation implementation and each
   blocker above; do not rely on release notes or `main`. Record any application
   adaptation that replaces a local API without weakening its contract.
2. Change the root `Package.swift` Citadel dependency to that exact release.
   Resolve and commit both `Package.resolved` and
   `RemoteFiles.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
   Check their actual Citadel and transitive revisions, including NIOSSH, and
   ensure no local checkout or package override supplies the tested Citadel.
3. Run `python3 -B scripts/generate-project.py` and retain any generated changes;
   the Xcode project consumes the root package. Remove `Vendor/Citadel` only in
   the candidate migration, preserving its patch/history links in this document.
   Update dependency documentation and license attribution for the final graph.
4. Run focused OpenSSH regression coverage, then full acceptance against the
   exact candidate source and resolved dependencies. Keep logs and xcresults;
   skipped fixture tests do not establish cancellation or authentication success.
5. Commit the removal only after all required lanes pass with the published
   dependency. Report failures or missing release behavior as blockers, retaining
   the vendored package until resolved.

Focused verification:

```sh
scripts/test-openssh.sh swift test --filter 'SFTPIntegrationTests|SFTPDirectoryReadTests|PublicKeyInstallerTests|IdentityTests|BoundedPreviewReaderTests'
```

In particular, `SFTPIntegrationTests` must pass
`testCancellationAndDeadlineCloseSilentHandshakeSocket`,
`testJumpHostCancellationAndDeadlineCloseTheSilentDestinationTunnel`,
`testBoundedSearchExecClosesOnOutputOverflowCancellationAndDeadlineWithoutClosingSFTP`,
`testCancelBeforeConnectDoesNotAuthenticate`, and the changed/unknown-host,
shared-channel retirement and reconnect tests. The remaining selected suites
cover listing drains and bounds, malformed frames, FSTAT, password discovery,
key parsing and the application's detached cancellation/deadline behavior.
`testCitadelJumpChannelCloseFinishesHandshakeWithoutClosingParent` directly checks
immediate and delayed child closure against OpenSSH, bypassing the application's
detached deadline wrapper. It requires the retained Citadel handshake to finish
within two seconds and verifies continued SFTP use on the parent connection.

Full local acceptance includes macOS/OpenSSH, signed hosted Simulator and UI,
VoiceOver, and optimized generic-device compilation:

```sh
python3 -B scripts/generate-project.py
git diff --check
python3 -B scripts/test-acceptance.py --allow-dirty \
  --simulator SIMULATOR_UDID \
  --output /private/tmp/remotefiles-citadel-release-NEW_RUN
```

Use a fresh output directory outside the checkout and one run per simulator;
pass `--port 22223` if the default fixture ports are occupied. Omit
`--allow-dirty` for a committed candidate. Follow
[automated acceptance](AUTOMATED_ACCEPTANCE.md) for allowed skips and evidence
requirements, and [CI policy](CI.md) for the additional lanes selected by a
dependency/vendor change. These checks do not establish physical-device or
cellular-network behavior.
