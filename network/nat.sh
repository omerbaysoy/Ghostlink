#!/usr/bin/env bash
# NAT: forward traffic from gl-hotspot through gl-upstream
# Idempotent — uses named chains to flush and reapply on every call
#
# Traffic flow: client → gl-hotspot → [GHOSTLINK NAT] → gl-upstream → internet
#
# KROVEX lesson: named chains (GHOSTLINK_FORWARD, GHOSTLINK_NAT) are the correct
# pattern. Never use raw -A append — it duplicates rules on restart.
#
# Usage: nat.sh {up|down|status}

set -euo pipefail

UPSTREAM="gl-upstream"
MGMT="gl-mgmt"

# Effective hotspot interface: use gl-hotspot (preferred) unless setup_hotspot.sh
# wrote a fallback interface to /run/ghostlink/hotspot.state (RTL8188EUS fallback case)
HOTSPOT="gl-hotspot"
if [[ -f /run/ghostlink/hotspot.state ]]; then
    _eff=$(grep '^HOTSPOT_IFACE=' /run/ghostlink/hotspot.state 2>/dev/null | cut -d= -f2)
    [[ -n "$_eff" ]] && HOTSPOT="$_eff"
fi

CHAIN_FWD="GHOSTLINK_FORWARD"
CHAIN_NAT="GHOSTLINK_NAT"

log()     { echo "  [nat] $*"; }
log_ok()  { echo "  [nat] ✓ $*"; }
log_err() { echo "  [nat] ✗ $*" >&2; }

iface_exists() {
    [[ -d "/sys/class/net/$1" ]]
}

# ── Chain management ──────────────────────────────────────────────────────────

ensure_chain() {
    local table="${1:-filter}" chain="$2"
    if [[ "$table" == "filter" ]]; then
        iptables -N "$chain" 2>/dev/null || iptables -F "$chain"
    else
        iptables -t "$table" -N "$chain" 2>/dev/null || iptables -t "$table" -F "$chain"
    fi
}

hook_chain() {
    local table="${1:-filter}" hook="$2" chain="$3"
    if [[ "$table" == "filter" ]]; then
        iptables -C "$hook" -j "$chain" 2>/dev/null || iptables -I "$hook" 1 -j "$chain"
    else
        iptables -t "$table" -C "$hook" -j "$chain" 2>/dev/null || \
            iptables -t "$table" -I "$hook" 1 -j "$chain"
    fi
}

unhook_chain() {
    local table="${1:-filter}" hook="$2" chain="$3"
    if [[ "$table" == "filter" ]]; then
        while iptables -D "$hook" -j "$chain" 2>/dev/null; do :; done
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
    else
        while iptables -t "$table" -D "$hook" -j "$chain" 2>/dev/null; do :; done
        iptables -t "$table" -F "$chain" 2>/dev/null || true
        iptables -t "$table" -X "$chain" 2>/dev/null || true
    fi
}

# ── NAT up ────────────────────────────────────────────────────────────────────

nat_up() {
    log "Applying NAT rules (flush+reapply)..."

    # IPv4 forwarding
    sysctl -qw net.ipv4.ip_forward=1
    log_ok "net.ipv4.ip_forward=1"

    # ── FORWARD chain ─────────────────────────────────────────────────────────
    ensure_chain filter "$CHAIN_FWD"
    hook_chain   filter FORWARD "$CHAIN_FWD"

    # gl-mgmt: never forward management interface traffic
    iptables -A "$CHAIN_FWD" -i "$MGMT" -j DROP 2>/dev/null || true
    iptables -A "$CHAIN_FWD" -o "$MGMT" -j DROP 2>/dev/null || true

    # gl-hotspot → gl-upstream: forward client traffic to upstream
    if iface_exists "$HOTSPOT" && iface_exists "$UPSTREAM"; then
        iptables -A "$CHAIN_FWD" -i "$HOTSPOT" -o "$UPSTREAM" -j ACCEPT
        iptables -A "$CHAIN_FWD" -i "$UPSTREAM" -o "$HOTSPOT" \
            -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        log_ok "Forwarding: $HOTSPOT → $UPSTREAM (client internet)"
    elif ! iface_exists "$HOTSPOT"; then
        log "  $HOTSPOT not yet up — hotspot forwarding skipped (rerun when up)"
    elif ! iface_exists "$UPSTREAM"; then
        log "  $UPSTREAM not yet up — upstream forwarding skipped (rerun when up)"
    fi

    iptables -A "$CHAIN_FWD" -j RETURN

    # ── POSTROUTING (NAT) ─────────────────────────────────────────────────────
    ensure_chain nat "$CHAIN_NAT"
    hook_chain   nat POSTROUTING "$CHAIN_NAT"

    if iface_exists "$UPSTREAM"; then
        iptables -t nat -A "$CHAIN_NAT" -o "$UPSTREAM" -j MASQUERADE
        log_ok "MASQUERADE on $UPSTREAM"
    fi
    iptables -t nat -A "$CHAIN_NAT" -j RETURN

    # ── Persist ───────────────────────────────────────────────────────────────
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    log_ok "NAT rules applied"
}

# ── NAT down ──────────────────────────────────────────────────────────────────

nat_down() {
    log "Removing NAT rules..."
    unhook_chain filter FORWARD "$CHAIN_FWD"
    unhook_chain nat    POSTROUTING "$CHAIN_NAT"
    sysctl -qw net.ipv4.ip_forward=0 2>/dev/null || true
    log_ok "NAT rules removed"
}

# ── NAT status ────────────────────────────────────────────────────────────────

nat_status() {
    echo ""
    echo "  NAT Status"
    echo "  ─────────────────────────────────"

    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    echo "  ip_forward : $fwd"

    local fwd_rules
    fwd_rules=$(iptables -L "$CHAIN_FWD" 2>/dev/null | grep -c ACCEPT || echo "0")
    echo "  FORWARD    : ${fwd_rules} ACCEPT rule(s) in $CHAIN_FWD"

    local nat_rules
    nat_rules=$(iptables -t nat -L "$CHAIN_NAT" 2>/dev/null | grep -c MASQUERADE || echo "0")
    echo "  NAT        : ${nat_rules} MASQUERADE rule(s) in $CHAIN_NAT"

    echo "  Interfaces : ${HOTSPOT} → ${UPSTREAM}"
    echo ""
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-up}" in
    up|apply|start)    nat_up     ;;
    down|stop|remove)  nat_down   ;;
    status)            nat_status ;;
    *)                 echo "Usage: nat.sh {up|down|status}" >&2; exit 1 ;;
esac
