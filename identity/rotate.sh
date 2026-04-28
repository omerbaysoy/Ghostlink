#!/usr/bin/env bash
# Rotate identity on an interface
# Usage: rotate.sh <interface> <profile|random>

set -euo pipefail

REPO="/opt/ghostlink"
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
