# Server compatibility

[Documentation](README.md) · [Connections](CONNECTIONS.md) · [SSH transport](SSH_SPIKE.md)

RemoteFiles uses the server's SFTP subsystem and the app's existing SSH algorithm policy. It does not
enable older algorithm collections when a connection fails. A result for one implementation/version
is evidence for that configuration, rather than a guarantee about a NAS vendor or every SSH server.

## Session-channel limits

Browsing normally retains one SFTP channel and searches/prefetch retain another. Downloads and
offline folder saves use an isolated channel so their cancellation, deadlines and bulk reads do not
share the browsing channel. A folder save's files share its one transfer channel.

When a server refuses the walk channel, searches share browsing for the rest of that authenticated
connection. If the walk channel already occupies the last slot when a transfer is refused, the
adapter stops assigning new work to it, lets its current requests and deferred closes drain, closes
it, then attempts the transfer again. Later walks share browsing until reconnect. Servers which
accept the extra channel keep the existing separate-channel behaviour. Only an explicit channel-open
refusal triggers this change; authentication, trust, file permissions and timeouts are not retried as
channel-capacity failures.

Two session channels therefore suffice for browsing plus one isolated transfer even after a search
or prefetch. While sharing, search/listing traffic can delay browsing and a channel failure can affect
both; this is the cost of the server's smaller limit. One-channel servers support browsing and SFTP
search, but can refuse an export, download or offline save while browsing retains that slot. Such a
refusal publishes no partial saved folder and leaves the SSH connection usable. Transfers do not
silently fall back to the browsing channel. Other simultaneous isolated transfers can still exhaust
a server's slots.

## Reproducible checks

[The opt-in launcher](../Tests/ServerCompatibilityAcceptance/README.md) creates only disposable,
loopback-only servers. It exercises the production adapter with generated identities and explicit
host-key trust, and retains source fingerprints and logs. It includes OpenSSH `internal-sftp` with
`MaxSessions` 10, 2 and 1; AsyncSSH 2.24.1; and Paramiko 5.1.0 with the same three channel limits.

It checks listings, short reads, SFTP content-search fallback and budgets, complete offline folder
bytes, symlink refusal, transfer limits, channel reclamation and cancellation. The Python fixtures
have no Linux/procfs helper, so a successful content search must use SFTP and remember that capability
decision. [Linux helper acceptance](../Tests/LinuxSearchAcceptance/README.md) is separate.

The initial 9 November 2026 baseline reproduced offline-save channel refusal on both two-channel
OpenSSH and two-channel Paramiko after browsing and walking. Ordinary ten-channel servers passed.
The earlier connection-opening probes of Paramiko 2.12 required wider algorithms; current Paramiko
5.1.0 negotiates the app's production algorithms. No algorithm was added or weakened for this work.

With the reclamation fix, all 37 selected tests passed without skips across the seven configurations
on macOS 27.2 with the Xcode 27.2 Swift toolchain. Each ordinary configuration ran five methods;
two-channel Paramiko also ran the two gated listing/cancellation methods. These are macOS transport
results. The initial AsyncSSH attempt failed in fixture authentication setup (a `Path` supplied where
AsyncSSH requires an authorised-keys filename string); correcting that fixture argument required no
app or algorithm change.

The OpenSSH version was 10.5p1 (LibreSSL 3.3.6). The ordinary macOS/OpenSSH suite also contains
`testTwoChannelServerReclaimsTheWalkForAnOfflineSave`, which starts a second disposable daemon with
`MaxSessions=2` using the existing fixture's temporary keys/configuration. This keeps the demonstrated
regression covered by the usual CI lane without installing Python server packages or changing its
launcher. There is no new simulator skip; that process-hosting test is compiled only on macOS.
It failed with channel refusal against the original transport and passed with the fix. Eight existing
OpenSSH channel/lifecycle/offline-transfer regressions also passed, as did 51 acceptance-runner checks
and three regressions for the opt-in launcher's fail-closed result inventory. Project generation and
whitespace checks passed. Those initial checks did not include simulator, full UI/VoiceOver or
physical-device acceptance; the later hardware evidence follows.

## Physical iPhone acceptance: 9 November 2026

Three signed Debug XCTest methods passed on the physical iPhone 17 Pro, iOS 27.2 (24B119),
using the unchanged production transport from this compatibility fix in RemoteFilesTestHost:
OpenSSH 10.5p1 with `MaxSessions=2`, Paramiko 5.1.0 with two channels, and AsyncSSH 2.24.1.
There were no failed or skipped methods. USB supplied installation/debugging; each server's relay
recorded one connection from the phone's Tailscale address. Independent temporary host keys were
pinned, and fixture identities lived in the test's in-memory secret store.

Each method checked Unicode browsing, the complete 256 KiB file (including the Python servers'
short replies), a completed walk followed by a 14-file offline snapshot with every byte checked,
one skipped link, two content searches with all 12 expected matches, snapshot escape-link rejection,
and working browsing afterwards on the same authenticated SSH connection. Both limited servers
logged an actual channel refusal. All local test stores, server trees and throwaway keys were removed.
These checks exercise transport and persistence through the production APIs on hardware.

The signed Debug app also built, passed strict signature verification and was installed over the
existing RemoteFiles app without an uninstall or data reset. The first additional Demo UI smoke was
blocked before its method started: the UI runner timed out after 60 seconds while enabling automation
mode while a passcode authorisation prompt was waiting on the phone. After on-device authorisation,
the unchanged `testBrowseReadRefreshAndReturn`
passed in 26.122 seconds, with no failures or skips. It exercised folder browsing, the rendered reader,
Source/Rendered switching, Refresh and Back. No assertion, timeout or app code changed for the retry.
This UI smoke uses Demo; the three production transport/persistence checks above use real servers.

Still unverified: proprietary servers such as Bitvise and NAS-specific configurations, other server
versions, real network loss/latency, physical iPhone cancellation and one-channel behaviour, and a Linux
helper constrained by low channel limits. Missing interpreter/procfs capability still uses the bounded
SFTP fallback. Existing canonical path checks and the portable SFTP atomic-confinement limitation
remain unchanged.
