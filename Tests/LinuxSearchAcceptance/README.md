# Linux server search acceptance

This opt-in suite connects the production Swift SFTP adapter to a real Linux
OpenSSH server. It fails if supported searches silently fall back. It lives
outside the default test target because it requires an explicitly provisioned
remote host; it adds no default-suite skips or acceptance exemptions.

## Isolated fixture

Use a disposable Linux host or a separate loopback-only sshd under an existing
unprivileged account. Requirements: Linux 5.14+, Python 3.7+, OpenSSH, and procfs
readable by SFTP. Keep normal process-inspection protections enabled. Do not
change the host's normal sshd configuration or authorized keys.

Generate two temporary client keys named `client` and `restricted` locally, and
an independent host key for the fixture daemon. Its temporary authorized-keys
file contains the first public key normally and the second prefixed with
`command="internal-sftp"`. Use public-key-only authentication, loopback binding,
an unused port, a temporary PID/log file, and an absolute authorized-keys path.
Use the host's normal SFTP subsystem. On Ubuntu with a password-locked cloud
account, enable PAM while leaving password and keyboard-interactive login off.
Copy the fixture's public host key to local `host.pub` through an already-trusted
SSH connection. Never disable host-key checking for the management connection.

Create this synthetic tree under the remote fixture directory (the test root is
its `files` subdirectory):

```python
from pathlib import Path
import sys
fixture = Path(sys.argv[1])
root = fixture / 'files'
(root / 'sub').mkdir(parents=True)
(root / '.hidden').mkdir()
(root / 'large').mkdir()
(root / 'needle-2.txt').write_text('alpha\nNeedle café [x].*\n')
(root / 'needle-10.txt').write_text('No match here\n')
(root / 'sub/source.md').write_text('nested NEEDLE\n')
(root / '.hidden/needle.txt').write_text('hidden needle\n')
(fixture / 'outside.txt').write_text('outside secret needle\n')
(root / 'needle-link.txt').symlink_to(fixture / 'outside.txt')
(root / 'sub/escape').symlink_to(fixture)
(root / 'binary.txt').write_bytes(b'needle\0binary')
for index in range(500):
    (root / 'large' / f'file-{index:04}.txt').write_text('x' * 65500 + 'needle\n')
```

Forward the fixture's loopback port through the trusted management connection:

```sh
ssh -N -T -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o ExitOnForwardFailure=yes -L 127.0.0.1:22347:127.0.0.1:22347 HOST
```

## Run against an isolated source snapshot

Create a fresh snapshot of the committed revision, copy this manual test into
its test target, and run only this suite. Keep the snapshot outside the working
checkout. Substitute the local key directory, remote root, port, and account.

```sh
snapshot=$(mktemp -d /private/tmp/remotefiles-linux-acceptance.XXXXXX)
git archive HEAD | tar -x -C "$snapshot"
cp "$snapshot/Tests/LinuxSearchAcceptance/LinuxServerSearchAcceptanceTests.swift" \
   "$snapshot/Tests/RemoteFilesCoreTests/"
git rev-parse HEAD > "$snapshot/tested-head.txt"
LINUX_SEARCH_LOCAL=/private/tmp/KEY_DIRECTORY \
LINUX_SEARCH_ROOT=/tmp/REMOTE_FIXTURE/files \
LINUX_SEARCH_PORT=22347 LINUX_SEARCH_USER=ubuntu \
  swift test --package-path "$snapshot" --filter LinuxServerSearchAcceptanceTests \
  > "$snapshot/linux-search.log" 2>&1
```

The local key directory also holds temporary trust/metadata stores. Missing
configuration or a connection failure fails the suite. Preserve its log and
source SHA. Stop only the fixture daemon identified by its temporary PID file,
close the tunnel, and remove its synthetic tree and temporary keys afterward.

### Session-channel limits

`LinuxServerChannelLimitAcceptanceTests` runs against a fixture daemon with a low `MaxSessions` and must
be told the limit in `LINUX_SEARCH_MAX_SESSIONS`. Start one daemon per limit from the same configuration
with `MaxSessions` 3, 2 and 1 on further ports, and run only that class against each (the other tests
assume the helper fits beside browsing, which needs three). With room for the helper it must run before
and after a cancelled search; without, search must fall back once to SFTP with the same results. Every
limit must keep one authenticated connection.

```sh
LINUX_SEARCH_MAX_SESSIONS=2 LINUX_SEARCH_PORT=22349 ... \
  swift test --package-path "$snapshot" --filter LinuxServerChannelLimitAcceptanceTests
```

### A disposable guest on a Mac

Without a Linux host, a QEMU guest on Apple silicon works and needs no shared daemon. Verify the
image against Ubuntu's `SHA256SUMS`, give it a NoCloud seed that authorizes a management key, and
forward only to loopback:

```sh
hdiutil makehybrid -o seed.iso -iso -joliet -default-volume-name cidata seed   # meta-data, user-data
qemu-img create -f qcow2 -F qcow2 -b ubuntu-24.04-minimal-cloudimg-arm64.img disk.qcow2 16G
qemu-system-aarch64 -M virt -accel hvf -cpu host -smp 4 -m 2048 \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -drive if=pflash,format=raw,file=vars.fd -drive if=virtio,format=qcow2,file=disk.qcow2 \
  -drive if=virtio,format=raw,readonly=on,file=seed.iso \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:22400-:22,hostfwd=tcp:127.0.0.1:22401-:22401 \
  -device virtio-net-pci,netdev=n0 -display none
```

Then start the fixture daemon on 22401 inside the guest as above; no tunnel is needed. A second
drive with `throttling.iops-total=150` models a slow disk for cold-cache timings.

## Recorded validation: 2026-11-09

Ubuntu 26.04.1, Linux `7.0.0-42-generic`, OpenSSH `10.2p1`, Python `3.14`, with loopback daemons at
`MaxSessions` 10, 3, 2 and 1 reached through one SSH forward. Before the channel-limit changes, the
cancellation test failed at 3 (the search after the cancelled one found the helper disabled for the
connection), and at 1 a search threw `channelSetupRejected`. After them the channel-limit test passed at
all four limits, using the helper twice at 10 and 3 and SFTP after one attempt at 2 and 1, with one
connection each; the seven tests above passed at 10 and 3. At 2 and 1 those of the seven that search
after browsing fail by design: the helper never fits beside browsing there. See [server compatibility](../../docs/SERVER_COMPATIBILITY.md#the-linux-search-helper).

## Recorded validation: 2026-11-07

Seven tests passed with no failures or skips on such a guest: Ubuntu 24.04.5, Linux
`6.8.0-147-generic`, OpenSSH `9.6p1`, Python `3.12.3`. Besides the five below, results arrive before
the search finishes (200 content matches, none twice, zero SFTP reads; they share a folder, so they
arrive together, before the final line), and the match
limit ends the helper with browsing and a further server search still working. The production-adapter
tests also passed with `Subsystem sftp internal-sftp`. This was after the helper's setup became four
pipelined round trips and its output a line per batch.

## Recorded validation: 2026-10-22

Five tests passed with no failures or skips on Ubuntu, Linux
`7.0.0-1013-oracle`, OpenSSH `10.2p1`, and Python `3.14.4`, using a separate
loopback-only daemon accessed through SSH forwarding:

- Production adapter: three completed server searches, zero SFTP file reads,
  one reused SSH connection; names, literal contents, Unicode snippets and
  hidden-file policy checked.
- Forced SFTP-only key: one failed capability attempt, zero completed server
  searches, two SFTP reads across repeated searches, one reused connection.
- Server file/time limits and exclusion of symlink escape contents.
- Cancellation followed by successful browsing and another server search.
- Incorrect inode, mount ID, mount namespace and root substitution rejected
  with zero folders/files/bytes/candidates read.

The initial run caught OpenSSH REALPATH accepting a missing descriptor's final
component, and normal OpenSSH denying cross-process procfs inspection. The
adapter now requires live READLINK descriptors and compares kernel identities
obtained by each process from its own procfs entries while SFTP pins the root.
No process-inspection protections were relaxed. This is transport/helper
acceptance, not physical-device or interactive UI validation.
