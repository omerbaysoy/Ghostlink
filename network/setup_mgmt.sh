#!/usr/bin/env bash
# Configure gl-mgmt — SSH/dashboard interface
# Reads mode from /etc/ghostlink/ghostlink.conf

set -euo pipefail

CONF="/etc/ghostlink/ghostlink.conf"
IFACE="gl-mgmt"

ini_get() {
    local section="$1" key="$2"
    awk -F'=' "/^\[${section}\]/{s=1} s && /^${key}=/{print \$2; exit}" "$CONF"
}

MODE=$(ini_get mgmt mode)
SSID=$(ini_get mgmt ssid)
PASS=$(ini_get mgmt password)

connect_wpa() {
    cat > /etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="$SSID"
    psk="$PASS"
    key_mgmt=WPA-PSK
}
EOF
    chmod 600 /etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf

    systemctl enable --now wpa_supplicant@${IFACE}
    dhclient "$IFACE" &
    echo "gl-mgmt: connecting to $SSID..."
}

case "$MODE" in
    existing) connect_wpa ;;
    custom)
        ip addr add 192.168.10.1/24 dev "$IFACE" 2>/dev/null || true
        ip link set "$IFACE" up
        echo "gl-mgmt: static 192.168.10.1"
        ;;
    *)
        echo "gl-mgmt: mode=$MODE, skipping configuration"
        ;;
esac
