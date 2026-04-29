#!/usr/bin/env bash
# Show identity state and management protection status

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$REPO/identity/mgmt_guard.sh" ]]; then
    REPO="/opt/ghostlink"
fi
source "$REPO/identity/mgmt_guard.sh" 2>/dev/null || true

STATE="/var/lib/ghostlink/identity.state"
REAL_MACS="/var/lib/ghostlink/real_macs"

echo ""
echo "  ── Operational Identity (gl-upstream) ────────────────"

if [[ -f "$STATE" ]]; then
    # shellcheck source=/dev/null
    _s_iface="" _s_profile="" _s_vendor="" _s_model="" _s_mac="" _s_at=""
    while IFS='=' read -r k v; do
        case "$k" in
            IFACE)      _s_iface="$v" ;;
            PROFILE)    _s_profile="$v" ;;
            VENDOR)     _s_vendor="$v" ;;
            MODEL)      _s_model="$v" ;;
            MAC)        _s_mac="$v" ;;
            APPLIED_AT) _s_at="$v" ;;
        esac
    done < "$STATE"
    echo "  Interface : ${_s_iface:-unknown}"
    echo "  Profile   : ${_s_profile:-unknown}"
    echo "  Vendor    : ${_s_vendor:-?} ${_s_model:-}"
    echo "  Spoof MAC : ${_s_mac:-unknown}"
    echo "  Applied   : ${_s_at:-unknown}"
else
    echo "  No active identity — factory MACs in use"
fi

echo ""
echo "  ── Interface Protection ──────────────────────────────"

for iface in gl-mgmt gl-upstream gl-hotspot gl-aux; do
    prot_label=""
    if is_protected_iface "$iface" 2>/dev/null; then
        prot_label="PROTECTED (MAC spoof blocked)"
    else
        prot_label="spoofable"
    fi
    current_mac=$(cat /sys/class/net/"$iface"/address 2>/dev/null || echo "not present")
    printf "  %-14s  %-30s  mac=%s\n" "$iface" "$prot_label" "$current_mac"
done

echo ""
echo "  ── Hostname Protection ───────────────────────────────"
cfg_hostname=$(mgmt_hostname 2>/dev/null || echo "Ghostlink")
active_hostname=$(hostname 2>/dev/null || echo "unknown")
echo "  Config hostname  : $cfg_hostname"
echo "  Active hostname  : $active_hostname"
if should_protect_hostname 2>/dev/null; then
    echo "  Hostname status  : PROTECTED (changes blocked)"
else
    echo "  Hostname status  : unprotected (allow_hostname_spoof=true)"
fi

trusted_ssid_line="not connected to a trusted SSID"
if is_trusted_ssid 2>/dev/null; then
    current_ssid=$(iwgetid gl-mgmt -r 2>/dev/null || echo "")
    trusted_ssid_line="TRUSTED — connected to: $current_ssid"
fi
echo "  Trusted SSID     : $trusted_ssid_line"

echo ""
echo "  ── Factory MACs ──────────────────────────────────────"
if [[ -f "$REAL_MACS" ]]; then
    while IFS='=' read -r iface mac; do
        current=$(cat /sys/class/net/"$iface"/address 2>/dev/null || echo "down")
        indicator="  "
        [[ "$current" != "$mac" ]] && indicator="* "
        printf "  %s%-14s  factory=%s  current=%s\n" "$indicator" "$iface" "$mac" "$current"
    done < "$REAL_MACS"
else
    echo "  No factory MACs on record"
fi

echo ""
