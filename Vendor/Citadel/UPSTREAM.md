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
