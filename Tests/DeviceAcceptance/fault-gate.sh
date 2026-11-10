#!/bin/bash
# Forced command for the device's fault-control key. Install as
#   command="/path/fault-gate.sh FIXTURE_PORT ONE_CHANNEL_PORT DEV",restrict ssh-ed25519 ...
# beside ../NetworkFaultAcceptance/fault.sh. Allows only these fault actions, on those two ports, on DEV.
set -euo pipefail
fixture=$1; one_channel=$2; dev=$3
read -r port action a b c d extra <<< "${SSH_ORIGINAL_COMMAND:-}"
[[ -z "${extra:-}" ]] || { echo "denied" >&2; exit 2; }
[[ "$port" == "$fixture" || "$port" == "$one_channel" ]] || { echo "denied port" >&2; exit 2; }
case "$action" in
  shape)
    [[ "$a" =~ ^[0-9]+ms$ && "$b" =~ ^[0-9]+ms$ && "$c" =~ ^[0-9]+%$ && ( "$d" =~ ^[0-9]+mbit$ || "$d" == none ) ]] || { echo "denied shape" >&2; exit 2; }
    exec sudo -n "$(dirname "$0")/fault.sh" "$port" "$dev" shape "$a" "$b" "$c" "$d" ;;
  blackhole|restore|clear)
    [[ -z "${a:-}" ]] || { echo "denied" >&2; exit 2; }
    exec sudo -n "$(dirname "$0")/fault.sh" "$port" "$dev" "$action" ;;
  *) echo "denied action" >&2; exit 2 ;;
esac
