# Network fault acceptance

This opt-in suite runs the production Swift adapter against a disposable OpenSSH server while the server
delays, drops, rate-limits or blackholes the fixture's traffic. It lives outside the default test target:
it needs a provisioned Linux host with root for `tc` and `nft`, and missing configuration fails rather
than skips. See [verified behaviour](../../docs/SERVER_COMPATIBILITY.md#network-faults-9-november-2026).

## Fixture

On a disposable or personal Linux host you administer, create a temporary directory with an independent
host key, an authorized-keys file holding a temporary client key, and a `files` tree:

- `big.bin`, 8 MiB of incompressible bytes;
- `tree/folder 0` to `tree/folder 3`, twelve 40–150 KB files each (48 files, within the offline limits);
- `needle.txt` containing `network needle`.

Record `sha256sum` of every file, relative to `files` (`./big.bin`, `./tree/folder 0/file-00.bin`, ...),
in `manifest.sha256`, and copy it, the client key (`client`) and the fixture's public host key
(`host.pub`) to a local directory. Start a separate daemon as your normal user, with absolute paths
(`sshd` re-executes itself per connection, so a relative `-f` path fails every login):

```
ListenAddress <loopback or tailnet address>
Port 22360
HostKey /tmp/FIXTURE/host_ed25519
PidFile /tmp/FIXTURE/sshd.pid
AuthorizedKeysFile /tmp/FIXTURE/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PerSourcePenalties no
Subsystem sftp /usr/lib/openssh/sftp-server
```

`PerSourcePenalties no` stops OpenSSH 9.8+ from penalising the client after the deliberately broken
connections. Never change the host's own `sshd` configuration or authorised keys.

[`fault.sh`](fault.sh) applies faults to that one port only: `shape DELAY JITTER LOSS RATE|none` adds a
`netem` qdisc for replies from the port; `blackhole` drops the port both ways with an `nftables` table of
its own; `restore` removes the drop; `clear` removes both. Copy it to the host and give the test a
command that runs it as root, for example over an already-trusted management connection:

```sh
NETWORK_FAULT_CONTROL="ssh -o BatchMode=yes HOST sudo -n /tmp/FIXTURE/fault.sh 22360 DEV"
```

`DEV` is the interface the fixture's replies leave by: the host's network or tailnet interface when the
Mac connects directly, or `lo` when it connects through an SSH port forward. A forward keeps the faults
real for the fixture's TCP connection, but the app's own socket then talks to the local forwarder and
sees only stalls. Prefer a direct path; a per-process firewall on the Mac must allow the test runner.

## Run

From a fresh snapshot, as for [Linux search acceptance](../LinuxSearchAcceptance/README.md), copy this
suite into the test target and run it:

```sh
cp Tests/NetworkFaultAcceptance/NetworkFaultAcceptanceTests.swift "$snapshot/Tests/RemoteFilesCoreTests/"
NETWORK_FAULT_LOCAL=/private/tmp/KEY_DIRECTORY NETWORK_FAULT_HOST=ADDRESS NETWORK_FAULT_PORT=22360 \
NETWORK_FAULT_USER=USER NETWORK_FAULT_ROOT=/tmp/FIXTURE/files NETWORK_FAULT_CONTROL="..." \
  swift test --package-path "$snapshot" --filter NetworkFaultAcceptanceTests
```

The suite clears all faults before and after each test. It takes about three minutes, one of them for
the outage that outlasts a folder save's idle limit. Afterwards run `fault.sh PORT DEV clear`, stop only the
daemon named by its PID file, and remove the fixture directory and temporary keys.
