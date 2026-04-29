#!/usr/bin/env bash
# Rotate identity on an interface
# Usage: rotate.sh <interface> <profile|random>

set -euo pipefail

# Resolve REPO relative to this script's location (works from source tree AND /opt/ghostlink)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Fall back to /opt/ghostlink if profiles.sh is not found relative to script
if [[ ! -f "$REPO/identity/profiles.sh" ]]; then
    REPO="/opt/ghostlink"
fi
source "$REPO/identity/profiles.sh"

IFACE="${1:?Usage: rotate.sh <interface> <profile|random>}"
TARGET="${2:-random}"

if [[ "$TARGET" == "random" ]]; then
    PROFILE=$(random_profile)
else
    if ! profile_exists "$TARGET"; then
        echo "Error: unknown profile '$TARGET'" >&2
        exit 1
    fi
    PROFILE="$TARGET"
fi

OUI=$(profile_oui "$PROFILE")
MAC=$(generate_mac "$OUI")

bash "$REPO/identity/spoof.sh" "$IFACE" "$PROFILE" "$MAC"
