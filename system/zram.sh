#!/usr/bin/env bash
# ZRAM setup — 1GB zstd, priority 100
# Idempotent: skips if ZRAM is already active

ZRAM_SIZE_MB=1024
ZRAM_COMP=zstd

apply() {
    # Already active?
    if swapon --show 2>/dev/null | grep -q zram; then
        echo "ZRAM: already active — skipping"
        return 0
    fi

    # zram kernel module
    modprobe zram 2>/dev/null || { echo "ZRAM: kernel module not available"; return 1; }

    # zramctl (from util-linux, usually present)
    if ! command -v zramctl &>/dev/null; then
        echo "ZRAM: zramctl not found — skipping"
        return 1
    fi

    local dev
    dev=$(zramctl --find --size "${ZRAM_SIZE_MB}M" --algorithm "$ZRAM_COMP" 2>/dev/null)
    if [[ -z "$dev" ]]; then
        echo "ZRAM: could not allocate device"
        return 1
    fi

    mkswap "$dev"
    swapon --priority 100 "$dev"

    # Persist via /etc/default/zramswap if service exists
    if [[ -f /etc/default/zramswap ]]; then
        cat > /etc/default/zramswap <<EOF
ALGO=$ZRAM_COMP
PERCENT=50
PRIORITY=100
EOF
        systemctl enable zramswap 2>/dev/null || true
    fi

    echo "ZRAM: ${dev} ${ZRAM_SIZE_MB}MB ${ZRAM_COMP} priority=100"
}

case "${1:-apply}" in apply) apply ;; esac
