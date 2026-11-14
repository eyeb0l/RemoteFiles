# SwiftNIO SSH provenance

Vendored from https://github.com/Wellz26/swift-nio-ssh at pinned revision
`d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c`. Original license and notices are retained.
Only the NIOSSH library target is included; examples, upstream tests and the documentation plugin are omitted. Trailing whitespace is normalized for repository checks.

## Where the pinned revision comes from

Checked 14 November 2026 against the three repositories.

- The pinned revision was committed on 12 September 2026 and first vendored here on 21 October 2026.
  It is a personal fork of https://github.com/Joannis/swift-nio-ssh (branch `citadel2`, kept by
  Citadel's author), which is a fork of https://github.com/apple/swift-nio-ssh.
- It is three commits ahead of `citadel2` at `c997b6b` (16 September 2025): a NIO product dependency
  for Mac Catalyst, and "Don't send a window adjust after a locally-initiated close" with its merge.
- The last commit it shares with Apple's `main` is `b0591e4`, release **0.4.0** (21 April 2022). The
  fork has 78 commits since then. They add custom transport protection, key-exchange and public-key
  types, certificate authentication, username and public-key accessors, and platform support.
- Apple's `main` has 94 commits since 0.4.0 (release 0.15.1 at the time of checking). By patch
  identity, 88 of them have no equivalent in the fork; the newest that has one is #134 (6 February
  2023). So this package does not track Apple's releases, and a fix made there arrives here only if
  someone ports it.

### Apple fixes the fork lacks

| Apple change | What it fixes | Here |
|---|---|---|
| Advisory fix merged 15 July 2026 (`31cdc3c`) | An ECDSA signature scalar wider than the curve wrote out of bounds on the stack, before authentication | Covered by the local scalar validation described below, which predates it |
| #153, July 2023 | Lines a server sends before its version string entered the key-exchange hash | Fixed locally, below |
| #244, July 2026 | Limits on the version banner, preamble and packet sizes | The fork caps the version and preamble at 4,096 bytes and checks packet lengths against the maximum packet size; local hardening is below |
| #238, June 2026 | A bare line feed as the first byte crashed a server | Server role only, and the fork's parser has no such index |
| #245 and #247, July 2026 | Configurable maximum packet size; a limit on client authentication attempts | The fork takes the packet size as a protocol option; the other is server-side |
| #143, April 2023 | A window update sent after a local close | The fork carries its own change of 12 September 2026 |
| #150, June 2023 | Space reserved in a buffer by moving the writer index | Not included; the reserved bytes are written before the buffer is sent, and no effect is known |
| Sendable and strict-concurrency adoption, 2023 to 2025 | Compile-time checking | Not included |

Neither Apple's `main` nor the fork implements strict key exchange, the countermeasure to the
Terrapin attack. `OfferedAlgorithmsTests` pins the offered ciphers to AES-GCM, which the attack does
not reach.

### Checking the local changes

On 14 November 2026, at `50b8aaa`, `Sources/NIOSSH` differed from the fork at the pinned revision in
seven files (91 lines added, 14 removed, ignoring trailing whitespace): `SSHChildChannel.swift`,
`CustomKeys.swift`, `NIOSSHPublicKey.swift`, `NIOSSHSignature.swift`, `SSHMessages.swift`,
`SSHPacketParser.swift` and `UserAuthSignablePayload.swift`. Those are the changes described below,
and nothing else. To repeat the comparison:

```sh
git clone https://github.com/Wellz26/swift-nio-ssh fork && git -C fork checkout d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c
git diff --no-index --ignore-space-at-eol --stat fork/Sources/NIOSSH Vendor/swift-nio-ssh/Sources/NIOSSH
```

The pinned commit exists only in that personal fork. If it disappears, start from `citadel2` at
`c997b6b` and the three commits listed above.

## Local changes

Local change: custom public keys expose a defaulted `authenticationAlgorithm` distinct from
`publicKeyPrefix`. Client user-authentication payloads and requests use it while the public-key
blob and fingerprint keep their original encoding. This permits RFC 8332 RSA SHA-2 authentication
with `ssh-rsa` public keys. Built-in keys keep their existing algorithm. No host-key negotiation,
legacy RSA verification or algorithm defaults are changed. Regression coverage includes an
independent OpenSSH server with SHA-1 RSA authentication explicitly disabled.

The manifest accepts swift-crypto below 6.0.0 where the fork stopped at 4.0.0; Apple's package
widened its own range the same way (#233, #259). No source change was needed for swift-crypto 5.1.1.

Local security hardening validates encrypted packet-length arithmetic before sizing a read,
rejects a peer channel maximum packet size of zero while preserving small nonzero values, and
validates ECDSA signature mpints as canonical positive, nonzero, curve-width-bounded integers
before copying them into fixed-width storage. The package retains a focused local test target for
these untrusted wire-format boundaries.

Local security hardening also bounds what the packet parser buffers. `SSHPacketParser.append`,
and `bufferInboundData` above it, now throw a protocol violation once the bytes left over from
parsing exceed the maximum packet size plus 1,024 bytes. Parsing leaves at most one incomplete
packet, so more than that is data nothing is consuming: upstream kept a packet that failed to
decrypt, retried it on every read and appended each read behind it without limit.
`NIOSSHHandler.channelRead` reports the error as it reports a parsing error. The local test target
covers the bound.

The version parser returns the server's identification string alone. A server may send other
lines before it (RFC 4253, section 4.2), and the string goes into the key-exchange hash; the fork
returned those lines with it, so the host's signature never verified and such a server could not
be reached (`NIOSSHError.invalidExchangeHashSignature`). Apple fixed this in July 2023 (#153), after
the fork diverged. `SFTPDirectoryReadTests.testLinesBeforeTheServersVersionStringDoNotBreakKeyExchange`
covers it.
