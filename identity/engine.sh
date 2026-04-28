#!/usr/bin/env bash
# Identity engine — called on boot by gl-identity.service
# Applies persisted identity or auto-rotates based on config

set -euo pipefail

REPO="/opt/ghostlink"
CONF="/etc/ghostlink/ghostlink.conf"
STATE="/var/lib/ghostlink/identity.state"

ini_get() {
    local section="$1" key="$2"
    awk -F'=' "/^\[${section}\]/{s=1} s && /^${key}=/{print \$2; exit}" "$CONF"
}

PERSIST=$(ini_get identity persist_across_reboot)
AUTO_ROTATE=$(ini_get identity auto_rotate)
DEFAULT_PROFILE=$(ini_get identity default_profile)
UPSTREAM_IFACE=$(ini_get network upstream_interface)
UPSTREAM_IFACE="${UPSTREAM_IFACE:-gl-upstream}"

logger -t "gl-identity" "Starting identity engine"

if [[ "$PERSIST" == "true" ]] && [[ -f "$STATE" ]]; then
    source "$STATE"
    if [[ -n "${MAC:-}" && -n "${PROFILE:-}" ]]; then
        logger -t "gl-identity" "Restoring identity: $PROFILE ($MAC)"
        bash "$REPO/identity/spoof.sh" "$UPSTREAM_IFACE" "$PROFILE" "$MAC"
        exit 0
    fi
fi

if [[ "$AUTO_ROTATE" == "true" ]] || [[ "${DEFAULT_PROFILE}" == "random" ]]; then
    logger -t "gl-identity" "Auto-rotating to random profile"
    bash "$REPO/identity/rotate.sh" "$UPSTREAM_IFACE" random
else
    logger -t "gl-identity" "Applying profile: $DEFAULT_PROFILE"
    bash "$REPO/identity/rotate.sh" "$UPSTREAM_IFACE" "$DEFAULT_PROFILE"
fi
