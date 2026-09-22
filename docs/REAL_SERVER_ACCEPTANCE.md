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

Local evidence:

- `/private/tmp/remotefiles-real-identity2.xcresult`: successful on-phone key generation.
- `/private/tmp/remotefiles-real-journey.xcresult`: successful actual-server journey.
- `/private/tmp/remotefiles-real-reopen.xcresult`: saved-connection reopen and real project report.
- Adjacent `.log` files record the UI steps and assertions.

Still outstanding: forced network interruption/stale rendering, denied Local
Network permission, locked/encrypted-key lifecycle, preserved scroll position
for a long folder, full accessibility/selection matrix, and representative large
report/directory performance. Read-only enforcement here is an OpenSSH command
restriction; this UI test deliberately did not attempt remote writes.
