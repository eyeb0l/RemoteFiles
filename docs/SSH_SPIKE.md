# SSH/SFTP dependency spike — 22 September 2026

Citadel is retained behind `SFTPRemoteFileService`. Its exact upstream source revision is
`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`. The MIT-licensed source is vendored in
`Vendor/Citadel` with two small connection-lifecycle patches recorded in `UPSTREAM.md`.
Transitive dependency versions are recorded in the checked-in package resolution files.

## Why the local patch exists

The upstream `SSHClient.connect(on:settings:)` route crashed a real OpenSSH test at
`NIOCore/ChannelPipeline.swift:1208: Precondition failed`: its synchronous pipeline setup
ran outside the event loop. Its normal `connect(to:)` route sets up the pipeline correctly,
but does not expose a socket until authentication finishes. That prevents callers from
closing an in-flight connection immediately.

The local patch adds `SSHClientSettings.onChannelCreated` to the existing event-loop
initializer and makes the handshake promise fail on `channelInactive`. RemoteFiles uses
the normal connection API, retains the socket from creation, and closes it for cancellation,
timeouts, trust failure, disconnect, or backgrounding. No cipher, KDF, cryptography, or SSH
algorithm defaults were changed. Deprecated algorithm collections are never enabled.
The unused upstream example/test targets and example-only ColorizeSwift dependency were
removed from the vendored package manifest.

Citadel's directory helper also leaves its directory handle open. The adapter scopes each
operation to an SFTP child channel and closes that channel when complete, releasing remote
handles while reusing the authenticated SSH connection. This avoids growing handle use
without patching the SFTP protocol implementation. The application only exposes realpath,
stat, readdir, and read operations; it does not issue remote writes or shell commands.

Citadel's `readAll` trusts the initial stat size. The adapter instead reads in up-to-64 KiB
chunks, applies the configured limit to every response, and probes one byte beyond the limit
to detect growth. It closes the SFTP channel on error/cancellation. An explicit 15-second
operation deadline bounds connection/list/read operations; the dependency also has a
10-second login timeout. Requests reuse an existing SSH connection without automatic
reconnect loops. A deliberate next request reconnects if the connection has ended.

## Independent test environment and results

Test host: macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 5 language mode, system
OpenSSH 10.3p1 / LibreSSL 3.3.6. The server is `/usr/sbin/sshd` with a temporary, loopback-only
configuration at `127.0.0.1:22222`, temporary host/identity keys, and a temporary authorised
fixture directory. Password/PAM authentication is disabled. The launcher removes its files
and terminates its server after the run. Existing SSH files, Remote Login, sshd settings,
firewall, and Tailscale configuration are untouched.

The macOS core run at 13:17:04 local time passed **30 XCTest tests, zero failures**
in 3.58 seconds. Two subsequently added deterministic receive-time growth tests also passed
on macOS. The complete final suite then ran on **iPhone 18 Pro / iOS 27.0 Simulator at
13:22:28: 32 XCTest tests passed, zero failures**, including the real OpenSSH fixture and
actual device-only, unlocked-accessibility Keychain storage attributes/save/reload/delete.
The simulator test host was ad-hoc signed with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`.
The earlier unsigned run failed Keychain with `-34018`; signing fixed it without custom
entitlements or a personal development team. The 32 tests are 2 bounded-reader, 7 document-policy,
5 identity/trust, 5 real transport, and 13 state/persistence tests. The macOS and iOS-specific
identity suites each have five cases; macOS runs the full ssh-keygen parser matrix while iOS
runs the actual Keychain case. These are not physical-iPhone or cellular/Tailscale results.
Final application Simulator/device build evidence is recorded separately in `PREVIEW_STATUS.md`.

Verified against this OpenSSH server:

- On-device-style generated Ed25519 private key authenticated and read Markdown.
- Ordinary `ssh-keygen -t ed25519` unencrypted and default encrypted imports authenticated.
- Unknown host and a deliberately mismatching fixture trust record failed before user
  authentication; the fixture log recorded neither an accepted nor failed public-key offer.
- Canonical paths, Unicode/spaces, dotfiles, empty folders/files, a 1,000-entry directory,
  a resolved symlink, permission denial, missing files, oversized files, exact byte limits,
  reused authentication, and explicit disconnect/reconnect.
- A separate silent TCP fixture proved cancellation of an in-flight handshake returned
  within two seconds, and a configured one-second deadline within 2.5 seconds. The combined
  cancellation/deadline test completed in 1.198 seconds on the final simulator run.
- The receive-time helper used by production rejected controlled growth from a 4-byte initial
  stat to 9 received bytes with an 8-byte limit. A separate case proved short reads continue and
  an exact-limit read probes for EOF. These are deterministic byte-receiving tests, not a
  claim to have scheduled a growing file on the independent OpenSSH server.
- Unit tests verified encrypted representation preservation, no private material in
  metadata, missing/wrong passphrases, malformed/public-only keys, deletion safeguards,
  trust persistence/reset, and unlocked identity clearing.

## Verified key matrix

| Input | Result |
| --- | --- |
| Generated Ed25519 | Authentication and SFTP passed |
| OpenSSH Ed25519, unencrypted (`none`) | Import, authentication and SFTP passed |
| OpenSSH Ed25519, default ssh-keygen encrypted AES-256-CTR/bcrypt 16 | Import, authentication and SFTP passed |
| OpenSSH Ed25519, AES-128-CTR/bcrypt 16 | Parser import passed; separate authentication not exercised |
| Missing passphrase | Specific missing-passphrase error |
| Wrong passphrase | Specific failed-decryption error |
| bcrypt rounds 32 | Explicit unsupported-format rejection |
| AES-256-CBC | Explicit unsupported-format rejection |
| Public-key-only input | Specific public-key-only error |
| Malformed input | Specific malformed-key error |

The supported parser policy is Ed25519 OpenSSH with no encryption or AES-128/256-CTR and
bcrypt rounds 1–31. The table distinguishes tested values from that permitted range; every
round count was not tested. Other algorithms/formats are deferred. The app never recommends
removing protection from an existing key.

## Reproduce

```sh
scripts/test-openssh.sh swift test

scripts/test-openssh.sh xcodebuild test \
  -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -collect-test-diagnostics never -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

The script creates fresh fixtures for each run. It also exports `TEST_RUNNER_REMOTEFILES_*`
variables for an `xcodebuild test` command using an iOS XCTest target. Tests skip explicitly
when fixture variables are absent. A skip must not be described as a passed SFTP test.
A custom unused loopback port can be selected with `REMOTEFILES_TEST_PORT`.

Measured macOS loopback sample (13:09:44 run):

| Operation | Result |
| --- | --- |
| Cold connection/authentication | 49.3 ms |
| Cold directory including connection | 67.2 ms |
| Warm read of 173,321-byte report | 4.86 ms; four requests including EOF |
| Warm 1,000-entry directory | 217.3 ms |
| Journey total file bytes/read requests | 173,419 bytes / 9 requests |
| Authenticated connections before explicit disconnect | 1 |

These are one local loopback sample and are not iPhone/cellular performance claims.
The final simulator run measured a 90.4 ms cold connection, 119.6 ms cold directory including
connection, 9.97 ms warm 173,321-byte report, and 598.1 ms 1,000-entry directory. The simulator
reused one SSH connection for the browse/read journey. These samples vary with local simulator
and build load; they do not establish remote-network or UI-hitch performance. Later samples
belong in `PREVIEW_STATUS.md` and do not replace physical-device profiling.

Remaining validation: physical iPhone outside local Wi-Fi over Tailscale; denied local-network
permission; iOS background/foreground behavior with actual networking; and remote-file growth
during a read under controlled OpenSSH server timing. Receive-time growth protection is covered
with deterministic chunks through the same helper as production; independent OpenSSH covers
static overflow, short buffered reads, and exact boundaries.
