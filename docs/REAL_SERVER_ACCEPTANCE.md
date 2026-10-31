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

## 31 October 2026 iPhone session

A hands-on session on the physical iPhone 17 Pro (iOS 27.2) against **My MacBook**
over Tailscale. Builds were signed Release with `ENABLE_TESTABILITY=YES` from
[PR #46](https://github.com/eyeb0l/RemoteFiles/pull/46): `aa1daa9` for the
automated run and the first PDF check, then `844dced`, which fixed the rotation
drift that check found, for everything else. Until the network recordings, the
phone used Wi-Fi and the route was not recorded. All fixtures were synthetic files
added to `Fixtures/` for the session and removed afterwards; the phone's own key
was not exported.

### Automated

The demo `RemoteFilesUITests` class passed 28 of 29 methods in about 20 minutes,
including both PDF search journeys. `testImportRSAAndECDSAKeysShowsTheirAlgorithmsAndPublicKeys`
failed twice: the app rejected the RSA key the test generates and pastes as
malformed, so the ECDSA case never ran. Importing a real encrypted RSA file through
the UI worked, so the failure is specific to the test's generated key or paste path.
Evidence on the Mac mini: `/private/tmp/remotefiles-pdfnav-device-ui1.xcresult` and
`/private/tmp/remotefiles-pdfnav-device-key2.xcresult`.

### Passed by hand

- **PDF navigation** ([step 13](MANUAL_ACCEPTANCE.md)): a 12-page PDF with a phrase
  only on page 9. Live and saved-index results opened at page 9. A mid-page position
  returned after Back, relaunch and rotation, the last after the `844dced` fix. After
  the file was replaced on the server, Refresh opened revision 2 at the top, and a
  stale saved-index result still opened the current file at page 9.
- **Managed downloads:** three 120 MiB random files. Transfers continued in the
  background; a queued item did not start while backgrounded or locked, and started
  after unlocking. System cancellation, lock, force quit and Disconnect each exposed
  Retry, and retries started from zero. A completed download saved to iCloud Drive
  matched the server's SHA-256. Resource expiration could not be forced.
- **Save Original:** the PDF saved from the reader matched the server's SHA-256, and
  cancelling the picker kept the reader usable.
- **Offline file** (step 9): opened in Airplane Mode after Disconnect and relaunch;
  Share Original matched revision 1 byte-for-byte; Update Offline Copy fetched
  revision 2; an update interrupted by Airplane Mode kept the old copy and saved
  time; removing the copy left the server file unchanged. The offline reader has no
  Find or Headings controls.
- **Offline folder** (step 10): nested and empty folders saved with hidden files
  excluded and two symbolic links counted; browsing, sharing and relaunch worked in
  Airplane Mode. An update picked up an added, a deleted and an edited file. With a
  member made unreadable, the update failed and the previous snapshot stayed complete.
  An 18-level folder failed at the 16-level limit with nothing published.
- **Offline links** (step 11): sibling, nested, parent and heading links, and Back
  position, worked in Airplane Mode. Missing, hidden, symbolic-link, unsupported,
  query and outside-folder links each explained the failure and kept the reader.
- **Keys** (step 4, in part): encrypted RSA 3072 and Ed25519 files imported with the
  expected fingerprints, and exports matched the originals byte-for-byte. Cancelling
  authentication and the Files picker saved nothing. Both identities survived locking.
  A connection using the encrypted key prompted for the passphrase, a swipe-dismiss
  connected nothing, and after relaunch it prompted again. These keys were disposable
  and never authorized; the server rejected them as expected.
- **Appearance and accessibility** (step 6): selection and copy in Rendered and
  Source, horizontally panned code blocks and tables, light/dark, the largest
  accessibility text size, Reduce Motion, Reduce Transparency, VoiceOver continuous
  reading, the Headings rotor, focus returning to the opened row, and the PDF's page
  announcement.

### Network recordings

Both used `scripts/test-cellular-tailscale.py --manual` on the MacBook, with the
phone cabled to it and Wi-Fi off in Settings. Evidence on the MacBook:
`/private/tmp/remotefiles-net-run1/` and `/private/tmp/remotefiles-net-run2/`.

- **Interruption, 19:14–19:28, PASS.** 744 samples, all wired, with a direct route to
  an O2 UK carrier address (briefly relayed), never local, and 146 MB of WireGuard
  traffic. A refresh interrupted by Airplane Mode showed an error banner within
  seconds and kept the previous copy; the next refresh worked. Two transfers did not
  fail promptly, as described below.
- **Handoff, 19:28–19:35.** 333 samples, all wired. The route moved from the carrier
  to the home LAN when Wi-Fi joined at 19:29:51, and back through a London relay to
  the carrier at 19:31:37–38. A managed download in progress across each switch
  stalled for a few seconds and then completed; browsing worked after each. The
  summary's `path_never_local` failure is the intended Wi-Fi leg. Tailscale keeps the
  tunnel address, so this does not show a non-Tailscale handoff.

### Found

- **A dead network isn't noticed during transfers.** In Airplane Mode a managed
  download stopped moving at 19:16:54, and the Mac dropped its socket at 19:17:34,
  but the app showed no failure until the network returned at 19:19, despite the
  documented 60-second inactivity limit. An offline-copy update in the same state
  showed nothing, and its Cancel took effect only after about 3 minutes (the
  180-second limit), again without an explanation.
- **Linked offline readers exhaust preview leases.** Following links back and forth
  in a saved folder eventually showed "Close another offline preview before opening
  this file." Returning to Offline Files cleared it. Each stacked reader keeps one of
  the four leases.
- **RSA paste in the device UI test**, as above.

### Still outstanding over cellular

These runs establish the network path for one journey: saved-connection reopen,
folder listing and a rendered report, over both a relayed and a direct route. The
following remain unverified over cellular:

- **Changed-file refresh.** `testRealServerBrowseAndRefresh` needs the Mac fixture
  changed after `REMOTEFILES_READY_FOR_SERVER_UPDATE`. The script doesn't drive that
  update, and this journey hasn't run over a recorded cellular path.
- **Network interruption.** A refresh and a managed download were interrupted on
  [31 October](#31-october-2026-iphone-session); the refresh passed, but transfers
  don't notice the dead network promptly. A recursive search remains unchecked.
- **Wi-Fi/cellular handoff.** Passed in both directions over Tailscale with a
  download in progress on [31 October](#31-october-2026-iphone-session). A reader
  left open across the switch, and handoff without Tailscale, remain unchecked.
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

Still outstanding: preserved scroll position for a long folder, a recursive search
during network loss, and representative large report/directory performance. Stale
rendering after an interrupted refresh, the encrypted-key lifecycle and the
accessibility/selection matrix passed on [31 October](#31-october-2026-iphone-session). Read-only enforcement here is an OpenSSH command
restriction; this UI test deliberately did not attempt remote writes.
