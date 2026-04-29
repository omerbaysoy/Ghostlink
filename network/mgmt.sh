#!/usr/bin/env bash
# Management WiFi (gl-mgmt) — connect, protect, keep, configure
#
# Design rules (from KROVEX lessons):
#   - Default action: keep the existing connection if gl-mgmt already has an IP
#   - Never add gl-mgmt as the default route (SSH/dashboard access must survive)
#   - Detect NM vs wpa_supplicant and use the right tool
#   - Never break an existing working connection without explicit user request
#
# Usage: mgmt.sh {start|status|keep|configure|reconnect}
#   start      — keep existing connection if up, connect if not (boot service behavior)
#   status     — show current state
#   keep       — verify existing connection, persist state, protect routes
#   configure  — interactive SSID/password config (writes config, reconnects)
#   reconnect  — restart connection using saved config

set -euo pipefail

IFACE="gl-mgmt"
CONF="/etc/ghostlink/ghostlink.conf"
STATE="/run/ghostlink/mgmt.state"
NM_CON="GHOSTLINK-MGMT"

mkdir -p "$(dirname "$STATE")"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()     { echo "  [mgmt] $*"; }
log_ok()  { echo "  [mgmt] ✓ $*"; }
log_err() { echo "  [mgmt] ✗ $*" >&2; }
log_warn(){ echo "  [mgmt] ⚠ $*"; }

ini_get() {
    local section="$1" key="$2" default="${3:-}"
    local val
    val=$(awk -F'=' "/^\[${section}\]/{s=1} s && /^${key}=/{print \$2; exit}" "$CONF" 2>/dev/null)
    echo "${val:-$default}"
}

iface_ip() {
    ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}'
}

iface_up() {
    [[ -d "/sys/class/net/$IFACE" ]] || return 1
    local ip
    ip=$(iface_ip)
    [[ -n "$ip" ]]
}

# Detect which WiFi stack is managing this interface
wifi_manager() {
    if systemctl is-active NetworkManager &>/dev/null; then
        echo "nm"
    elif systemctl is-active "wpa_supplicant@${IFACE}" &>/dev/null; then
        echo "wpa"
    elif systemctl is-active wpa_supplicant &>/dev/null; then
        echo "wpa"
    else
        echo "none"
    fi
}

# Ensure gl-mgmt never adds a default route (management route must stay local)
protect_routes() {
    local mgr
    mgr=$(wifi_manager)

    if [[ "$mgr" == "nm" ]]; then
        local conn
        conn=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null | head -1 || true)
        if [[ -n "$conn" && "$conn" != "--" ]]; then
            nmcli connection modify "$conn" \
                ipv4.never-default yes \
                ipv4.route-metric  900 \
                ipv6.never-default yes \
                ipv6.route-metric  900 >/dev/null 2>&1 || true
            nmcli device reapply "$IFACE" >/dev/null 2>&1 || true
        fi
    fi

    # Always remove any default route via gl-mgmt at the kernel level
    while ip -4 route del default dev "$IFACE" 2>/dev/null; do :; done
    log_ok "Route protection applied: $IFACE will never be default gateway"
}

save_state() {
    local ip="${1:-$(iface_ip)}"
    local ssid="${2:-$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null | head -1 || echo unknown)}"
    mkdir -p "$(dirname "$STATE")"
    cat > "$STATE" <<EOF
IFACE=$IFACE
IP=$ip
SSID=$ssid
MANAGER=$(wifi_manager)
TIMESTAMP=$(date +%s)
EOF
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_status() {
    echo ""
    echo "  Management WiFi (gl-mgmt)"
    echo "  ─────────────────────────────────────"

    if ! [[ -d "/sys/class/net/$IFACE" ]]; then
        log_err "Interface $IFACE not found — is the RPi onboard WiFi available?"
        echo ""
        return 1
    fi

    local ip
    ip=$(iface_ip)
    local mgr
    mgr=$(wifi_manager)

    if [[ -n "$ip" ]]; then
        local ssid=""
        if [[ "$mgr" == "nm" ]]; then
            ssid=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null | head -1 || echo "")
        else
            ssid=$(iwgetid "$IFACE" -r 2>/dev/null || echo "")
        fi
        echo "  Status  : connected"
        echo "  SSID    : ${ssid:-unknown}"
        echo "  IP      : $ip"
        echo "  Manager : $mgr"
    else
        echo "  Status  : not connected"
        echo "  Manager : $mgr"
    fi

    local dflt_via_mgmt
    dflt_via_mgmt=$(ip -4 route | grep "^default" | grep "$IFACE" || true)
    if [[ -n "$dflt_via_mgmt" ]]; then
        log_warn "CAUTION: $IFACE is a default route — SSH may break if upstream is lost"
    fi

    [[ -f "$STATE" ]] && echo "" && echo "  State file:" && sed 's/^/    /' "$STATE"
    echo ""
}

cmd_keep() {
    if ! iface_up; then
        log_warn "$IFACE does not have an IP address — nothing to keep"
        return 0
    fi
    local ip
    ip=$(iface_ip)
    log_ok "Keeping existing connection: $IFACE @ $ip"
    protect_routes
    save_state "$ip"
}

cmd_start() {
    if ! [[ -d "/sys/class/net/$IFACE" ]]; then
        log_warn "$IFACE not found — skipping management WiFi setup"
        return 0
    fi

    if iface_up; then
        local ip
        ip=$(iface_ip)
        log_ok "$IFACE already connected ($ip) — keeping"
        protect_routes
        save_state "$ip"
        return 0
    fi

    log "$IFACE has no IP — attempting to connect using saved config..."
    cmd_reconnect
}

cmd_configure() {
    local ssid="${1:-}"
    local pass="${2:-}"

    if [[ -z "$ssid" ]]; then
        read -rp "  Management WiFi SSID: " ssid
    fi
    if [[ -z "$pass" ]]; then
        read -rsp "  Management WiFi Password: " pass; echo ""
    fi

    # Save to ghostlink.conf
    if [[ -f "$CONF" ]]; then
        sed -i "s/^mode=.*/mode=existing/" "$CONF"
        sed -i "s/^ssid=.*/ssid=${ssid}/" "$CONF"
        sed -i "s/^password=.*/password=${pass}/" "$CONF"
        log_ok "Config written to $CONF"
    fi

    local mgr
    mgr=$(wifi_manager)

    if [[ "$mgr" == "nm" ]]; then
        _nm_connect "$ssid" "$pass"
    else
        _wpa_configure "$ssid" "$pass"
    fi

    protect_routes
    save_state "" "$ssid"
}

cmd_reconnect() {
    if ! [[ -f "$CONF" ]]; then
        log_err "Config not found: $CONF"
        return 1
    fi

    local ssid pass mode
    ssid=$(ini_get mgmt ssid)
    pass=$(ini_get mgmt password)
    mode=$(ini_get mgmt mode "existing")

    if [[ "$mode" == "custom" ]]; then
        _static_ip
        return 0
    fi

    if [[ -z "$ssid" ]]; then
        log_err "mgmt.ssid not configured in $CONF — run 'ghostlink mgmt configure'"
        return 1
    fi

    local mgr
    mgr=$(wifi_manager)
    if [[ "$mgr" == "nm" ]]; then
        _nm_connect "$ssid" "$pass"
    else
        _wpa_configure "$ssid" "$pass"
        _wpa_connect
    fi

    protect_routes
    save_state "" "$ssid"
}

# ── NM backend ────────────────────────────────────────────────────────────────

_nm_connect() {
    local ssid="$1" pass="$2"
    log "Connecting via NetworkManager: $IFACE → $ssid"

    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi on >/dev/null 2>&1 || true
    nmcli dev set "$IFACE" managed yes >/dev/null 2>&1 || true

    # Remove stale connection if it exists
    nmcli connection delete "$NM_CON" >/dev/null 2>&1 || true

    nmcli connection add \
        type wifi \
        ifname "$IFACE" \
        con-name "$NM_CON" \
        ssid "$ssid" >/dev/null

    nmcli connection modify "$NM_CON" \
        802-11-wireless-security.key-mgmt wpa-psk \
        802-11-wireless-security.psk "$pass" \
        ipv4.method auto \
        ipv4.never-default yes \
        ipv4.route-metric 900 \
        ipv6.method ignore \
        connection.autoconnect yes >/dev/null

    if ! nmcli --wait 45 connection up "$NM_CON" ifname "$IFACE" >/dev/null 2>&1; then
        log_err "NM failed to connect to $ssid — check SSID/password"
        log_err "Run: journalctl -u NetworkManager | tail -20"
        return 1
    fi

    local ip
    for _ in {1..15}; do
        ip=$(iface_ip); [[ -n "$ip" ]] && break; sleep 1
    done
    [[ -n "${ip:-}" ]] || { log_err "No IP after connecting to $ssid"; return 1; }
    log_ok "Connected: $IFACE → $ssid @ $ip"
}

# ── wpa_supplicant + dhcpcd backend ──────────────────────────────────────────

_wpa_configure() {
    local ssid="$1" pass="$2"
    local conf="/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf"
    log "Writing wpa_supplicant config: $conf"
    cat > "$conf" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="$ssid"
    psk="$pass"
    key_mgmt=WPA-PSK
}
EOF
    chmod 600 "$conf"
}

_wpa_connect() {
    systemctl enable --now "wpa_supplicant@${IFACE}" 2>/dev/null || \
        systemctl restart "wpa_supplicant@${IFACE}" 2>/dev/null || true

    # dhcpcd / dhclient for IP
    if command -v dhcpcd &>/dev/null; then
        dhcpcd -b "$IFACE" 2>/dev/null || true
    else
        dhclient -b "$IFACE" 2>/dev/null || true
    fi

    local ip=""
    for _ in {1..30}; do
        ip=$(iface_ip); [[ -n "$ip" ]] && break; sleep 1
    done
    [[ -n "$ip" ]] || { log_warn "No IP assigned to $IFACE after 30s — check credentials"; return 0; }
    log_ok "Connected via wpa_supplicant: $IFACE @ $ip"
}

_static_ip() {
    local static_ip="192.168.10.1"
    ip addr flush dev "$IFACE" 2>/dev/null || true
    ip addr add "${static_ip}/24" dev "$IFACE" 2>/dev/null || true
    ip link set "$IFACE" up
    log_ok "$IFACE configured with static IP: $static_ip"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-status}" in
    start)     cmd_start                       ;;
    status)    cmd_status                      ;;
    keep)      cmd_keep                        ;;
    configure) shift; cmd_configure "$@"       ;;
    reconnect) cmd_reconnect                   ;;
    *)
        echo "Usage: mgmt.sh {start|status|keep|configure [ssid] [pass]|reconnect}" >&2
        exit 1
        ;;
esac
