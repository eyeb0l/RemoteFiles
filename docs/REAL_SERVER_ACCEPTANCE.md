# Real Mac server acceptance

On 22 September 2026, the physical iPhone 17 Pro connected from RemoteFiles to
this Mac's existing OpenSSH service, using the Mac's Tailscale address on port 22.
This was the normal app and actual account/filesystem, not Demo or a loopback fixture.

## Setup retained for use

- Saved connection: **My MacBook**, account `iris`, starting directory
  `/Users/iris/Developer/RemoteFiles`, also saved as a favourite.
- Dedicated identity: **RemoteFiles iPhone - MacBook**, generated inside the
  iPhone app. Its private key remains in the phone's device-only Keychain.
- With explicit user approval, the public key was appended to the Mac account's
  `~/.ssh/authorized_keys`, preserving its existing entries. The entry is tagged
  `remotefiles-iphone-macbook` and uses `restrict` plus a forced
  `/usr/libexec/sftp-server -R -d /Users/iris/Developer/RemoteFiles` command.
  This forces read-only SFTP and disables shell/forwarding. The starting directory
  is **not** a filesystem jail: the account's other readable files remain readable.
- To revoke this phone's authorization, remove only the authorized_keys line
  carrying that tag. Deleting the app's saved connection alone does not revoke it.
- Existing Remote Login and Tailscale services were already running; no SSH
  host keys, tailnet policy, router ports, or other authorization entries changed.

## Verified journey

1. Create the dedicated identity through the physical app's UI; read only its
   public key for server authorization.
2. Create and save the real connection through the UI.
3. Compare the displayed Ed25519 host fingerprint with the Mac's independently
   read `/etc/ssh/ssh_host_ed25519_key.pub`, then accept the matching key.
4. Browse the actual project and `Fixtures` directory, and open
   `Live-server-report.md` with its initial revision.
5. Open Source, update that file on the Mac only after the iPhone confirms the
   first read, and Refresh. Assert the new revision in Source and Rendered.
6. Return to the real directory successfully.
7. Relaunch the app, reopen the saved connection, save the project favourite, and
   open the actual `docs/READER_PERFORMANCE.md` report from the Mac. This separate
   test passed in 15.242 seconds at 15:10:15 local time.

The browse/read/changed-file-refresh test **passed**, zero failures, in 38.164
seconds at 15:08:30 local time. This includes UI automation overhead and is not
an SFTP latency measurement. [Initial rendering](screenshots/real-server-initial.png)
and [refreshed rendering](screenshots/real-server-refreshed.png) were exported
from the actual device test. The refreshed rendering was visually inspected.

The endpoint used the Tailscale IP and the Mac's route to the phone was `utun11`.
The device screenshots display 5G. This establishes real SFTP via Tailscale with
cellular status visible, not an independently controlled off-site-network test
or proof of the complete physical acceptance matrix.

## Repeatable checks

`RealServerUITests` are opt-in and skip ordinary test runs. Enable them with
`TEST_RUNNER_REMOTEFILES_REAL_SERVER=1`. The initial journey additionally requires
`TEST_RUNNER_REMOTEFILES_REAL_HOST`, `..._USER`, `..._DIRECTORY`, and
`..._FINGERPRINT`; these are forwarded to the runner without the `TEST_RUNNER_`
prefix. Never pass private keys/passwords through these variables.

Build the signed Release test target with `ENABLE_TESTABILITY=YES` as documented
in [READER_PERFORMANCE.md](READER_PERFORMANCE.md). Run only the intended test with
`xcodebuild test-without-building -only-testing:RemoteFilesUITests/RealServerUITests/TEST_NAME`.
The connection and identity are intentionally retained. The refresh check requires
resetting the dedicated fixture to revision 1, then changing it to revision 2 after
`REMOTEFILES_READY_FOR_SERVER_UPDATE` appears in the test log.

## Cellular and Tailscale evidence

`scripts/test-cellular-tailscale.py` runs one `RealServerUITests` method on a
cabled iPhone and records, on the Mac, which path its SSH traffic took. The cable
carries only the Xcode test session; the app's traffic uses the phone's own network.

Before running, turn the iPhone's Wi-Fi off in Settings (Control Center only
disconnects it for a while), turn off Personal Hotspot, connect the cable and open
Tailscale on the phone. The saved connection must use the Mac's MagicDNS name or
Tailscale IP. Export the `TEST_RUNNER_REMOTEFILES_REAL_*` variables a test needs,
then run:

```sh
/usr/bin/python3 -B scripts/test-cellular-tailscale.py --device DEVICE_UDID \
  --output /private/tmp/remotefiles-cellular-NEW_RUN --build
/usr/bin/python3 -B scripts/test-cellular-tailscale.py --device DEVICE_UDID \
  --output /private/tmp/remotefiles-cellular-NEW_RUN --manual
```

Use Apple's `/usr/bin/python3`: macOS hides the TCP socket table from netstat when
uv or Homebrew Python launches it, and the script stops if it cannot see that table.
The first form defaults to `testSavedConnectionReopensRealProject`; choose another
method with `--test`, and omit `--build` to reuse `DerivedData-device`. `--manual`
skips the device test and samples until you press Return, for checks such as
interrupting the network during a refresh. Record the screen with QuickTime
(New Movie Recording, iPhone as the camera) because iPhone Mirroring needs the
phone's Wi-Fi. If several iOS devices are online in the tailnet, pass `--peer`.

Add `--require-direct` to fail unless every sample taken during the phone's SSH
session uses a direct route to a public address, not a DERP relay. If the route
stays relayed, first run `tailscale ping` from the Mac to another peer and read
the `tailscale status` health warnings. A relay to every peer means the Mac is the
cause, not the carrier.

The script stops before testing if Xcode reaches the phone over the local network
or Tailscale routes to it through a private address, an address inside one of
the Mac's interface networks (such as a shared global IPv6 prefix) or the Mac's
own public address. While it runs, it samples `tailscale status`, established
`netstat` sockets on the SSH port, whether the iPhone is still on USB and the
`sshd` log. `summary.md` passes only when sampling continued to the end, the
phone stayed on USB, the route was never local, an SSH session arrived from the
phone's tailnet address, WireGuard traffic flowed and the device test passed
rather than skipped. A DERP relay route counts as cellular-consistent; it is weaker
evidence than a direct route to a carrier address. Passing establishes the
cellular/Tailscale path for that run, not an off-site trip, movement between cells
or a Wi-Fi/cellular handoff.

On 30 October 2026 the physical iPhone 17 Pro (iOS 27.2) passed this check, with
Wi-Fi off in Settings, 5G connected and the cable attached. The signed Release
build of the commit adding this record ran `testSavedConnectionReopensRealProject`,
which passed in 33.2 seconds. It opened **My MacBook** at `100.125.79.6`, browsed
the real project's `docs` folder and rendered `READER_PERFORMANCE.md`. All 42
samples showed the iPhone on USB and a Tailscale DERP relay route (`lhr`), never
a local one. An SSH session from the phone's tailnet address `100.114.108.88` was
established in 26 samples, and 43,648 WireGuard bytes were exchanged. Because the
route was relayed, this does not show a direct path to a carrier address. Evidence:
`/private/tmp/remotefiles-cellular-run3/` (`summary.md`, `samples.jsonl`,
`sshd.log`, `tests.xcresult`).

Two earlier runs that day didn't count as passes. In the first, the test waited for
`READER_PERFORMANCE.md` before scrolling to it in the lazy folder list. It now
scrolls until the row exists. In both runs, netstat started from a uv-installed
Python showed no TCP sockets, so the phone's SSH session went undetected even
though `sshd` logged it. The script now refuses to run without the TCP table.

Later that day `--require-direct` first failed because of the Mac. Its Tailscale
reported "The MagicSock function ReceiveIPv4 is not running", and it reached every
peer through DERP. After Tailscale restarted (updating to 1.105.140), that warning
cleared. The same test then passed in 33.4 seconds with every check, including
`direct_route`. All 40 samples used one direct WireGuard route to an O2 UK carrier
address, different from the Mac's public address. The phone's SSH session appeared
in 25 samples, and 42,320 WireGuard bytes were exchanged. `tailscale ping` round
trips were about 80–150 ms direct and 75–170 ms relayed. Those are a few samples,
not a latency benchmark. Evidence: `/private/tmp/remotefiles-cellular-direct1/`.

### Still outstanding over cellular

These runs establish the network path for one journey: saved-connection reopen,
folder listing and a rendered report, over both a relayed and a direct route. The
following remain unverified over cellular:

- **Changed-file refresh.** `testRealServerBrowseAndRefresh` needs the Mac fixture
  changed after `REMOTEFILES_READY_FOR_SERVER_UPDATE`. The script doesn't drive that
  update, and this journey hasn't run over a recorded cellular path.
- **Network interruption.** Turn on Airplane Mode or turn off cellular during a
  refresh, a recursive search and a managed download. The previous copy must stay
  clearly labelled as stale, no partial content may be shown as current, and
  navigation must recover afterwards. Record these with `--manual` and a QuickTime
  capture; the script records the path, not the app's state.
- **Wi-Fi/cellular handoff.** Switch networks with a session or reader open, in both
  directions. Tailscale may change route mid-session, so `--require-direct` doesn't
  apply.
- **Off-site use.** Repeat away from home, ideally with the Mac behind a different
  network, and while moving between cells or in weak signal. A cabled run at home
  shows the same packet path but not radio conditions.
- **Background and lock over cellular.** Background teardown and foreground refetch
  passed over Tailscale ([lifecycle evidence](DEVICE_PERMISSIONS_LIFECYCLE.md)) but
  without a recorded cellular path. Background transfers, locking and relaunch
  remain unchecked over cellular.
- **Performance.** No timing compares relayed and direct cellular with Wi-Fi.
  Instruments profiling of the 1,000-entry folder and large report on cellular
  remains outstanding; `tailscale ping` samples aren't a benchmark.
- **Other carriers and networks.** Only O2 UK 5G has been recorded. Carriers that
  block UDP or use harder NAT may only ever relay.

Local evidence:

- `/private/tmp/remotefiles-real-identity2.xcresult`: successful on-phone key generation.
- `/private/tmp/remotefiles-real-journey.xcresult`: successful actual-server journey.
- `/private/tmp/remotefiles-real-reopen.xcresult`: saved-connection reopen and real project report.
- Adjacent `.log` files record the UI steps and assertions.

Denied Local Network access, permission recovery, and actual-network background
teardown/foreground refetch now pass on the physical iPhone; see
[device lifecycle evidence](DEVICE_PERMISSIONS_LIFECYCLE.md).

Still outstanding: forced network interruption/stale rendering, locked/encrypted-key lifecycle, preserved scroll position
for a long folder, full accessibility/selection matrix, and representative large
report/directory performance. Read-only enforcement here is an OpenSSH command
restriction; this UI test deliberately did not attempt remote writes.
