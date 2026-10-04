#!/bin/bash
# Runs an independent, loopback-only OpenSSH fixture. Never reads existing SSH keys/config.
set -euo pipefail
umask 077
fixture="$(mktemp -d /private/tmp/remotefiles-openssh.XXXXXX)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM
port="${REMOTEFILES_TEST_PORT:-22222}"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/plain"
ssh-keygen -q -t ed25519 -N 'fixture-passphrase' -f "$fixture/encrypted"
ssh-keygen -q -t ed25519 -a 32 -N 'fixture-passphrase' -f "$fixture/unsupported"
cat "$fixture/plain.pub" "$fixture/encrypted.pub" > "$fixture/authorized_keys"
mkdir -p "$fixture/files/empty" "$fixture/files/thousand" "$fixture/files/docs"
printf '# Fixture report\n\nRead over independent OpenSSH.\n' > "$fixture/files/report.md"
awk 'BEGIN { print "# Representative agent report\n"; for (i=0;i<1600;i++) print "- Measurement " i ": the remote preview reads Markdown, keeps useful cached content, and refreshes on demand." }' > "$fixture/files/large-report.md"
printf 'hello\n' > "$fixture/files/Unicode café.txt"
printf 'hidden\n' > "$fixture/files/.hidden"
: > "$fixture/files/empty.txt"
printf 'restricted\n' > "$fixture/files/permission-denied.txt"
chmod 000 "$fixture/files/permission-denied.txt"
printf '\377\376\000' > "$fixture/files/binary.bin"
dd if=/dev/zero of="$fixture/files/oversized.txt" bs=1048576 count=3 2>/dev/null
ln -s report.md "$fixture/files/report-link.md"
printf '# Linked source\n' > "$fixture/files/docs/source.md"
printf 'outside fixture connection root\n' > "$fixture/outside.md"
ln -s "$fixture/outside.md" "$fixture/files/docs/escape.md"
ln -s "$fixture/outside.md" "$fixture/files/outside-export.txt"
ln -s "$fixture/files" "$fixture/root-alias"
printf 'é 東京\r\n\ttrailing spaces  \r\n' > "$fixture/files/original.txt"
for ((i=0; i<1000; i++)); do : > "$fixture/files/thousand/entry-$i.txt"; done
cat > "$fixture/sshd_config" <<CONFIG
Port $port
ListenAddress 127.0.0.1
HostKey $fixture/host
PidFile $fixture/sshd.pid
AuthorizedKeysFile $fixture/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
AllowUsers $(id -un)
Subsystem sftp internal-sftp
LogLevel VERBOSE
CONFIG
/usr/sbin/sshd -D -e -f "$fixture/sshd_config" > "$fixture/sshd.log" 2>&1 &
server_pid=$!
for ((i=0; i<30; i++)); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$fixture/sshd.log"
    echo 'OpenSSH fixture could not start; no host settings were changed.' >&2
    exit 1
  fi
  if /usr/bin/nc -z 127.0.0.1 "$port" 2>/dev/null; then break; fi
  sleep 0.1
done
export REMOTEFILES_SFTP_FIXTURE="$fixture"
export REMOTEFILES_SFTP_PORT="$port"
export REMOTEFILES_SFTP_USER="$(id -un)"
# xcodebuild forwards TEST_RUNNER_* into iOS XCTest processes (without prefix).
export TEST_RUNNER_REMOTEFILES_SFTP_FIXTURE="$REMOTEFILES_SFTP_FIXTURE"
export TEST_RUNNER_REMOTEFILES_SFTP_PORT="$REMOTEFILES_SFTP_PORT"
export TEST_RUNNER_REMOTEFILES_SFTP_USER="$REMOTEFILES_SFTP_USER"
if [ "$#" -eq 0 ]; then set -- swift test --filter SFTPIntegrationTests; fi
if "$@"; then
  exit 0
else
  result=$?
  tail -n 60 "$fixture/sshd.log" >&2
  exit "$result"
fi
