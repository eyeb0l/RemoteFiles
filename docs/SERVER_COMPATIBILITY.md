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
rest, so browsing waits for at most the files in flight (up to 16 small ones, or one large one). A file
waiting for the slot to come back is queued, not stalled: neither its transfer's idle deadline nor the
save's minute without bytes starts until it has the slot. While
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
a Mac against a disposable OpenSSH 10.2p1 daemon on an Ubuntu server, directly over a tailnet, with
delay, loss, rate limits and total outages applied by `tc netem` and `nftables` on the server's tailnet
interface to the fixture's port alone; the server logged the Mac's own address. All six tests passed on
the final code:

| Fault | Result |
|---|---|
| 150 ± 30 ms delay, 2% loss on replies | Listing 1.6 s, helper search 1.6 s, 8 MiB download 135 s, 48-file save 75 s; every byte equal; one connection |
| Outage during a managed download (6 Mbit/s) | Ended at its idle deadline plus close grace (15.2 s with a 10 s test deadline), kept 3.5 MB, resumed from exactly that offset on a new connection |
| 5 s outage during a download | Finished on the same connection, every byte equal |
| Outage while browsing | Timed out at 15.1 s; TCP outlived the outage, so browsing continued on the same connection |
| Outage, then cancelling a folder save | Returned in 5 ms; nothing published; the save then succeeded |
| Outage outlasting a folder save | Failed at 59.6 s (a file's 60 s idle limit; 179.4 s before that change); drained in 4.8 s; nothing published; the save then succeeded |

The lossy transfers are slow because of TCP, not the app: with a 150 ms round trip, 2% loss and the
tailnet's 1,280-byte packets, TCP's loss-limited rate is about 70 KB/s, which predicts roughly two
minutes for 8 MiB. Earlier runs, before a per-process firewall on the Mac allowed the test runner,
reached the fixture through an SSH port forward with the faults on the server's loopback, where loss
is recovered almost at once (the same download took 5–7 s); every other result matched.

A folder save's files then had a fixed 180-second deadline rather than a transfer's idle deadline, so a
save stalled by an outage took three minutes to report failure, against about a minute for a single
download. A folder save's file now fails after 60 seconds without receiving bytes, in the transport and in
its exporter; `testStalledFolderSaveFailsAtTheIdleLimit` covers it in the macOS OpenSSH suite, and fails
against the fixed deadline. Single-file offline saves and exports keep the 180-second total.

## Physical iPhone, channels and faults: 9 November 2026

[Device acceptance](../Tests/DeviceAcceptance/README.md) ran on the iPhone 17 Pro (iOS 27.2) in a signed
Debug `RemoteFilesTests` build of the committed code, against OpenSSH 10.2p1 daemons on an Ubuntu server
reached over the phone's own tailnet connection; the server logged the phone's address. Faults were
applied on the server to the fixture port alone, by the phone itself through a control key whose forced
command allows only those actions. All three tests passed, twice (figures from the second run):

| Test | Result |
|---|---|
| Cancellation | A rate-limited download 0.9 s, a folder save 5 ms and a helper content search under 1 ms after cancelling; nothing published; browsing and a helper search then worked on the same connection |
| Outages on the phone's socket | A download ended 15.1 s into an outage (10 s test idle limit plus the 5 s close grace), resumed from the 2.4 MB kept with every byte equal; a 5 s outage was ridden out; cancelling during an outage returned after 5.06 s (the close grace); browsing then reconnected |
| One-channel server | Search before browsing fell back to SFTP; browsing during a 48-file save waited 0.76 s while the save handed back the channel; four loans; every byte equal; a download borrowed the channel; cancelling a borrowing save returned in 7 ms and published nothing; one connection |

## NAS stand-ins: 9 November 2026

No proprietary NAS was available, so the opt-in launcher's [container mode](../Tests/ServerCompatibilityAcceptance/README.md#container-stand-ins-on-a-remote-host)
ran the same five compatibility tests from a Mac, directly over a tailnet, against independent SFTP servers
in containers on an Ubuntu host: NAS-style chrooted OpenSSH, ProFTPD's `mod_sftp` and SFTPGo, chosen for
their separate SSH stacks or for the configurations NAS firmware ships. They are stand-ins, not vendor
evidence.

| Scenario | Result |
|---|---|
| OpenSSH 8.2p1, chroot, `ForceCommand internal-sftp -R` | All five passed; the Linux helper fell back to SFTP after one attempt |
| The same with `MaxSessions 1` | All five passed, lending browsing's channel to the offline save (the server logged its refusals) |
| ProFTPD 1.3.8 `mod_sftp`, `DefaultRoot`, default channels | All five passed |
| SFTPGo 2.6.6, virtual root `/` | All five passed |
| ProFTPD with `SFTPMaxChannels 1` | Incompatible: see below |
| Dropbear 2024.85 with OpenSSH's `sftp-server` | Incompatible: see below |

Findings:

- **Dropbear cannot connect.** This Dropbear build (Alpine 3.20's 2024.85) offers only
  `chacha20-poly1305@openssh.com`, `aes128-ctr` and `aes256-ctr`, while AES-GCM is the only cipher family
  the app's SSH stack (swift-nio-ssh) implements. Every connection ends in key exchange (the server logs
  `No matching algo enc c->s`). The app now says it has no encryption method in common with the server and
  names AES-GCM, instead of a generic error; `testServerWithoutAESGCMReportsNoCommonEncryption` covers it
  with OpenSSH offering Dropbear's ciphers. Routers and small embedded storage often run Dropbear.
  Supporting it would need ChaCha20-Poly1305 in the vendored SSH stack; no algorithm was added or weakened.
- **ProFTPD drops the session when its channel limit is reached.** With `SFTPMaxChannels 1` it refuses a
  second channel (with reason "unknown channel type") and then disconnects the whole connection, which an
  independent client (Paramiko) also lost. Any client that opens a second channel loses the session, so the
  app's walk, search helper and transfers each disconnect it. The default limit is 10, where all tests pass.
- **SFTPGo refuses links leaving the user's root** with "permission denied" rather than resolving them; the
  app treats that as the refusal it is and publishes nothing. Its root is `/`, which the tests now handle.
- **Chrooted, SFTP-only accounts block the Linux helper,** whose exec runs `internal-sftp` instead; search
  falls back to SFTP after one attempt, as on other servers without the helper.

Still unverified: proprietary servers such as Bitvise and vendor NAS firmware itself (beyond the
stand-ins above), other server versions, and cellular-only paths or loss rates on the phone (its faults were outages and rate limits
over a tailnet). Missing interpreter/procfs capability still uses the
bounded SFTP fallback. Existing canonical path checks and the portable SFTP atomic-confinement
limitation remain unchanged.
