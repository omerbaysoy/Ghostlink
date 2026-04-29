#!/usr/bin/env bash
# Identity engine — called on boot by gl-identity.service
# Applies persisted identity or auto-rotates based on ghostlink.conf

set -euo pipefail

REPO="/opt/ghostlink"
CONF="/etc/ghostlink/ghostlink.conf"
STATE="/var/lib/ghostlink/identity.state"

source "$REPO/identity/mgmt_guard.sh" 2>/dev/null || true

ini_get() {
    local section="$1" key="$2" default="${3:-}"
    local val
    val=$(awk -F'=' "/^\[${section}\]/{s=1} s && /^${key}=/{print \$2; exit}" "$CONF" 2>/dev/null)
    echo "${val:-$default}"
}

# Bail out gracefully if config is not yet installed (first run before install finishes)
if [[ ! -f "$CONF" ]]; then
    logger -t "gl-identity" "Config not found at $CONF — identity engine skipped"
    exit 0
fi

PERSIST="$(ini_get identity persist_across_reboot true)"
AUTO_ROTATE="$(ini_get identity auto_rotate false)"
DEFAULT_PROFILE="$(ini_get identity default_profile random)"
STABLE_ON_TRUSTED="$(ini_get identity stable_on_trusted_network true)"
UPSTREAM_IFACE="$(ini_get network upstream_interface gl-upstream)"

# Resolve to actual OS interface if role mapping is in use
_actual_upstream=$(role_iface "upstream" 2>/dev/null || echo "")
[[ -n "$_actual_upstream" ]] && UPSTREAM_IFACE="$_actual_upstream"

logger -t "gl-identity" "Starting identity engine (iface=$UPSTREAM_IFACE persist=$PERSIST auto_rotate=$AUTO_ROTATE)"

# Verify the target interface exists before attempting to spoof
if ! ip link show "$UPSTREAM_IFACE" &>/dev/null; then
    logger -t "gl-identity" "Interface $UPSTREAM_IFACE not found — skipping identity apply"
    exit 0
fi

# Management protection: refuse to touch a protected interface
if is_protected_iface "$UPSTREAM_IFACE" 2>/dev/null; then
    logger -t "gl-identity" "Interface $UPSTREAM_IFACE is protected — identity engine skipped"
    exit 0
fi

# If auto_rotate=false, skip all rotation — just restore if persist is on
if [[ "$AUTO_ROTATE" != "true" ]]; then
    if [[ "$PERSIST" == "true" ]] && [[ -f "$STATE" ]]; then
        _s_mac="" _s_profile=""
        while IFS='=' read -r k v; do
            case "$k" in MAC) _s_mac="$v" ;; PROFILE) _s_profile="$v" ;; esac
        done < "$STATE"
        if [[ -n "${_s_mac:-}" && -n "${_s_profile:-}" ]]; then
            logger -t "gl-identity" "Restoring persisted: $_s_profile ($_s_mac)"
            bash "$REPO/identity/spoof.sh" "$UPSTREAM_IFACE" "$_s_profile" "$_s_mac"
        fi
    else
        logger -t "gl-identity" "auto_rotate=false and no persisted state — leaving identity unchanged"
    fi
    exit 0
fi

# auto_rotate=true from here on

# Skip rotation if connected to a trusted management network
if [[ "$STABLE_ON_TRUSTED" == "true" ]] && is_trusted_ssid 2>/dev/null; then
    logger -t "gl-identity" "Connected to trusted SSID — skipping rotation (stable_on_trusted_network=true)"
    exit 0
fi

# Restore persisted identity first (overrides rotation when persist=true)
if [[ "$PERSIST" == "true" ]] && [[ -f "$STATE" ]]; then
    _s_mac="" _s_profile=""
    while IFS='=' read -r k v; do
        case "$k" in MAC) _s_mac="$v" ;; PROFILE) _s_profile="$v" ;; esac
    done < "$STATE"
    if [[ -n "${_s_mac:-}" && -n "${_s_profile:-}" ]]; then
        logger -t "gl-identity" "Restoring persisted: $_s_profile ($_s_mac)"
        bash "$REPO/identity/spoof.sh" "$UPSTREAM_IFACE" "$_s_profile" "$_s_mac"
        exit 0
    fi
fi

# Rotate to a new identity
logger -t "gl-identity" "Rotating to new identity (profile=$DEFAULT_PROFILE)"
bash "$REPO/identity/rotate.sh" "$UPSTREAM_IFACE" "$DEFAULT_PROFILE"
