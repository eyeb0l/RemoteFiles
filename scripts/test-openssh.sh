#!/bin/bash
# Runs an independent, loopback-only OpenSSH fixture. Never reads existing SSH keys/config.
set -euo pipefail
umask 077
fixture="$(mktemp -d /private/tmp/remotefiles-openssh.XXXXXX)"
server_pid=""
jump_pid=""
logger_pid=""
cleanup() {
  if [ -n "$jump_pid" ]; then kill "$jump_pid" 2>/dev/null || true; wait "$jump_pid" 2>/dev/null || true; fi
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  # With sshd stopped, ask the timestamping follower to drain the log to its end and exit.
  # It ignores the process-group INT/TERM a timed-out runner sends; bound the wait, then kill it.
  drained=0
  if [ -n "$logger_pid" ]; then
    : > "$fixture/sshd.stop"
    for ((i=0; i<50; i++)); do kill -0 "$logger_pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$logger_pid" 2>/dev/null || true
    if wait "$logger_pid" 2>/dev/null; then drained=1; fi
  fi
  # REMOTEFILES_SSHD_LOG keeps the complete server log as evidence: a client-side
  # transport error alone cannot show whether the server or the client ended a session.
  # If the follower did not finish, keep the complete raw log rather than a partial copy.
  if [ -n "${REMOTEFILES_SSHD_LOG:-}" ]; then
    if [ "$drained" = 1 ]; then cp "$fixture/sshd-timestamped.log" "$REMOTEFILES_SSHD_LOG" 2>/dev/null || true
    elif [ -f "$fixture/sshd.log" ]; then cp "$fixture/sshd.log" "$REMOTEFILES_SSHD_LOG" 2>/dev/null || true; fi
  fi
  if [ -n "${REMOTEFILES_SSHD_LOG:-}" ] && [ -f "$fixture/jump-sshd.log" ]; then cp "$fixture/jump-sshd.log" "${REMOTEFILES_SSHD_LOG%.log}-jump.log" 2>/dev/null || true; fi
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM
port="${REMOTEFILES_TEST_PORT:-22222}"
jump_port="${REMOTEFILES_TEST_JUMP_PORT:-$((port + 1))}"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/jump-host"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/jump-key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/plain"
ssh-keygen -q -t ed25519 -N 'fixture-passphrase' -f "$fixture/encrypted"
ssh-keygen -q -t ed25519 -a 32 -N 'fixture-passphrase' -f "$fixture/unsupported"
cat "$fixture/plain.pub" "$fixture/encrypted.pub" > "$fixture/authorized_keys"
# Runtime-only identities exercise every imported algorithm without checking private fixtures in.
for spec in rsa:2048 ecdsa:256 ecdsa:384 ecdsa:521; do
  kind="${spec%:*}"; bits="${spec#*:}"
  for protection in plain encrypted; do
    passphrase=''; if [ "$protection" = encrypted ]; then passphrase='fixture-passphrase'; fi
    name="$fixture/$kind-$bits-$protection"
    ssh-keygen -q -t "$kind" -b "$bits" -a 4 -N "$passphrase" -f "$name"
    cat "$name.pub" >> "$fixture/authorized_keys"
  done
done
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
PubkeyAcceptedAlgorithms ${REMOTEFILES_TEST_PUBKEY_ALGORITHMS:-ssh-ed25519,rsa-sha2-512,rsa-sha2-256,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521}
UsePAM no
PermitRootLogin no
AllowUsers $(id -un)
Subsystem sftp internal-sftp
LogLevel VERBOSE
CONFIG
# Tests deliberately abandon handshakes (host-key rejection, pre-auth cancellation). OpenSSH 9.8+
# penalises each one and, past 15 s of penalties, drops every new loopback connection, making
# later tests fail on earlier ones. Older sshd versions without the option keep their behaviour.
if /usr/sbin/sshd -t -f "$fixture/sshd_config" -o PerSourcePenalties=no 2>/dev/null; then
  echo 'PerSourcePenalties no' >> "$fixture/sshd_config"
fi
# A second independent server is the bastion. It accepts only its own identity and can forward
# only to loopback fixture listeners; tests prove both host keys and both accounts are checked.
sed -e "s/^Port .*/Port $jump_port/" \
    -e "s|^HostKey .*|HostKey $fixture/jump-host|" \
    -e "s|^PidFile .*|PidFile $fixture/jump.pid|" \
    -e "s|^AuthorizedKeysFile .*|AuthorizedKeysFile $fixture/jump-key.pub|" \
    "$fixture/sshd_config" > "$fixture/jump_config"
printf '\nAllowTcpForwarding local\nPermitOpen 127.0.0.1:*\n' >> "$fixture/jump_config"
TZ= /usr/sbin/sshd -D -e -f "$fixture/jump_config" >> "$fixture/jump-sshd.log" 2>&1 &
jump_pid=$!
for ((i=0; i<30; i++)); do
  if ! kill -0 "$jump_pid" 2>/dev/null; then cat "$fixture/jump-sshd.log"; exit 1; fi
  if /usr/bin/nc -z 127.0.0.1 "$jump_port" 2>/dev/null; then break; fi
  sleep 0.1
done
# Tests read sshd.log directly (including assertions that lines are absent), so sshd writes it
# synchronously. A follower adds read-time timestamps (within 50 ms) to a separate evidence copy.
: > "$fixture/sshd.log"
# internal-sftp formats an ls -l line for every READDIR entry: two directory-service lookups and, with
# TZ unset or naming a zone, a reload of the zoneinfo file by strftime. Under a fresh CI simulator's
# boot load the 1,000-entry folder took over a minute. An empty TZ is UTC with no file to load; local
# listings were 3-5x faster with it, idle and under load. No test asserts the long names.
TZ= /usr/sbin/sshd -D -e -f "$fixture/sshd_config" >> "$fixture/sshd.log" 2>&1 &
server_pid=$!
/usr/bin/perl -MPOSIX=strftime -MTime::HiRes=time,sleep -e '
  $SIG{INT} = $SIG{TERM} = "IGNORE";
  my ($in, $out, $stop) = @ARGV;
  open(my $r, "<", $in) or die "$in: $!"; open(my $w, ">", $out) or die "$out: $!"; select $w; $| = 1;
  while (1) {
    my $stopping = -e $stop;
    while (defined(my $line = <$r>)) {
      # Keep a partial line until sshd finishes writing it, unless the server has stopped.
      if ($line !~ /\n\z/ && !$stopping) { seek($r, -length($line), 1); last }
      my $t = time; printf "%s.%03dZ %s", strftime("%H:%M:%S", gmtime $t), ($t - int $t) * 1000, $line;
    }
    last if $stopping;
    sleep 0.05; seek($r, 0, 1);
  }' "$fixture/sshd.log" "$fixture/sshd-timestamped.log" "$fixture/sshd.stop" &
logger_pid=$!
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
export REMOTEFILES_SFTP_JUMP_PORT="$jump_port"
export REMOTEFILES_SFTP_USER="$(id -un)"
# xcodebuild forwards TEST_RUNNER_* into iOS XCTest processes (without prefix).
export TEST_RUNNER_REMOTEFILES_SFTP_FIXTURE="$REMOTEFILES_SFTP_FIXTURE"
export TEST_RUNNER_REMOTEFILES_SFTP_PORT="$REMOTEFILES_SFTP_PORT"
export TEST_RUNNER_REMOTEFILES_SFTP_JUMP_PORT="$jump_port"
export TEST_RUNNER_REMOTEFILES_SFTP_USER="$REMOTEFILES_SFTP_USER"
if [ "$#" -eq 0 ]; then set -- swift test --filter SFTPIntegrationTests; fi
if "$@"; then
  exit 0
else
  result=$?
  tail -n 60 "$fixture/sshd.log" >&2
  exit "$result"
fi
