#!/usr/bin/env bash
# Network utility helpers

has_internet() {
    ping -c1 -W3 8.8.8.8 &>/dev/null
}

wait_for_interface() {
    local iface="$1" timeout="${2:-15}"
    local elapsed=0
    while ! ip link show "$iface" &>/dev/null; do
        sleep 1; elapsed=$((elapsed+1))
        [[ $elapsed -ge $timeout ]] && return 1
    done
    return 0
}

interface_ip() {
    ip -4 addr show "$1" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
}

write_wpa_supplicant() {
    local ssid="$1" password="$2" conf="${3:-/etc/wpa_supplicant/wpa_supplicant.conf}"
    cat > "$conf" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="$ssid"
    psk="$password"
    key_mgmt=WPA-PSK
}
EOF
}

enable_ip_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "net.ipv4.ip_forward" /etc/sysctl.d/99-ghostlink.conf 2>/dev/null || \
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-ghostlink.conf
}

setup_nat() {
    local upstream="$1" hotspot="$2"
    iptables -t nat -C POSTROUTING -o "$upstream" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$upstream" -j MASQUERADE
    iptables -C FORWARD -i "$hotspot" -o "$upstream" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$hotspot" -o "$upstream" -j ACCEPT
    iptables -C FORWARD -i "$upstream" -o "$hotspot" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$upstream" -o "$hotspot" -m state --state RELATED,ESTABLISHED -j ACCEPT
}
