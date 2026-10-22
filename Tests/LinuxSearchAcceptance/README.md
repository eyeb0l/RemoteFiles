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
