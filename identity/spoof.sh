#!/usr/bin/env bash
# Apply a device profile to an interface: MAC + hostname
# Usage: spoof.sh <interface> <profile_name> <mac>

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$REPO/identity/profiles.sh" ]]; then
    REPO="/opt/ghostlink"
fi
source "$REPO/identity/profiles.sh"

IFACE="${1:?Usage: spoof.sh <interface> <profile> <mac>}"
PROFILE="${2:?}"
MAC="${3:?}"

apply_mac() {
    ip link set dev "$IFACE" down
    ip link set dev "$IFACE" address "$MAC"
    ip link set dev "$IFACE" up
}

apply_hostname() {
    local hostname
    hostname=$(profile_hostname "$PROFILE")
    [[ -z "$hostname" ]] && return 0

    local suffix
    suffix=$(echo "$MAC" | tr -d ':' | tail -c 5)
    local full_host="${hostname}-${suffix}"

    hostnamectl set-hostname "$full_host" 2>/dev/null || \
        echo "$full_host" > /etc/hostname
}

apply_dhcp_class() {
    local vendor
    vendor=$(profile_field "$PROFILE" "dhcp_vendor")
    [[ -z "$vendor" ]] && return 0

    mkdir -p /etc/dhcp
    echo "send vendor-class-identifier \"${vendor}\";" \
        > /etc/dhcp/ghostlink-vendor.conf
}

save_state() {
    local vendor model
    vendor=$(profile_vendor "$PROFILE")
    model=$(profile_model  "$PROFILE")
    mkdir -p /var/lib/ghostlink
    cat > /var/lib/ghostlink/identity.state <<EOF
IFACE=$IFACE
PROFILE=$PROFILE
MAC=$MAC
VENDOR=$vendor
MODEL=$model
APPLIED_AT=$(date -Iseconds)
EOF
}

apply_mac
apply_hostname
apply_dhcp_class
save_state

echo "Spoofed $IFACE → $MAC ($PROFILE)"
