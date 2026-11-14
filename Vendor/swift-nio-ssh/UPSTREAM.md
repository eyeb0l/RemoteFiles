# SwiftNIO SSH provenance

Vendored from https://github.com/Wellz26/swift-nio-ssh at pinned revision
`d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c`. Original license and notices are retained.
Only the NIOSSH library target is included; examples, upstream tests and the documentation plugin are omitted. Trailing whitespace is normalized for repository checks.

Local change: custom public keys expose a defaulted `authenticationAlgorithm` distinct from
`publicKeyPrefix`. Client user-authentication payloads and requests use it while the public-key
blob and fingerprint keep their original encoding. This permits RFC 8332 RSA SHA-2 authentication
with `ssh-rsa` public keys. Built-in keys keep their existing algorithm. No host-key negotiation,
legacy RSA verification or algorithm defaults are changed. Regression coverage includes an
independent OpenSSH server with SHA-1 RSA authentication explicitly disabled.

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
