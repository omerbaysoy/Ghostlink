#!/usr/bin/env bash
# Restore real (factory) MAC address on an interface
# Usage: restore.sh <interface>

set -euo pipefail

REAL_MACS="/var/lib/ghostlink/real_macs"
IFACE="${1:?Usage: restore.sh <interface>}"

if [[ ! -f "$REAL_MACS" ]]; then
    echo "Error: $REAL_MACS not found — was the identity system initialised?" >&2
    exit 1
fi

REAL_MAC=$(grep "^${IFACE}=" "$REAL_MACS" | cut -d= -f2)

if [[ -z "$REAL_MAC" ]]; then
    echo "Error: no saved MAC for $IFACE" >&2
    exit 1
fi

ip link set dev "$IFACE" down
ip link set dev "$IFACE" address "$REAL_MAC"
ip link set dev "$IFACE" up

# Clear identity state if it was for this interface
STATE="/var/lib/ghostlink/identity.state"
if [[ -f "$STATE" ]] && grep -q "^IFACE=${IFACE}$" "$STATE"; then
    rm -f "$STATE"
fi

echo "Restored $IFACE → $REAL_MAC (factory)"
