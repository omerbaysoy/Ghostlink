#!/usr/bin/env bash
# Classifies wireless interfaces by capability and writes udev .link rules.
# Works on RPi (brcmfmac onboard) and generic Linux (any non-USB = onboard).
# Usage: classify.sh [--write-udev] [--map-only]

set -euo pipefail

WRITE_UDEV=false
MAP_ONLY=false
for arg in "$@"; do
    [[ "$arg" == "--write-udev" ]] && WRITE_UDEV=true
    [[ "$arg" == "--map-only"   ]] && MAP_ONLY=true
done

UDEV_DIR="/etc/systemd/network"
MAP_FILE="/var/lib/ghostlink/interfaces.map"

declare -A iface_monitor
declare -A iface_ap
declare -A iface_mac
declare -a onboard_ifaces=()
declare -a usb_ifaces=()

is_usb_iface() {
    readlink -f /sys/class/net/"$1"/device 2>/dev/null | grep -q "/usb[0-9]"
}

collect_interfaces() {
    local ifaces
    mapfile -t ifaces < <(iw dev 2>/dev/null | awk '/Interface/{print $2}')

    for iface in "${ifaces[@]}"; do
        local mac phy
        mac=$(cat /sys/class/net/"$iface"/address 2>/dev/null) || continue
        phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}') || continue

        iface_mac["$iface"]="$mac"

        local phy_info
        phy_info=$(iw phy "$phy" info 2>/dev/null)
        echo "$phy_info" | grep -q "monitor"   && iface_monitor["$iface"]=1 || iface_monitor["$iface"]=0
        echo "$phy_info" | grep -qE " AP$| AP " && iface_ap["$iface"]=1     || iface_ap["$iface"]=0

        # Onboard = not USB (PCIe, SDIO, M.2 — works for RPi BCM and laptop Intel/Realtek)
        if is_usb_iface "$iface"; then
            usb_ifaces+=("$iface")
        else
            onboard_ifaces+=("$iface")
        fi
    done
}

write_link_rule() {
    local alias="$1" mac="$2"
    mkdir -p "$UDEV_DIR"
    cat > "$UDEV_DIR/10-${alias}.link" <<EOF
[Match]
MACAddress=${mac}

[Link]
Name=${alias}
EOF
    echo "  Wrote: $UDEV_DIR/10-${alias}.link  ($alias → $mac)"
}

assign_roles() {
    local upstream_iface="" hotspot_iface="" mgmt_iface=""

    # gl-mgmt: onboard (non-USB) WiFi — works for RPi BCM43455 and laptop Intel/Realtek
    if [[ ${#onboard_ifaces[@]} -gt 0 ]]; then
        mgmt_iface="${onboard_ifaces[0]}"
    fi

    # gl-upstream: USB adapter with monitor mode capability
    for iface in "${usb_ifaces[@]}"; do
        if [[ "${iface_monitor[$iface]:-0}" -eq 1 ]] && [[ -z "$upstream_iface" ]]; then
            upstream_iface="$iface"
        fi
    done

    # gl-hotspot: second USB adapter with AP mode capability
    for iface in "${usb_ifaces[@]}"; do
        [[ "$iface" == "$upstream_iface" ]] && continue
        if [[ "${iface_ap[$iface]:-0}" -eq 1 ]] && [[ -z "$hotspot_iface" ]]; then
            hotspot_iface="$iface"
        fi
    done

    # Fallback: if no AP-capable second adapter, use any remaining USB
    if [[ -z "$hotspot_iface" ]]; then
        for iface in "${usb_ifaces[@]}"; do
            [[ "$iface" == "$upstream_iface" ]] && continue
            hotspot_iface="$iface"
            break
        done
    fi

    # Fallback: if no USB adapters at all (e.g., Kali on laptop),
    # onboard can serve as upstream; mgmt uses ethernet
    if [[ -z "$upstream_iface" ]] && [[ ${#onboard_ifaces[@]} -gt 0 ]]; then
        upstream_iface="${onboard_ifaces[0]}"
        mgmt_iface=""   # Will use ethernet/SSH on existing interface
    fi

    echo ""
    echo "  Interface assignment:"
    printf "  %-14s → %-12s %s\n" "gl-mgmt"    "${mgmt_iface:-NONE}"     "(${iface_mac[$mgmt_iface]:-N/A})"
    printf "  %-14s → %-12s %s\n" "gl-upstream" "${upstream_iface:-NONE}" "(${iface_mac[$upstream_iface]:-N/A})"
    printf "  %-14s → %-12s %s\n" "gl-hotspot"  "${hotspot_iface:-NONE}"  "(${iface_mac[$hotspot_iface]:-N/A})"
    echo ""

    # Save map
    mkdir -p "$(dirname "$MAP_FILE")"
    {
        echo "gl-mgmt=${mgmt_iface:-}"
        echo "gl-upstream=${upstream_iface:-}"
        echo "gl-hotspot=${hotspot_iface:-}"
    } > "$MAP_FILE"

    if $WRITE_UDEV; then
        [[ -n "$mgmt_iface"     ]] && write_link_rule gl-mgmt     "${iface_mac[$mgmt_iface]}"
        [[ -n "$upstream_iface" ]] && write_link_rule gl-upstream  "${iface_mac[$upstream_iface]}"
        [[ -n "$hotspot_iface"  ]] && write_link_rule gl-hotspot   "${iface_mac[$hotspot_iface]}"
    fi
}

collect_interfaces
assign_roles
