#!/usr/bin/env bash
# Rotate identity on an interface
# Usage: rotate.sh <interface> <profile|random>

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$REPO/identity/profiles.sh" ]]; then
    REPO="/opt/ghostlink"
fi
source "$REPO/identity/profiles.sh"
source "$REPO/identity/mgmt_guard.sh"

IFACE="${1:?Usage: rotate.sh <interface> <profile|random>}"
TARGET="${2:-random}"

# Management protection: refuse to spoof protected interfaces
if is_protected_iface "$IFACE"; then
    echo "  [identity] BLOCKED: $IFACE is a protected management interface" >&2
    echo "  [identity] MAC spoofing on $IFACE is disabled (protect_gl_mgmt=true)" >&2
    echo "  [identity] To spoof operational identity, use: rotate.sh gl-upstream random" >&2
    exit 1
fi

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
