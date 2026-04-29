#!/usr/bin/env bash
# NAT: forward traffic from gl-hotspot clients through gl-upstream
# Usage: nat.sh {up|down}

UPSTREAM="gl-upstream"
HOTSPOT="gl-hotspot"
HOTSPOT_NET="192.168.50.0/24"

nat_up() {
    sysctl -qw net.ipv4.ip_forward=1

    iptables -t nat -A POSTROUTING -o "$UPSTREAM" -j MASQUERADE
    iptables -A FORWARD -i "$UPSTREAM" -o "$HOTSPOT" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i "$HOTSPOT" -o "$UPSTREAM" -j ACCEPT

    echo "NAT: $HOTSPOT_NET → $UPSTREAM enabled"
}

nat_down() {
    iptables -t nat -D POSTROUTING -o "$UPSTREAM" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$UPSTREAM" -o "$HOTSPOT" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$HOTSPOT" -o "$UPSTREAM" -j ACCEPT 2>/dev/null || true

    echo "NAT: disabled"
}

nat_save() {
    iptables-save > /etc/iptables/rules.v4
}

case "${1:-up}" in
    up|apply|start)   nat_up; nat_save ;;
    down|stop|remove) nat_down ;;
    *)                echo "Usage: nat.sh {up|down}" ;;
esac
