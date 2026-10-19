#!/bin/bash
# Times round-trip-sensitive SFTP operations through a delaying loopback proxy in front of the
# isolated OpenSSH fixture. Never touches system network settings.
# Usage: scripts/benchmark-latency.sh [rtt-ms (default 40)] [mbit per direction, 0 = unlimited] [runs (default 5)]
set -euo pipefail
rtt="${1:-40}"; mbit="${2:-0}"; runs="${3:-5}"
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${REMOTEFILES_SFTP_FIXTURE:-}" ]; then
  exec "$root/scripts/test-openssh.sh" "$0" "$rtt" "$mbit" "$runs"
fi
proxy_port=$((REMOTEFILES_SFTP_PORT + 1000))
python3 -B "$root/scripts/latency_proxy.py" --listen "$proxy_port" --target "$REMOTEFILES_SFTP_PORT" \
  --rtt-ms "$rtt" --mbit "$mbit" &
proxy=$!
trap 'kill "$proxy" 2>/dev/null || true' EXIT
# Wait for the listening socket: a probe connection would reach sshd unauthenticated and be penalised.
for ((i=0; i<50; i++)); do
  /usr/sbin/lsof -nP -iTCP:"$proxy_port" -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.1
done
cd "$root"
REMOTEFILES_SFTP_PORT="$proxy_port" REMOTEFILES_BENCHMARK=1 REMOTEFILES_BENCHMARK_RUNS="$runs" \
  REMOTEFILES_BENCHMARK_LABEL="rtt=${rtt}ms mbit=${mbit}" \
  swift test --filter LatencyBenchmarkTests 2>&1 | tee /dev/stderr | grep -q "Executed 1 test, with 0 failures"
