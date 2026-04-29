#!/usr/bin/env bash
# Interface role classifier — writes systemd .link files for deterministic naming
#
# Strategy (from KROVEX lessons):
#   - Use driver name to assign roles — more reliable than USB enumeration order
#     or capability probing. USB adapters may appear as wlan0/wlan1/wlan2 in any
#     order depending on boot timing; driver names are stable.
#   - Onboard (brcmfmac)  → gl-mgmt
#   - RTL8812AU (88XXau)  → gl-upstream
#   - RTL88x2BU (88x2bu)  → gl-hotspot
#   - Also write udev rules based on USB ID for adapters not yet loaded at install time
#
# Usage: classify.sh [--write-link|--write-udev|--map-only|--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="$SCRIPT_DIR/hw_inventory.sh"

LINK_DIR="/etc/systemd/network"
UDEV_DIR="/etc/udev/rules.d"
MAP_FILE="/var/lib/ghostlink/interfaces.map"

WRITE_LINK=false
WRITE_UDEV=false
MAP_ONLY=false
JSON=false

for arg in "$@"; do
    case "$arg" in
        --write-link)  WRITE_LINK=true ;;
        --write-udev)  WRITE_UDEV=true ;;
        --map-only)    MAP_ONLY=true   ;;
        --json)        JSON=true       ;;
    esac
done

# ── Collect hardware inventory ──────────────────────────────────────────────

declare -A inv_mac inv_driver inv_type inv_usb_id inv_role

if [[ -x "$INVENTORY" ]]; then
    current_iface=""
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
        key="${key%$'\n'}"
        [[ "$key" == "---" ]] && { current_iface=""; continue; }
        [[ "$key" == "IFACE" ]] && { current_iface="$val"; continue; }
        [[ -z "$current_iface" ]] && continue
        case "$key" in
            MAC)    inv_mac["$current_iface"]="$val"    ;;
            DRIVER) inv_driver["$current_iface"]="$val" ;;
            TYPE)   inv_type["$current_iface"]="$val"   ;;
            USB_ID) inv_usb_id["$current_iface"]="$val" ;;
            ROLE)   inv_role["$current_iface"]="$val"   ;;
        esac
    done < <("$INVENTORY" text 2>/dev/null)
fi

# ── Role assignment ──────────────────────────────────────────────────────────

mgmt_iface=""
upstream_iface=""
hotspot_iface=""
aux_iface=""

# Prefer driver-detected assignment
for iface in "${!inv_role[@]}"; do
    role="${inv_role[$iface]}"
    case "$role" in
        gl-mgmt)
            [[ -z "$mgmt_iface" ]] && mgmt_iface="$iface"
            ;;
        gl-upstream)
            [[ -z "$upstream_iface" ]] && upstream_iface="$iface"
            ;;
        gl-hotspot)
            [[ -z "$hotspot_iface" ]] && hotspot_iface="$iface"
            ;;
        gl-aux)
            [[ -z "$aux_iface" ]] && aux_iface="$iface"
            ;;
    esac
done

# Fallback: if no driver-based assignment found, use USB/onboard type
if [[ -z "$mgmt_iface" && -z "$upstream_iface" && -z "$hotspot_iface" ]]; then
    for iface in "${!inv_type[@]}"; do
        t="${inv_type[$iface]}"
        if [[ "$t" == "onboard" && -z "$mgmt_iface" ]]; then
            mgmt_iface="$iface"
        elif [[ "$t" == "usb" && -z "$upstream_iface" ]]; then
            upstream_iface="$iface"
        elif [[ "$t" == "usb" && -z "$hotspot_iface" && "$iface" != "$upstream_iface" ]]; then
            hotspot_iface="$iface"
        elif [[ "$t" == "usb" && -z "$aux_iface" && "$iface" != "$upstream_iface" && "$iface" != "$hotspot_iface" ]]; then
            aux_iface="$iface"
        fi
    done
fi

# Safe accessors — return N/A when iface variable is empty (avoids "bad array subscript")
role_driver() { local iface="${1:-}"; [[ -z "$iface" ]] && echo "N/A" && return; echo "${inv_driver[$iface]:-N/A}"; }
role_mac()    { local iface="${1:-}"; [[ -z "$iface" ]] && echo "N/A" && return; echo "${inv_mac[$iface]:-N/A}"; }

if $MAP_ONLY; then
    echo "gl-mgmt=${mgmt_iface:-}"
    echo "gl-upstream=${upstream_iface:-}"
    echo "gl-hotspot=${hotspot_iface:-}"
    echo "gl-aux=${aux_iface:-}"
    exit 0
fi

if $JSON; then
    python3 -c "
import json, sys
d = {
  'gl-mgmt':    '${mgmt_iface:-}',
  'gl-upstream':'${upstream_iface:-}',
  'gl-hotspot': '${hotspot_iface:-}',
  'gl-aux':     '${aux_iface:-}',
}
print(json.dumps(d, indent=2))
"
    exit 0
fi

echo ""
echo "  Interface role assignment:"
printf "  %-14s → %-12s  driver=%-12s  mac=%s\n" \
    "gl-mgmt"     "${mgmt_iface:-NONE}"     "$(role_driver "$mgmt_iface")"     "$(role_mac "$mgmt_iface")"
printf "  %-14s → %-12s  driver=%-12s  mac=%s\n" \
    "gl-upstream"  "${upstream_iface:-NONE}" "$(role_driver "$upstream_iface")" "$(role_mac "$upstream_iface")"
printf "  %-14s → %-12s  driver=%-12s  mac=%s\n" \
    "gl-hotspot"   "${hotspot_iface:-NONE}"  "$(role_driver "$hotspot_iface")"  "$(role_mac "$hotspot_iface")"
printf "  %-14s → %-12s  driver=%-12s  mac=%s\n" \
    "gl-aux"       "${aux_iface:-NONE}"      "$(role_driver "$aux_iface")"      "$(role_mac "$aux_iface")"
echo ""

# ── Write systemd .link files (driver-based — survive USB re-enumeration) ───

write_link_driver() {
    local role="$1" driver="$2"
    [[ -z "$driver" || "$driver" == "unknown" ]] && return
    mkdir -p "$LINK_DIR"
    cat > "$LINK_DIR/10-${role}.link" <<EOF
[Match]
Driver=${driver}

[Link]
Name=${role}
EOF
    echo "  Wrote: $LINK_DIR/10-${role}.link  (Driver=${driver} → ${role})"
}

# Also write MAC-based .link as fallback (used when adapter is already renamed gl-*)
write_link_mac() {
    local role="$1" mac="$2"
    [[ -z "$mac" || "$mac" == "unknown" ]] && return
    mkdir -p "$LINK_DIR"
    cat > "$LINK_DIR/11-${role}-mac.link" <<EOF
[Match]
MACAddress=${mac}

[Link]
Name=${role}
EOF
}

if $WRITE_LINK; then
    [[ -n "$mgmt_iface" ]]     && write_link_driver gl-mgmt     "${inv_driver[$mgmt_iface]:-}"
    [[ -n "$mgmt_iface" ]]     && write_link_mac    gl-mgmt     "${inv_mac[$mgmt_iface]:-}"
    [[ -n "$upstream_iface" ]] && write_link_driver gl-upstream  "${inv_driver[$upstream_iface]:-}"
    [[ -n "$upstream_iface" ]] && write_link_mac    gl-upstream  "${inv_mac[$upstream_iface]:-}"
    [[ -n "$hotspot_iface" ]]  && write_link_driver gl-hotspot   "${inv_driver[$hotspot_iface]:-}"
    [[ -n "$hotspot_iface" ]]  && write_link_mac    gl-hotspot   "${inv_mac[$hotspot_iface]:-}"
    [[ -n "$aux_iface" ]]      && write_link_driver gl-aux       "${inv_driver[$aux_iface]:-}"
    [[ -n "$aux_iface" ]]      && write_link_mac    gl-aux       "${inv_mac[$aux_iface]:-}"
fi

# ── Write udev rules (USB ID-based — active even before driver loads) ────────
# These cover all known RTL8812AU and RTL88x2BU USB IDs from sources.conf

write_udev_rules() {
    mkdir -p "$UDEV_DIR"
    cat > "$UDEV_DIR/72-ghostlink-wifi.rules" <<'EOF'
# Ghostlink deterministic WiFi interface naming (USB ID-based)
# RTL8812AU → gl-upstream, RTL88x2BU → gl-hotspot, RTL8188EUS → gl-aux
# regardless of USB enumeration order.

# RTL8812AU — pentest/upstream (aircrack-ng monitor+injection driver)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="8812", NAME="gl-upstream"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="881a", NAME="gl-upstream"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="8811", NAME="gl-upstream"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="2357", ATTRS{idProduct}=="0101", NAME="gl-upstream"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="2357", ATTRS{idProduct}=="0103", NAME="gl-upstream"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="a811", NAME="gl-upstream"

# RTL88x2BU — distribution AP / preferred hotspot (morrownr AP-mode driver)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="b812", NAME="gl-hotspot"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="b820", NAME="gl-hotspot"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="b82c", NAME="gl-hotspot"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="2001", ATTRS{idProduct}=="331e", NAME="gl-hotspot"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="c820", NAME="gl-hotspot"

# RTL8188EUS — auxiliary adapter / fallback AP (aircrack-ng rtl8188eus driver)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="8179", NAME="gl-aux"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="8178", NAME="gl-aux"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="817e", NAME="gl-aux"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="0179", NAME="gl-aux"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="2001", ATTRS{idProduct}=="3311", NAME="gl-aux"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{idVendor}=="2357", ATTRS{idProduct}=="010c", NAME="gl-aux"
EOF
    echo "  Wrote: $UDEV_DIR/72-ghostlink-wifi.rules"
}

if $WRITE_UDEV; then
    write_udev_rules
fi

# ── Save interface map ────────────────────────────────────────────────────────

mkdir -p "$(dirname "$MAP_FILE")"
{
    echo "gl-mgmt=${mgmt_iface:-}"
    echo "gl-upstream=${upstream_iface:-}"
    echo "gl-hotspot=${hotspot_iface:-}"
    echo "gl-aux=${aux_iface:-}"
} > "$MAP_FILE"
echo "  Saved: $MAP_FILE"
