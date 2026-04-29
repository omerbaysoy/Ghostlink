#!/usr/bin/env bash
# gl-upstream (RTL8812AU) state machine
#
# States: idle | monitor | station | connected | failed
# Transitions:
#   idle/connected → monitor  : enable monitor mode (scan/capture)
#   monitor → station         : restore managed mode
#   station → connected       : connect to WiFi network (upstream)
#   connected → station       : disconnect
#
# Key design (from KROVEX lessons):
#   - Use iw type switch to keep interface name gl-upstream (no wlan1mon renaming)
#   - Always kill airmon-ng check-kill processes before mode switch
#   - After connecting upstream, set it as default route (metric 100)
#   - Never touch gl-mgmt routes during upstream operations
#   - Track state in /var/lib/ghostlink/upstream.state
#
# Usage: upstream_mode.sh {status|monitor|station|connect <ssid> [pass]|disconnect}

set -euo pipefail

IFACE="gl-upstream"
CONF="/etc/ghostlink/ghostlink.conf"
STATE="/var/lib/ghostlink/upstream.state"
NM_CON="GHOSTLINK-UPSTREAM"

mkdir -p "$(dirname "$STATE")"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()     { echo "  [upstream] $*"; }
log_ok()  { echo "  [upstream] ✓ $*"; }
log_err() { echo "  [upstream] ✗ $*" >&2; }
log_warn(){ echo "  [upstream] ⚠ $*"; }

iface_exists() {
    [[ -d "/sys/class/net/$IFACE" ]]
}

iface_ip() {
    ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}'
}

current_mode() {
    if ! iface_exists; then echo "missing"; return; fi
    local mode
    mode=$(iw dev "$IFACE" info 2>/dev/null | awk '/type/{print $2}')
    case "${mode:-}" in
        monitor)          echo "monitor" ;;
        managed|station)  echo "station" ;;
        *)                echo "idle"    ;;
    esac
}

write_state() {
    local mode="$1" ssid="${2:-}" ip="${3:-}"
    cat > "$STATE" <<EOF
MODE=$mode
IFACE=$IFACE
SSID=$ssid
IP=$ip
TIMESTAMP=$(date +%s)
EOF
}

read_state() {
    [[ -f "$STATE" ]] && cat "$STATE" || echo "MODE=unknown"
}

wifi_manager() {
    if systemctl is-active NetworkManager &>/dev/null; then echo "nm"
    elif systemctl is-active "wpa_supplicant@${IFACE}" &>/dev/null; then echo "wpa"
    else echo "none"
    fi
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_status() {
    echo ""
    echo "  Upstream Interface (gl-upstream)"
    echo "  ─────────────────────────────────────"

    if ! iface_exists; then
        log_err "Interface $IFACE not found — is RTL8812AU adapter plugged in?"
        echo ""
        return 1
    fi

    local mode ip ssid
    mode=$(current_mode)
    ip=$(iface_ip)

    echo "  Interface : $IFACE"
    echo "  Mode      : $mode"
    [[ -n "$ip" ]] && echo "  IP        : $ip"

    if [[ "$mode" == "station" || "$mode" == "idle" ]]; then
        ssid=$(iwgetid "$IFACE" -r 2>/dev/null || echo "")
        [[ -n "$ssid" ]] && echo "  SSID      : $ssid"
    fi

    local dflt
    dflt=$(ip -4 route | grep "^default" | grep "$IFACE" || true)
    [[ -n "$dflt" ]] && echo "  Routing   : default gateway"

    if [[ -f "$STATE" ]]; then
        echo ""
        echo "  State file:"
        sed 's/^/    /' "$STATE"
    fi
    echo ""
}

cmd_monitor() {
    if ! iface_exists; then
        log_err "$IFACE not found — cannot enable monitor mode"
        return 1
    fi

    local mode
    mode=$(current_mode)
    if [[ "$mode" == "monitor" ]]; then
        log_ok "$IFACE is already in monitor mode"
        write_state "monitor"
        return 0
    fi

    log "Enabling monitor mode on $IFACE..."

    # Kill processes that hold the interface (NM, wpa_supplicant, dhclient)
    _kill_interface_users

    ip link set dev "$IFACE" down
    iw dev "$IFACE" set type monitor

    # Set flags for better capture compatibility
    iw dev "$IFACE" set monitor none 2>/dev/null || true
    ip link set dev "$IFACE" up

    # Verify
    mode=$(current_mode)
    if [[ "$mode" == "monitor" ]]; then
        log_ok "$IFACE → monitor mode (ready for scan/capture)"
    else
        log_err "Failed to enter monitor mode (current: $mode)"
        return 1
    fi

    write_state "monitor"
}

cmd_station() {
    if ! iface_exists; then
        log_err "$IFACE not found"
        return 1
    fi

    local mode
    mode=$(current_mode)
    if [[ "$mode" == "station" || "$mode" == "idle" ]]; then
        log_ok "$IFACE is already in managed/station mode"
        write_state "station"
        return 0
    fi

    log "Switching $IFACE to managed mode..."

    ip link set dev "$IFACE" down

    # From monitor → managed (keep same interface name, no rename)
    iw dev "$IFACE" set type managed

    ip link set dev "$IFACE" up

    # Re-hand to NetworkManager if available
    if systemctl is-active NetworkManager &>/dev/null; then
        nmcli dev set "$IFACE" managed yes >/dev/null 2>&1 || true
    fi

    rfkill unblock wifi 2>/dev/null || true

    mode=$(current_mode)
    if [[ "$mode" == "station" || "$mode" == "idle" ]]; then
        log_ok "$IFACE → managed/station mode"
    else
        log_err "Mode switch failed (current: $mode)"
        return 1
    fi

    write_state "station"
}

cmd_connect() {
    local ssid="${1:-}"
    local pass="${2:-}"

    if [[ -z "$ssid" ]]; then
        log_err "Usage: upstream_mode.sh connect <ssid> [password]"
        return 1
    fi

    if ! iface_exists; then
        log_err "$IFACE not found"
        return 1
    fi

    # Ensure managed mode first
    local mode
    mode=$(current_mode)
    if [[ "$mode" == "monitor" ]]; then
        log "Switching from monitor to station first..."
        cmd_station
    fi

    log "Connecting $IFACE to upstream WiFi: $ssid"

    local mgr
    mgr=$(wifi_manager)

    if [[ "$mgr" == "nm" ]]; then
        _nm_connect "$ssid" "$pass"
    else
        _wpa_connect "$ssid" "$pass"
    fi

    # Set upstream as default route (metric 100 — preferred over gl-mgmt)
    _set_upstream_default

    local ip
    ip=$(iface_ip)
    log_ok "Connected: $IFACE → $ssid @ ${ip:-no-ip}"
    write_state "connected" "$ssid" "${ip:-}"
}

cmd_disconnect() {
    if ! iface_exists; then return 0; fi

    local mgr
    mgr=$(wifi_manager)

    if [[ "$mgr" == "nm" ]]; then
        nmcli connection down "$NM_CON" >/dev/null 2>&1 || true
        nmcli dev disconnect "$IFACE" >/dev/null 2>&1 || true
    else
        pkill -f "dhclient.*$IFACE" 2>/dev/null || true
        pkill -f "dhcpcd.*$IFACE" 2>/dev/null || true
        ip addr flush dev "$IFACE" 2>/dev/null || true
    fi

    # Remove default route through this interface
    while ip -4 route del default dev "$IFACE" 2>/dev/null; do :; done

    log_ok "$IFACE disconnected"
    write_state "station"
}

# ── Backends ──────────────────────────────────────────────────────────────────

_kill_interface_users() {
    # Gracefully detach NM from this interface for monitor mode operations
    if systemctl is-active NetworkManager &>/dev/null; then
        nmcli dev set "$IFACE" managed no >/dev/null 2>&1 || true
    fi
    # Kill dhclient/dhcpcd on this interface
    pkill -f "dhclient.*$IFACE" 2>/dev/null || true
    pkill -f "dhcpcd.*$IFACE"  2>/dev/null || true
    # Kill wpa_supplicant on this interface only
    pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null || true
    sleep 0.5
}

_nm_connect() {
    local ssid="$1" pass="$2"

    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi on >/dev/null 2>&1 || true
    nmcli dev set "$IFACE" managed yes >/dev/null 2>&1 || true

    nmcli connection delete "$NM_CON" >/dev/null 2>&1 || true
    nmcli connection add \
        type wifi \
        ifname "$IFACE" \
        con-name "$NM_CON" \
        ssid "$ssid" >/dev/null

    nmcli connection modify "$NM_CON" \
        ipv4.method auto \
        ipv4.never-default no \
        ipv4.route-metric 100 \
        ipv6.method ignore \
        connection.autoconnect no >/dev/null

    if [[ -n "$pass" ]]; then
        nmcli connection modify "$NM_CON" \
            802-11-wireless-security.key-mgmt wpa-psk \
            802-11-wireless-security.psk "$pass" >/dev/null
    fi

    if ! nmcli --wait 45 connection up "$NM_CON" ifname "$IFACE" >/dev/null 2>&1; then
        log_err "NetworkManager failed to connect to '$ssid'"
        log_err "Tip: check SSID/password or run: journalctl -u NetworkManager | tail -20"
        return 1
    fi

    local ip=""
    for _ in {1..20}; do
        ip=$(iface_ip); [[ -n "$ip" ]] && break; sleep 1
    done
    [[ -n "${ip:-}" ]] || { log_err "No IP after connecting"; return 1; }
}

_wpa_connect() {
    local ssid="$1" pass="$2"
    local wpa_conf="/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf"

    cat > "$wpa_conf" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="$ssid"
    psk="$pass"
    key_mgmt=WPA-PSK
}
EOF
    chmod 600 "$wpa_conf"

    # Start/restart wpa_supplicant for this interface
    systemctl restart "wpa_supplicant@${IFACE}" 2>/dev/null || \
        wpa_supplicant -B -i "$IFACE" -c "$wpa_conf" 2>/dev/null || true

    # Get IP via dhcpcd or dhclient
    if command -v dhcpcd &>/dev/null; then
        dhcpcd -b "$IFACE" 2>/dev/null || true
    else
        dhclient -b "$IFACE" 2>/dev/null || true
    fi

    local ip=""
    for _ in {1..30}; do
        ip=$(iface_ip); [[ -n "$ip" ]] && break; sleep 1
    done
    [[ -n "${ip:-}" ]] || log_warn "No IP assigned — SSID/password may be wrong"
}

_set_upstream_default() {
    local gw
    gw=$(ip -4 route show dev "$IFACE" 2>/dev/null | awk '/default/{print $3; exit}')
    if [[ -z "$gw" ]]; then
        gw=$(ip -4 route show dev "$IFACE" 2>/dev/null | awk '/via/{print $3; exit}')
    fi

    if [[ -n "$gw" ]]; then
        # Remove lower-priority default routes (keep mgmt local route)
        ip route replace default via "$gw" dev "$IFACE" metric 100 2>/dev/null || true
        log_ok "Default route: via $gw dev $IFACE metric 100"
    else
        log_warn "Could not determine gateway — default route not set"
    fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-status}" in
    status)     cmd_status                ;;
    monitor)    cmd_monitor               ;;
    station)    cmd_station               ;;
    connect)    shift; cmd_connect "$@"   ;;
    disconnect) cmd_disconnect            ;;
    state)      read_state               ;;
    *)
        echo "Usage: upstream_mode.sh {status|monitor|station|connect <ssid> [pass]|disconnect}" >&2
        exit 1
        ;;
esac
