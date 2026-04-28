#!/usr/bin/env bash
# Classifies wireless interfaces by capability and writes udev .link rules.
# Usage: classify.sh [--write-udev]

WRITE_UDEV=false
[[ "${1:-}" == "--write-udev" ]] && WRITE_UDEV=true

UDEV_DIR="/etc/systemd/network"

declare -A iface_monitor
declare -A iface_ap
declare -A iface_mac
declare -a onboard_ifaces
declare -a usb_ifaces

collect_interfaces() {
    for iface in $(iw dev | awk '/Interface/{print $2}'); do
        local mac phy
        mac=$(cat /sys/class/net/"$iface"/address 2>/dev/null) || continue
        phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}') || continue

        iface_mac[$iface]="$mac"

        iw phy "$phy" info 2>/dev/null | grep -q "monitor"  && iface_monitor[$iface]=1 || iface_monitor[$iface]=0
        iw phy "$phy" info 2>/dev/null | grep -q " AP$\| AP " && iface_ap[$iface]=1     || iface_ap[$iface]=0

        local driver
        driver=$(readlink -f /sys/class/net/"$iface"/device/driver 2>/dev/null | xargs basename 2>/dev/null)
        if [[ "$driver" == "brcmfmac" ]]; then
            onboard_ifaces+=("$iface")
        else
            usb_ifaces+=("$iface")
        fi
    done
}

write_link_rule() {
    local alias="$1" mac="$2"
    cat > "$UDEV_DIR/10-${alias}.link" <<EOF
[Match]
MACAddress=${mac}

[Link]
Name=${alias}
EOF
    echo "Wrote udev rule: $alias → $mac"
}

assign_roles() {
    local upstream_iface="" hotspot_iface="" mgmt_iface=""

    # gl-mgmt: onboard BCM
    [[ ${#onboard_ifaces[@]} -gt 0 ]] && mgmt_iface="${onboard_ifaces[0]}"

    # gl-upstream: USB adapter with monitor mode (highest capability)
    for iface in "${usb_ifaces[@]}"; do
        if [[ "${iface_monitor[$iface]}" -eq 1 ]] && [[ -z "$upstream_iface" ]]; then
            upstream_iface="$iface"
        fi
    done

    # gl-hotspot: remaining USB adapter with AP mode
    for iface in "${usb_ifaces[@]}"; do
        [[ "$iface" == "$upstream_iface" ]] && continue
        [[ "${iface_ap[$iface]}" -eq 1 ]] && [[ -z "$hotspot_iface" ]] && hotspot_iface="$iface"
    done

    # Fallback: if only one USB adapter, assign it as upstream only
    if [[ -z "$hotspot_iface" ]] && [[ ${#usb_ifaces[@]} -ge 2 ]]; then
        for iface in "${usb_ifaces[@]}"; do
            [[ "$iface" == "$upstream_iface" ]] && continue
            hotspot_iface="$iface"
            break
        done
    fi

    echo ""
    echo "Interface assignment:"
    echo "  gl-mgmt     → ${mgmt_iface:-NONE} (${iface_mac[$mgmt_iface]:-N/A})"
    echo "  gl-upstream → ${upstream_iface:-NONE} (${iface_mac[$upstream_iface]:-N/A})"
    echo "  gl-hotspot  → ${hotspot_iface:-NONE} (${iface_mac[$hotspot_iface]:-N/A})"

    # Save map to state
    mkdir -p /var/lib/ghostlink
    {
        echo "gl-mgmt=${mgmt_iface}"
        echo "gl-upstream=${upstream_iface}"
        echo "gl-hotspot=${hotspot_iface}"
    } > /var/lib/ghostlink/interfaces.map

    if $WRITE_UDEV; then
        [[ -n "$mgmt_iface"     ]] && write_link_rule gl-mgmt     "${iface_mac[$mgmt_iface]}"
        [[ -n "$upstream_iface" ]] && write_link_rule gl-upstream  "${iface_mac[$upstream_iface]}"
        [[ -n "$hotspot_iface"  ]] && write_link_rule gl-hotspot   "${iface_mac[$hotspot_iface]}"
    fi
}

collect_interfaces
assign_roles
