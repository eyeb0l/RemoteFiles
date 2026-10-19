# Citadel source provenance

Vendored from https://github.com/orlandos-nl/Citadel at exact revision
`ae8562f895de06ccb86fdb1cbb65fd99c8976e12` on 22 September 2026. Upstream MIT license is retained.

`Sources/Citadel/ClientSession.swift` has two narrow additive changes: `SSHClientSettings.onChannelCreated`
is called by the existing NIO channel initializer. This lets RemoteFiles cancel or time out a connection by
closing its actual socket before host-key verification or user authentication completes. The handshake
handler also fails its pending promise on `channelInactive`, so cancellation does not have to wait for
the dependency's hidden ten-second login timer.

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
