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
both; this is the cost of the server's smaller limit.

### One-channel servers

A server that refuses a second channel while the connection holds only browsing's allows one. A
transfer then borrows browsing's slot rather than sharing its channel: new browsing work waits, outside
its own deadline, while work already under way finishes; browsing's channel closes; the transfer opens
its own. The slot comes back when the transfer's channel has closed, however that happens (completion,
cancellation, deadline or a dropped connection), and browsing work that was waiting goes first. Once a
server has needed this, later transfers on the same connection borrow in turn instead of racing
browsing for the slot. A transfer's cancellation and deadlines therefore stay its own.

Browsing waits for a single download or export to finish. A folder save starts no further files while
browsing is waiting, hands the slot back once the files under way finish, and borrows it again for the
rest, so browsing waits for at most the files in flight (up to 16 small ones, or one large one). While
a transfer holds the slot, a second, simultaneous transfer is still refused, as on any server whose
slots are all in use. Cancelling a transfer while it waits for browsing to finish can close the SSH
connection, as cancelling any transfer before it owns a channel already could.

### Slots the server has not yet freed

OpenSSH frees a session's slot only when that session's process has exited, a moment after its channel
has closed. The connection therefore tracks every channel it opens until it has closed. Where it has
just made room (reclaimed the walk, let a transfer or helper channel close, or replaced a retired
browsing channel), a refusal while one of its channels is still closing, or within a second of one
closing, is asked again briefly (at most five seconds); nothing has been sent on a refused channel. A
transfer refused while the only channels left are retired browsing ones waits for them to close first.

### The Linux search helper

The helper needs a private SFTP channel (holding the search root) and an exec channel beside browsing's,
so three in all. A refusal of either is a question of room, not of what the server can run: the search
lets this attempt's channels close before SFTP search takes over (on a one-channel server the fallback
needs that slot), then frees what it can and tries once more: an earlier search's channels that were
still closing, or the walk's channel. Only when browsing alone left no room is the helper remembered as
unavailable for the connection; a refusal while transfers hold channels falls back for that search only.
With `MaxSessions` 3 the helper runs beside browsing, including straight after a cancelled search; with
2 or 1 it never fits beside browsing, so search uses SFTP after one attempt.

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

## One-channel lending and Linux channel limits: 9 November 2026

A baseline of the unchanged transport against Ubuntu 26.04 (Linux 7.0, OpenSSH 10.2p1, Python 3.14)
with disposable loopback daemons at `MaxSessions` 10, 3, 2 and 1 found two faults beyond the
documented limits. After a cancelled helper search, its channels were still closing when the next
search asked for one; the refusal was remembered, disabling the helper for the connection
(`MaxSessions` 3 and 2). On a one-channel server a first search threw `channelSetupRejected` to the
caller, because the helper's channel was still closing when the SFTP fallback opened browsing's. A
one-channel server could also refuse browsing itself after the SFTP search had opened the walk's
channel first: browsing now takes the walk's slot back.

With the changes above, the [Linux acceptance](../Tests/LinuxSearchAcceptance/README.md) channel-limit
test passed at all four limits on one connection each: the helper ran before and after a cancelled
search at 10 and 3, and at 2 and 1 search fell back once to SFTP with the same results. The seven
existing Linux tests passed at 10 and 3. The opt-in matrix above passed all 37 tests across its seven
configurations, now requiring one-channel OpenSSH and Paramiko to complete the offline save by lending
browsing's channel, and every other server never to lend it. It found one more race, a download
straight after a failed preview on one-channel OpenSSH, now covered by the settle step above. The macOS
OpenSSH suite gained `testOneChannelServerLendsBrowsingToTransfersOnOneConnection` (a search before
browsing; browsing during a 96-file save, which hands the slot back and borrows it again; a download;
the failed-preview race) and `testOneChannelServerCancelledSaveReturnsTheChannel`. While these changes
were developed, the first failed with `channelSetupRejected` at the search, at browsing after it and at
the download after a failed preview; that last step fails three times in three without the settle step. All 508 package tests passed with the OpenSSH fixture (one benchmark skipped as before).

## Network faults: 9 November 2026

[Network fault acceptance](../Tests/NetworkFaultAcceptance/README.md) ran the production adapter from
a Mac against a disposable OpenSSH 10.2p1 daemon on an Ubuntu server, with delay, loss, rate limits
and total outages applied by `tc netem` and `nftables` on the server to the fixture's port alone.
The Mac's direct path was blocked by a per-process firewall, so the client reached the fixture through
an SSH port forward and the faults applied to the fixture's own TCP connection on the server's loopback.
The app's socket therefore saw stalls, not its own retransmissions. All six tests passed on the final
code (and on an earlier run with similar figures):

| Fault | Result |
|---|---|
| 150 ± 30 ms delay, 2% loss on replies | Listing 1.7 s, helper search 1.6 s, 8 MiB download 6.7 s, 48-file save 7.2 s; every byte equal; one connection |
| Outage during a managed download (6 Mbit/s) | Ended at its idle deadline plus close grace (15.8 s with a 10 s test deadline), kept 2.9 MB, resumed from exactly that offset on a new connection |
| 5 s outage during a download | Finished on the same connection, every byte equal |
| Outage while browsing | Timed out at 15.07 s; TCP outlived the outage, so browsing continued on the same connection |
| Outage, then cancelling a folder save | Returned in 7 ms; nothing published; the save then succeeded |
| Outage outlasting a folder save | Failed at 179.4 s (a file's 180 s deadline); drained in 5.0 s; nothing published; the save then succeeded |

A folder save's files use a fixed 180-second deadline rather than a transfer's idle deadline, so a
save stalled by an outage takes three minutes to report failure, against about a minute for a single
download; cancelling it is immediate.

Still unverified: proprietary servers such as Bitvise and NAS-specific configurations, other server
versions, network faults seen by the client's own socket (rather than through a forward), and physical
iPhone cancellation and one-channel behaviour. Missing interpreter/procfs capability still uses the
bounded SFTP fallback. Existing canonical path checks and the portable SFTP atomic-confinement
limitation remain unchanged.
