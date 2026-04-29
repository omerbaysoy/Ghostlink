#!/usr/bin/env bash
# Identity engine — called on boot by gl-identity.service
# Applies persisted identity or auto-rotates based on ghostlink.conf

set -euo pipefail

REPO="/opt/ghostlink"
CONF="/etc/ghostlink/ghostlink.conf"
STATE="/var/lib/ghostlink/identity.state"

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
UPSTREAM_IFACE="$(ini_get network upstream_interface gl-upstream)"

logger -t "gl-identity" "Starting identity engine (iface=$UPSTREAM_IFACE persist=$PERSIST)"

# Verify the target interface exists before attempting to spoof
if ! ip link show "$UPSTREAM_IFACE" &>/dev/null; then
    logger -t "gl-identity" "Interface $UPSTREAM_IFACE not found — skipping identity apply"
    exit 0
fi

# Restore persisted identity
if [[ "$PERSIST" == "true" ]] && [[ -f "$STATE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE" 2>/dev/null || true
    if [[ -n "${MAC:-}" && -n "${PROFILE:-}" ]]; then
        logger -t "gl-identity" "Restoring: $PROFILE ($MAC)"
        bash "$REPO/identity/spoof.sh" "$UPSTREAM_IFACE" "$PROFILE" "$MAC"
        exit 0
    fi
fi

# Rotate to a new identity
if [[ "$AUTO_ROTATE" == "true" ]] || [[ "$DEFAULT_PROFILE" == "random" ]]; then
    logger -t "gl-identity" "Rotating to random profile"
    bash "$REPO/identity/rotate.sh" "$UPSTREAM_IFACE" random
else
    logger -t "gl-identity" "Applying profile: $DEFAULT_PROFILE"
    bash "$REPO/identity/rotate.sh" "$UPSTREAM_IFACE" "$DEFAULT_PROFILE"
fi
