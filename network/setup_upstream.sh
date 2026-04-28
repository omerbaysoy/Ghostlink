#!/usr/bin/env bash
# Configure gl-upstream — pentest / NAT egress interface
# Brings up the interface and applies initial identity

set -euo pipefail

IFACE="gl-upstream"

# Bring interface up (MAC already spoofed by gl-identity.service)
ip link set "$IFACE" up 2>/dev/null || true

# DHCP to get an IP on the target network if mode is station
# (monitor mode is set per-operation by the pentest engine)
if dhclient -1 -q "$IFACE" 2>/dev/null; then
    IP=$(ip -4 addr show "$IFACE" | awk '/inet /{print $2}')
    echo "gl-upstream: acquired $IP"
else
    echo "gl-upstream: no DHCP response — interface ready for monitor mode"
fi
