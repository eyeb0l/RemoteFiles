# Citadel source provenance

Vendored from https://github.com/orlandos-nl/Citadel at exact revision
`ae8562f895de06ccb86fdb1cbb65fd99c8976e12` on 22 September 2026. Upstream MIT license is retained.

## Upstream status

Checked 29 October 2026: upstream `main` and the latest published release `0.12.1`
still resolve to the original revision above and do not contain these cancellation
hooks. Contribution: [Citadel #145](https://github.com/orlandos-nl/Citadel/pull/145). This includes direct/jump channel
creation, prompt handshake failure on close, and bounded exec-channel ownership.
Upstream monitoring has stopped; RemoteFiles maintains these patches independently.
The contribution is not a released dependency. Consider removing vendoring only if
an exact published release passes the [migration gate](../../docs/CITADEL_UPSTREAM.md),
including every other local patch described below or a verified replacement.
`SFTPIntegrationTests.testCitadelJumpChannelCloseFinishesHandshakeWithoutClosingParent`
guards prompt completion for immediate/delayed child closure and continued parent SFTP use.

## Local changes

`Sources/Citadel/ClientSession.swift` has two narrow additive changes: `SSHClientSettings.onChannelCreated`
is called by the existing NIO channel initializer. This lets RemoteFiles cancel or time out a connection by
closing its actual socket before host-key verification or user authentication completes. The handshake
handler also observes `channel.closeFuture` and fails its pending promise, so cancellation does not
have to wait for the dependency's hidden ten-second login timer. This replaces the original
`channelInactive` override: upstream NIOSSH consumes that event, and a jump connection retains its
handshake handler while awaiting authentication. Upstream regression tests exposed the resulting
ten-second delay even after closing the forwarded child. The close-future observer captures only the
promise and preserves an already completed authentication result.

Reason: the upstream `SSHClient.connect(on:settings:)` alternative invokes NIO synchronous pipeline
operations off the event loop. The unmodified source crashed the independent OpenSSH integration test
with `NIOCore/ChannelPipeline.swift:1208: Precondition failed`. The normal `connect(to:)` flow initializes
its pipeline on the proper event loop but otherwise hides the socket until authentication has finished.

The package manifest removes only the example executable, its ColorizeSwift dependency, and the
upstream test target. Production Citadel targets and dependencies remain the same. The application
and Xcode `Package.resolved` files pin all resolved transitive dependencies. No cryptography or
algorithm defaults were changed. See `docs/SSH_SPIKE.md` for local integration evidence.

`Sources/Citadel/SSHAuthenticationMethod.swift` adds the optional `discoverMethods` argument to
`passwordBased`. RemoteFiles' public-key installer enables it: an SSH `none` offer obtains the
server's advertised methods before a password is offered. A password-disabled server reports
`unsupportedPasswordAuthentication`; a rejected password reports `allAuthenticationOptionsFailed`.
The argument defaults to false for existing callers. Hosted/macOS fixture coverage verifies
unknown/changed host rejection, password-disabled refusal without key writes, and the discovery,
password-offer and rejected-password transitions. This does not change server authentication settings.
The synchronized `hasOfferedPassword` flag lets the installer also refuse a connection that
authenticates using the discovery `none` offer alone, before any remote command is executed.

`Sources/Citadel/SFTP/Client/SFTPClient.swift` makes `listDirectory` send `SSH_FXP_CLOSE` for its directory
handle after the final `readdir` (and best-effort when a `readdir` fails). Upstream leaves the handle open,
which forced RemoteFiles to open a fresh SFTP channel per operation. With the handle closed, RemoteFiles
reuses one SFTP channel per SSH session for listings, metadata and document reads. Any close status other
than `ok` (including `eof`, which the inbound handler otherwise passes through) fails the listing, so the
caller retires that channel instead of reusing it.

The same method gains an optional `resolvingPath` argument (default `true`, the upstream behaviour).
Upstream repeats `realpath` until the path stops changing, which costs at least one round trip even for
an already-canonical path. RemoteFiles canonicalizes once itself, because it reports that path, and
passes `false` to skip the redundant request.

`listDirectory` also gains an optional `concurrentReads` argument (default `1`, one `readdir` at a time as
upstream). A larger value keeps that many `readdir` requests in flight on the directory handle, so a folder
that fits one reply needs one round trip and a large folder is paced by the server rather than the RTT.
A new internal `sendRequestFuture` queues a request without awaiting it; event-loop tasks run in submission
order, so pipelined requests reach the server in issue order. Responses are consumed in request order and
every issued request is awaited. SFTP v3 does not promise that a server handles one handle's requests in
order (OpenSSH's sftp-server does), so correctness does not depend on it: each `readdir` takes a distinct
batch of the server's directory stream, names that arrive after an earlier request's EOF are kept unless
their filename was already returned (so a server that rewinds after EOF cannot repeat entries), and an
error status after EOF is ignored. After EOF no `readdir` is sent and `SSH_FXP_CLOSE` goes out at once behind
those still in flight, so draining them costs no extra round trip; its status must still be `ok`. An error
before EOF, task cancellation, or a reply other than names or EOF (upstream silently ended the listing on
one) stops new requests, drains those in flight, closes the handle and fails the listing. RemoteFiles
passes 8.

The vendored SFTP decoder rejects a zero-length frame and any frame larger than 1 MiB as soon as its
four-byte length prefix arrives. Both client and server `ByteToMessageHandler` instances use the matching
1 MiB-plus-prefix cumulation cap. SFTP v3 has no negotiated maximum; RemoteFiles requests file data in
64 KiB chunks, so the cap preserves its normal transfers while bounding memory committed to an
attacker-controlled incomplete frame.

`listDirectory` also bounds retained results to 10,000 entries and 16 MiB of decoded filename, longname,
attribute-extension, and per-entry storage by default. Both limits are optional parameters so a caller or
test may select a smaller bound. Crossing either limit stops issuing `READDIR`, drains the already-issued
pipeline window, sends one `CLOSE`, and then throws the corresponding `SFTPError`; the existing 1,000-entry
fixture remains below both defaults.

`SFTPFile.readAttributes()` sends `FSTAT` for the open handle rather than repeating pathname `STAT`.
RemoteFiles uses those attributes to validate size and type after `OPEN`, so they now describe the opened
object if a pathname is concurrently replaced. This is defense in depth for path races; SFTP v3 still has
no portable handle-relative open operation and this change alone does not make canonicalize-then-open
atomic.

## RSA and ECDSA identity imports

`ModernIdentityKeys.swift` adds import-only OpenSSH ECDSA P-256/P-384/P-521 parsers
and a modern RSA signer backed by Swift Crypto `_CryptoExtras`. RSA imports enforce
2048–8192-bit moduli, bounded canonical positive mpints, CRT coefficient consistency
and the crypto library's private-key consistency checks. ECDSA imports validate the
curve, private scalar and derived public point. The app compares the derived public
key with the outer container for every algorithm. `OpenSSHKey.swift` rejects trailing
public data and validates every padding byte, accepting a complete padding block.

`SSHAuthenticationMethod.rsaSHA2` offers SHA-512 then SHA-256, never SHA-1.
Citadel's pre-existing legacy RSA implementation is not used for identity signing.
Its manifest now uses the local, pinned `../swift-nio-ssh` source because RSA SHA-2
needs distinct authentication and public-key-format identifiers (RFC 8332).
Generated Ed25519 identities, cipher/KDF limits and host-key defaults are unchanged.
Runtime `ssh-keygen` import/fingerprint tests and independent OpenSSH authentication
cover every supported curve, encrypted/unencrypted originals and RSA SHA-2 fallback.

### Jump-host channel lifecycle

`SSHClient.jump(to:)` now calls `SSHClientSettings.onChannelCreated` before adding the nested
SSH handlers, matching direct connections. RemoteFiles tracks both the outer socket and the
forwarded child, so cancellation, deadline, failed destination trust and disconnect retire the
whole attempt. The direct-tcpip originator is a loopback placeholder with port zero; no local
listening port or agent forwarding is created. Both hop and destination retain their own
host-key validators and authentication methods.

### Bounded search command lifecycle

`SSHClient.executeBoundedCommand` exposes child-channel creation before the exec request,
so RemoteFiles can close only that channel on cancellation or deadline, including a late
channel-open completion. The existing buffered exec method delegates to it. `TTYHandler`
bounds stdout and stderr together and closes the child on overflow; previously stderr was
unbounded and overflowing stdout left the channel open. The existing exit-status behavior
is retained. Isolated OpenSSH tests exercise both output streams, cancellation, deadlines,
and continued SFTP use over the same SSH connection. No PTY, agent forwarding, or remote
file upload is added.

### Read-only descriptor identity lookup

`SFTPClient.readSymbolicLink` exposes the existing SFTP READLINK request and requires one
returned name. Its request enum wiring is added, and the dormant serializer is corrected
to emit READLINK (19), rather than SYMLINK (20). An OpenSSH regression verifies the raw
relative target. Server search uses it to require live directory descriptors and obtain the
SFTP process's mount namespace through its own procfs entries. No new SFTP write operations
or protocol extensions are introduced.
