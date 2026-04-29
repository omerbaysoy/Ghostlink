#!/usr/bin/env bash
# Apply a device profile to an interface: MAC + hostname
# Usage: spoof.sh <interface> <profile_name> <mac>
#
# Management protection: will not spoof gl-mgmt MAC or change hostname on
# trusted management networks. See [management] in ghostlink.conf.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$REPO/identity/profiles.sh" ]]; then
    REPO="/opt/ghostlink"
fi
source "$REPO/identity/profiles.sh"
source "$REPO/identity/mgmt_guard.sh"

IFACE="${1:?Usage: spoof.sh <interface> <profile> <mac>}"
PROFILE="${2:?}"
MAC="${3:?}"

# Management protection: reject MAC spoof on protected interfaces.
# rotate.sh already checks this, but spoof.sh is also called directly — enforce here too.
if is_protected_iface "$IFACE"; then
    echo "  [identity] BLOCKED: $IFACE is protected — MAC spoof refused" >&2
    exit 1
fi

apply_mac() {
    ip link set dev "$IFACE" down
    ip link set dev "$IFACE" address "$MAC"
    ip link set dev "$IFACE" up
}

apply_hostname() {
    local profile_hostname
    profile_hostname=$(profile_hostname "$PROFILE")
    [[ -z "$profile_hostname" ]] && return 0

    # Management protection: never change hostname if protection is enabled
    # or if connected to a trusted SSID.
    if should_protect_hostname; then
        local cfg_host
        cfg_host=$(mgmt_hostname)
        local current_host
        current_host=$(hostname 2>/dev/null || echo "")
        # If current hostname already matches management hostname, nothing to do
        if [[ "$current_host" == "$cfg_host" ]]; then
            return 0
        fi
        # Otherwise ensure hostname is set to management hostname, not the profile
        hostnamectl set-hostname "$cfg_host" 2>/dev/null || echo "$cfg_host" > /etc/hostname
        echo "  [identity] Hostname protected: kept as $cfg_host (not $profile_hostname)" >&2
        return 0
    fi

    local suffix
    suffix=$(echo "$MAC" | tr -d ':' | tail -c 5)
    local full_host="${profile_hostname}-${suffix}"
    hostnamectl set-hostname "$full_host" 2>/dev/null || echo "$full_host" > /etc/hostname
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

echo "  [identity] Spoofed $IFACE → $MAC ($PROFILE)"
