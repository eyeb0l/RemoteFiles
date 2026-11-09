# Real-server compatibility acceptance

This opt-in suite runs the production Swift adapter against independent SFTP implementations and
OpenSSH/Paramiko servers restricted to one or two session channels. It is outside the default test
target: a missing external server dependency fails setup rather than adding an allowed skip to CI.
See [verified behaviour and limitations](../../docs/SERVER_COMPATIBILITY.md).

On macOS, from the repository root:

```sh
uv run --no-project --python 3.14 --with asyncssh==2.24.1 --with paramiko==5.1.0 \
  python -B scripts/test-server-compatibility.py \
  --output /private/tmp/remotefiles-server-compatibility-NEW
```

Use a fresh output directory outside the checkout. `--scenarios openssh-2 paramiko-2` selects a
focused subset. Xcode's Swift toolchain, `/usr/sbin/sshd`, `ssh-keygen` and an unprivileged local
account are required. Root is deliberately not permitted by the OpenSSH fixture. No sudo is used.

The launcher copies the current Sources, Vendor and package manifests to an isolated source snapshot,
copies only this acceptance suite into its test target, and uses the resolved package versions.
It builds once and executes the same test binary sequentially against each server. A failed build
stops the matrix; a failed scenario does not prevent collecting evidence from the remaining servers.
The report records source hashes, the checkout commit/diff, fixture versions and scenario exit codes.
It retains each server log and the complete Swift build/test logs. The original checkout and its
dependency locks are not changed.

Every listener binds to `127.0.0.1` on an ephemeral port. Independent host/client keys and public-key
only authentication are generated for each scenario. Swift pins that host key through HostTrustStore;
the fixtures do not use the person's SSH keys, agent, configuration or authorised-keys file. OpenSSH
uses `internal-sftp -R`; the Python servers expose read-only handlers over their private fixture tree.
Paramiko's channel counter includes pending requests, so concurrent opens cannot exceed the limit.
The launcher stops its child listeners and removes their trees, temporary stores and keys on exit.

## Container stand-ins on a remote host

`--docker-host HOST --docker-address ADDRESS` runs instead independent SFTP servers in containers on a
Linux host you administer, reached for management with `ssh HOST` (already-trusted host key, `sudo -n
docker`) and published only on `ADDRESS`, such as the host's tailnet address, on ports 22364–22369. The
Mac must be allowed to reach that address directly. Image definitions are in [`docker/`](docker); the
launcher copies them and each scenario's fixture to a private `mktemp` directory on the host, builds the
images, records their IDs and server versions in the report, and removes containers and copies afterwards.
Containers are named `remotefiles-compat-*`; nothing else on the host is touched.

```sh
uv run --no-project --python 3.14 --with asyncssh==2.24.1 --with paramiko==5.1.0 \
  python -B scripts/test-server-compatibility.py --docker-host HOST --docker-address ADDRESS \
  --output /private/tmp/remotefiles-nas-standins-NEW
```

| Scenario | Server | Stands in for |
|---|---|---|
| `openssh82-chroot`, `openssh82-chroot-1` | OpenSSH 8.2p1, `ChrootDirectory` + `ForceCommand internal-sftp -R`, `MaxSessions` 10 or 1 | NAS firmware's chrooted SFTP-only accounts on an older OpenSSH |
| `proftpd-10` | ProFTPD 1.3.8 `mod_sftp`, `DefaultRoot` | An SSH stack independent of OpenSSH, used by hosting and some appliances |
| `sftpgo-default` | SFTPGo 2.6.6, virtual root `/`, list/download only | A Go SSH stack with a virtual file system, offered in NAS app catalogues |
| `proftpd-1`, `dropbear-default` | ProFTPD with `SFTPMaxChannels 1`; Dropbear 2024.85 with OpenSSH's `sftp-server` | Known incompatibilities, run only when named; see [server compatibility](../../docs/SERVER_COMPATIBILITY.md#nas-stand-ins-9-november-2026) |

These are stand-ins: real vendor firmware, its patches and its configuration can still differ.

All scenarios require:

- Unicode listings, reused browsing/walk channels, exact large-file bytes with pipelined reads.
- Repeated content searches using bounded SFTP fallback, remembered helper unavailability, no
  symlink-content reads, and the file-count limit.
- An offline folder saved after browsing and walking: all original bytes and the skipped link. A
  one-channel server must lend browsing's channel to the save; other servers must never lend it.
- Snapshot symlink rejection, preview/transfer byte limits (a download straight after a failed
  preview, on every server), and continued browsing.

AsyncSSH caps replies at 1 KiB and Paramiko at 4 KiB to exercise real short-read handling.
Against `paramiko-2`, two additional tests gate an actual READDIR with files outside the saved tree.
They verify foreground browsing while reclamation waits, successful transfer only after the walk
drains, and cancellation/drain without publishing. Gate polling synchronises the fixture; no ordering
or overlap assertion depends on an elapsed sleep. Cancellation before a transfer owns a channel may
close SSH, as for ordinary channel opening; the next foreground operation must reconnect successfully.

This is macOS transport acceptance, not physical-iPhone, Linux-helper, field-network or proprietary
server evidence. The earlier Linux helper suite remains under [LinuxSearchAcceptance](../LinuxSearchAcceptance/README.md).
