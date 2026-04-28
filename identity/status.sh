#!/usr/bin/env bash
# Show current identity state

STATE="/var/lib/ghostlink/identity.state"
REAL_MACS="/var/lib/ghostlink/real_macs"

echo ""
echo "  Identity Status"
echo "  ─────────────────────────────────"

if [[ -f "$STATE" ]]; then
    source "$STATE"
    echo "  Interface : $IFACE"
    echo "  Profile   : $PROFILE"
    echo "  Vendor    : $VENDOR $MODEL"
    echo "  Spoof MAC : $MAC"
    echo "  Applied   : $APPLIED_AT"
else
    echo "  No active identity (factory MACs)"
fi

echo ""
echo "  Factory MACs"
echo "  ─────────────────────────────────"
if [[ -f "$REAL_MACS" ]]; then
    while IFS='=' read -r iface mac; do
        current=$(cat /sys/class/net/"$iface"/address 2>/dev/null || echo "down")
        indicator="  "
        [[ "$current" != "$mac" ]] && indicator="* "
        echo "  ${indicator}${iface} : ${mac}  (current: ${current})"
    done < "$REAL_MACS"
else
    echo "  No factory MACs on record"
fi

echo ""
