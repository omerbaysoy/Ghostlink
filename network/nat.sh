#!/usr/bin/env bash
# GhostLink NAT + policy routing — management-safe, idempotent
#
# Traffic model:
#   Management (gl-mgmt): never forwarded, never NATed, route table untouched.
#   Hotspot clients:      marked fwmark 0x50 in mangle PREROUTING.
#   Policy routing:       fwmark 0x50 → ghostlink_upstream table (ID 200).
#   ghostlink_upstream:   default via upstream gateway (added when upstream has IP+GW).
#   MASQUERADE:           hotspot traffic exits via upstream interface.
#
# KROVEX lessons applied:
#   - Named chains only (GHOSTLINK_FORWARD, GHOSTLINK_NAT, GHOSTLINK_MANGLE).
#   - Never iptables -F or -X on global chains.
#   - Idempotent: flush own chains then reapply on every call.
#   - Role resolution via interfaces.map (falls back to gl-* names).
#
# Usage: nat.sh {up|down|status}

set -euo pipefail

MAP_FILE="/var/lib/ghostlink/interfaces.map"
RT_TABLE_ID=200
RT_TABLE_NAME="ghostlink_upstream"
FWMARK=0x50
FWMARK_MASK=0xff
IP_RULE_PRIORITY=200

CHAIN_FWD="GHOSTLINK_FORWARD"
CHAIN_NAT="GHOSTLINK_NAT"
CHAIN_MANGLE="GHOSTLINK_MANGLE"

# ── Role resolution ───────────────────────────────────────────────────────────

_resolve_role() {
    local role="gl-${1#gl-}"
    if [[ -f "$MAP_FILE" ]]; then
        local val
        val=$(grep "^${role}=" "$MAP_FILE" 2>/dev/null | cut -d= -f2)
        [[ -n "$val" ]] && echo "$val" && return
    fi
    [[ -d "/sys/class/net/$role" ]] && echo "$role" && return
    echo ""
}

UPSTREAM=$(_resolve_role upstream)
MGMT=$(_resolve_role mgmt)

# Effective hotspot: prefer setup_hotspot.sh runtime state, fallback to role map
HOTSPOT=$(_resolve_role hotspot)
if [[ -f /run/ghostlink/hotspot.state ]]; then
    _eff=$(grep '^HOTSPOT_IFACE=' /run/ghostlink/hotspot.state 2>/dev/null | cut -d= -f2)
    [[ -n "$_eff" ]] && HOTSPOT="$_eff"
fi

# Fallbacks if map is not yet written
[[ -z "$UPSTREAM" ]] && UPSTREAM="gl-upstream"
[[ -z "$MGMT" ]]     && MGMT="gl-mgmt"
[[ -z "$HOTSPOT" ]]  && HOTSPOT="gl-hotspot"

log()     { echo "  [nat] $*"; }
log_ok()  { echo "  [nat] ✓ $*"; }
log_err() { echo "  [nat] ✗ $*" >&2; }
log_warn(){ echo "  [nat] ⚠ $*"; }

iface_exists() { [[ -d "/sys/class/net/$1" ]]; }

# ── Routing table ─────────────────────────────────────────────────────────────

_ensure_rt_table() {
    local rt_tables="/etc/iproute2/rt_tables"
    if ! grep -qE "^${RT_TABLE_ID}[[:space:]]" "$rt_tables" 2>/dev/null; then
        echo "${RT_TABLE_ID}  ${RT_TABLE_NAME}" >> "$rt_tables"
        log_ok "Routing table registered: $RT_TABLE_ID $RT_TABLE_NAME"
    fi
}

_setup_upstream_route() {
    local upstream="$1"

    if ! iface_exists "$upstream"; then
        log_warn "Upstream interface $upstream not found — route not added to $RT_TABLE_NAME"
        return 0
    fi

    local gw
    gw=$(ip -4 route show dev "$upstream" 2>/dev/null | awk '/default/{print $3; exit}')
    [[ -z "$gw" ]] && gw=$(ip -4 route show dev "$upstream" 2>/dev/null | awk '/via/{print $3; exit}')

    if [[ -z "$gw" ]]; then
        log_warn "No gateway on $upstream — $RT_TABLE_NAME route not set"
        log "  Connect upstream first: ghostlink upstream connect <ssid> [pass]"
        return 0
    fi

    # Flush old routes in our table, then add current gateway
    ip route flush table "$RT_TABLE_NAME" 2>/dev/null || true

    # Add subnet route for upstream network so return path works
    local up_net
    up_net=$(ip -4 route show dev "$upstream" 2>/dev/null | awk '!/default/ && /[0-9]/{print $1; exit}')
    [[ -n "$up_net" ]] && \
        ip route add "$up_net" dev "$upstream" table "$RT_TABLE_NAME" 2>/dev/null || true

    ip route add default via "$gw" dev "$upstream" table "$RT_TABLE_NAME"
    log_ok "Upstream route: default via $gw dev $upstream  (table $RT_TABLE_NAME)"
}

_setup_ip_rule() {
    # Idempotent: add rule only if not already present
    if ! ip rule show 2>/dev/null | grep -q "fwmark 0x${FWMARK#0x}.*$RT_TABLE_NAME\|fwmark 0x${FWMARK#0x}.*$RT_TABLE_ID"; then
        ip rule add fwmark "$FWMARK" lookup "$RT_TABLE_NAME" priority "$IP_RULE_PRIORITY" 2>/dev/null || \
            ip rule add fwmark "$FWMARK" table "$RT_TABLE_ID" priority "$IP_RULE_PRIORITY" 2>/dev/null || true
        log_ok "ip rule: fwmark $FWMARK → $RT_TABLE_NAME (priority $IP_RULE_PRIORITY)"
    fi
}

_teardown_ip_rule() {
    while ip rule del fwmark "$FWMARK" 2>/dev/null; do :; done
    ip route flush table "$RT_TABLE_NAME" 2>/dev/null || true
}

# ── iptables chain helpers ────────────────────────────────────────────────────

_ensure_chain() {
    local table="${1:-filter}" chain="$2"
    if [[ "$table" == "filter" ]]; then
        iptables -N "$chain" 2>/dev/null || iptables -F "$chain"
    else
        iptables -t "$table" -N "$chain" 2>/dev/null || iptables -t "$table" -F "$chain"
    fi
}

_hook_chain() {
    local table="${1:-filter}" hook="$2" chain="$3"
    if [[ "$table" == "filter" ]]; then
        iptables -C "$hook" -j "$chain" 2>/dev/null || iptables -I "$hook" 1 -j "$chain"
    else
        iptables -t "$table" -C "$hook" -j "$chain" 2>/dev/null || \
            iptables -t "$table" -I "$hook" 1 -j "$chain"
    fi
}

_unhook_chain() {
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
    log "Applying GhostLink NAT + policy routing..."

    # IPv4 forwarding
    sysctl -qw net.ipv4.ip_forward=1
    log_ok "net.ipv4.ip_forward=1"

    # ── Routing table registration ─────────────────────────────────────────────
    _ensure_rt_table

    # ── Policy routing: fwmark → ghostlink_upstream table ─────────────────────
    _setup_upstream_route "$UPSTREAM"
    _setup_ip_rule

    # ── mangle PREROUTING: mark hotspot client packets ─────────────────────────
    _ensure_chain mangle "$CHAIN_MANGLE"
    _hook_chain   mangle PREROUTING "$CHAIN_MANGLE"

    if iface_exists "$HOTSPOT"; then
        iptables -t mangle -A "$CHAIN_MANGLE" -i "$HOTSPOT" -j MARK --set-mark "$FWMARK"
        log_ok "fwmark $FWMARK on packets from $HOTSPOT"
    else
        log "  $HOTSPOT not yet up — fwmark rule skipped (rerun when hotspot starts)"
    fi
    iptables -t mangle -A "$CHAIN_MANGLE" -j RETURN

    # ── FORWARD chain ──────────────────────────────────────────────────────────
    _ensure_chain filter "$CHAIN_FWD"
    _hook_chain   filter FORWARD "$CHAIN_FWD"

    # Management interface: never forward (management is sacred)
    if [[ -n "$MGMT" ]]; then
        iptables -A "$CHAIN_FWD" -i "$MGMT" -j DROP
        iptables -A "$CHAIN_FWD" -o "$MGMT" -j DROP
        log_ok "Management interface $MGMT blocked from forwarding"
    fi

    # Hotspot → upstream forwarding
    if iface_exists "$HOTSPOT" && iface_exists "$UPSTREAM"; then
        iptables -A "$CHAIN_FWD" -i "$HOTSPOT" -o "$UPSTREAM" -j ACCEPT
        iptables -A "$CHAIN_FWD" -i "$UPSTREAM" -o "$HOTSPOT" \
            -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        log_ok "Forwarding: $HOTSPOT → $UPSTREAM (client internet)"
    else
        iface_exists "$HOTSPOT" || log "  $HOTSPOT not yet up — hotspot forward skipped"
        iface_exists "$UPSTREAM" || log "  $UPSTREAM not yet up — upstream forward skipped"
    fi

    iptables -A "$CHAIN_FWD" -j RETURN

    # ── POSTROUTING / MASQUERADE ───────────────────────────────────────────────
    _ensure_chain nat "$CHAIN_NAT"
    _hook_chain   nat POSTROUTING "$CHAIN_NAT"

    if iface_exists "$UPSTREAM"; then
        # MASQUERADE only hotspot-sourced traffic exiting upstream
        if iface_exists "$HOTSPOT"; then
            local hotspot_net
            hotspot_net=$(ip -4 addr show "$HOTSPOT" 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1]; exit}')
            if [[ -n "$hotspot_net" ]]; then
                # Get the subnet (not just the IP)
                local hotspot_cidr
                hotspot_cidr=$(ip -4 addr show "$HOTSPOT" 2>/dev/null | awk '/inet /{print $2; exit}')
                iptables -t nat -A "$CHAIN_NAT" -s "$hotspot_cidr" -o "$UPSTREAM" -j MASQUERADE
                log_ok "MASQUERADE: $hotspot_cidr → $UPSTREAM"
            else
                # Fallback: MASQUERADE all on upstream
                iptables -t nat -A "$CHAIN_NAT" -o "$UPSTREAM" -j MASQUERADE
                log_ok "MASQUERADE on $UPSTREAM (no hotspot IP yet)"
            fi
        else
            iptables -t nat -A "$CHAIN_NAT" -o "$UPSTREAM" -j MASQUERADE
            log_ok "MASQUERADE on $UPSTREAM"
        fi
    fi
    iptables -t nat -A "$CHAIN_NAT" -j RETURN

    # ── Persist rules ──────────────────────────────────────────────────────────
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    log_ok "GhostLink NAT + policy routing applied"
}

# ── NAT down ──────────────────────────────────────────────────────────────────

nat_down() {
    log "Removing GhostLink NAT/routing rules..."

    _unhook_chain mangle PREROUTING "$CHAIN_MANGLE"
    _unhook_chain filter FORWARD    "$CHAIN_FWD"
    _unhook_chain nat    POSTROUTING "$CHAIN_NAT"

    _teardown_ip_rule

    sysctl -qw net.ipv4.ip_forward=0 2>/dev/null || true
    log_ok "GhostLink NAT/routing rules removed"
}

# ── NAT status ────────────────────────────────────────────────────────────────

nat_status() {
    echo ""
    echo "  NAT + Routing Status"
    echo "  ─────────────────────────────────────────────────────"

    # Management
    local mgmt_ip
    mgmt_ip=$(ip -4 addr show "$MGMT" 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1];exit}' || echo "")
    echo "  Management   : $MGMT  (${mgmt_ip:-no IP})"

    # Upstream
    local up_ip up_gw
    up_ip=$(ip -4 addr show "$UPSTREAM" 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1];exit}' || echo "")
    up_gw=$(ip -4 route show dev "$UPSTREAM" 2>/dev/null | awk '/default/{print $3; exit}' || echo "")
    echo "  Upstream     : $UPSTREAM  (${up_ip:-no IP})  gw=${up_gw:-none}"

    # Hotspot
    local hs_ip
    hs_ip=$(ip -4 addr show "$HOTSPOT" 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1];exit}' || echo "")
    echo "  Hotspot      : $HOTSPOT  (${hs_ip:-no IP})"

    echo ""

    # Policy routing table
    local rt_routes
    rt_routes=$(ip route show table "$RT_TABLE_NAME" 2>/dev/null || echo "")
    if [[ -n "$rt_routes" ]]; then
        log_ok "Policy routing ($RT_TABLE_NAME): active"
        echo "$rt_routes" | awk '{print "    "$0}'
    else
        echo "  Policy routing ($RT_TABLE_NAME): inactive (no routes)"
    fi

    # ip rules
    local ip_rules
    ip_rules=$(ip rule show 2>/dev/null | grep -E "fwmark 0x${FWMARK#0x}|${RT_TABLE_NAME}" || echo "")
    if [[ -n "$ip_rules" ]]; then
        log_ok "fwmark ip rule: active"
        echo "$ip_rules" | awk '{print "    "$0}'
    else
        echo "  fwmark ip rule: inactive"
    fi

    echo ""

    # ip_forward
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    echo "  ip_forward   : $fwd"

    # FORWARD chain
    local fwd_rules
    fwd_rules=$(iptables -L "$CHAIN_FWD" 2>/dev/null | grep -c ACCEPT || echo "0")
    echo "  FORWARD      : ${fwd_rules} ACCEPT rule(s) in $CHAIN_FWD"

    # NAT chain
    local nat_rules
    nat_rules=$(iptables -t nat -L "$CHAIN_NAT" 2>/dev/null | grep -c MASQUERADE || echo "0")
    echo "  NAT          : ${nat_rules} MASQUERADE rule(s) in $CHAIN_NAT"

    # Mangle
    local mangle_rules
    mangle_rules=$(iptables -t mangle -L "$CHAIN_MANGLE" 2>/dev/null | grep -c MARK || echo "0")
    echo "  fwmark MARK  : ${mangle_rules} MARK rule(s) in $CHAIN_MANGLE"

    # Management protection
    local mgmt_default
    mgmt_default=$(ip -4 route show default 2>/dev/null | grep -c "dev $MGMT" || echo "0")
    if [[ "$mgmt_default" -gt 0 ]]; then
        echo "  Mgmt default route: WARNING — $MGMT is a default route interface"
    else
        echo "  Mgmt default route: protected (not a default route)"
    fi

    echo ""
}

# ── Route status ──────────────────────────────────────────────────────────────

route_status() {
    echo ""
    echo "  Route Status"
    echo "  ─────────────────────────────────────────────────────"

    echo ""
    echo "  ── Default routes ────────────────────────────────────"
    ip -4 route show default 2>/dev/null | awk '{print "  "$0}' || echo "  (none)"

    echo ""
    echo "  ── Management interface routes ($MGMT) ───────────────"
    ip -4 route show dev "$MGMT" 2>/dev/null | awk '{print "  "$0}' || echo "  (none / interface missing)"

    echo ""
    echo "  ── $RT_TABLE_NAME routing table ──────────────────────"
    ip route show table "$RT_TABLE_NAME" 2>/dev/null | awk '{print "  "$0}' || echo "  (empty / not configured)"

    echo ""
    echo "  ── GhostLink ip rules ────────────────────────────────"
    ip rule show 2>/dev/null | grep -E "fwmark|$RT_TABLE_NAME|$RT_TABLE_ID" | awk '{print "  "$0}' || echo "  (none)"

    echo ""
    echo "  ── Firewall / NAT summary ────────────────────────────"
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    echo "  ip_forward       : $fwd"
    local nm
    nm=$(iptables -t nat -L "$CHAIN_NAT" 2>/dev/null | grep -c MASQUERADE || echo "0")
    echo "  MASQUERADE rules : $nm (in $CHAIN_NAT)"
    echo ""
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-up}" in
    up|apply|start)    nat_up        ;;
    down|stop|remove)  nat_down      ;;
    status)            nat_status    ;;
    route-status)      route_status  ;;
    *)
        echo "Usage: nat.sh {up|down|status|route-status}" >&2
        exit 1
        ;;
esac
