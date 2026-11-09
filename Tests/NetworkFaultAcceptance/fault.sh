#!/bin/bash
# Network faults for one fixture port only. Run as root: fault.sh PORT DEV clear|shape DELAY JITTER LOSS RATE|blackhole|restore
set -euo pipefail
PORT=$1; DEV=$2; shift 2
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "bad port" >&2; exit 2; }
unshape() { tc qdisc del dev "$DEV" root 2>/dev/null || true; }
unblock() { nft delete table inet rf_fault 2>/dev/null || true; }
case "$1" in
  clear) unshape; unblock ;;
  shape)
    unshape
    # Band 4 is for the fixture port alone; everything else keeps the usual priority bands.
    tc qdisc add dev "$DEV" root handle 1: prio bands 4 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1
    args="delay $2 $3 loss $4"; [ "$5" != none ] && args="$args rate $5"
    tc qdisc add dev "$DEV" parent 1:4 handle 40: netem $args limit 100000
    tc filter add dev "$DEV" parent 1:0 protocol ip prio 1 u32 match ip sport "$PORT" 0xffff flowid 1:4 ;;
  blackhole)
    unblock
    nft add table inet rf_fault
    nft add chain inet rf_fault input '{ type filter hook input priority -10; }'
    nft add chain inet rf_fault output '{ type filter hook output priority -10; }'
    nft add rule inet rf_fault input tcp dport "$PORT" drop
    nft add rule inet rf_fault output tcp sport "$PORT" drop ;;
  restore) unblock ;;
  *) echo "unknown fault $1" >&2; exit 2 ;;
esac
