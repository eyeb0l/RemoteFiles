# Physical iPhone permissions and lifecycle check

Checked on 23 September 2026 with the signed Release build on an iPhone 17 Pro
(iOS 27.0), the existing Mac OpenSSH server, and a disposable fixture under
`.test-server/remote-images`. The app’s dedicated read-only SFTP key was reused.

## Local Network permission

On Wi-Fi, connecting to the Mac’s LAN address produced the iOS prompt “Allow
‘RemoteFiles’ to find devices on local networks?” with the app’s configured
purpose text. Choosing **Don’t Allow** blocked the connection before host trust.
The folder remained navigable with **Try Again**. The original banner exposed
`NIOPosix.NIOConnectionError error 1`; connection failures from SwiftNIO now
show address/network guidance and the iPhone Settings path for Local Network
access. This is advice, not a claim that every connection failure is caused by
permission denial. [Denied-state screenshot](screenshots/local-network-denied.png).

After enabling RemoteFiles under Settings → Privacy & Security → Local Network,
the app presented the Mac’s host fingerprint and successfully listed the real
SFTP fixture. The temporary LAN connection was removed. Local Network access
was left enabled ([Settings screenshot](screenshots/local-network-restored.png)).
`testLocalNetworkDeniedAndRestored` passed twice: first from
an already denied state (**51.645 s**), then after starting with access allowed
and previously loaded folder entries (**70.366 s**). In the latter state, the
error banner appeared over retained entries rather than an empty-state retry
button. Evidence: `/private/tmp/remotefiles-permission-retry2.xcresult`,
`/private/tmp/remotefiles-permission-regression.xcresult`, and their logs.

## Background and foreground

With the Tailscale connection open, a host-side `netstat` snapshot recorded an
established SSH server socket. Three seconds after the app entered the
background, the corresponding socket was absent. The Mac’s fixture changed
while the app was backgrounded. On activation, the reader fetched and rendered
the changed contents without a manual refresh.
[Foreground screenshot](screenshots/foreground-reconnected.png).

`testBackgroundReconnectsToChangedRealServerDocument` passed in **29.605 s**;
evidence: `/private/tmp/remotefiles-lifecycle-sockets.xcresult`, its log, and
`/private/tmp/remotefiles-lifecycle-{connected,background}-sockets.txt`. The
test uses a host-side fixture updater after `REMOTEFILES_LIFECYCLE_BACKGROUND_READY`
appears in the device test log. An earlier content-only run also passed, but
only the final run captured socket teardown separately.

Locked-device Keychain behavior, encrypted-key unlock/dismissal, and an
interrupted refresh with a clearly stale previous copy still need physical
checks. Core tests cover their storage and cancellation contracts separately.
