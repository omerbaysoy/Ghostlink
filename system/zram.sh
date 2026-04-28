#!/usr/bin/env bash
# ZRAM setup — 1GB zstd, priority 100

ZRAM_SIZE_MB=1024
ZRAM_COMP=zstd

apply() {
    modprobe zram
    local dev
    dev=$(zramctl --find --size "${ZRAM_SIZE_MB}M" --algorithm "$ZRAM_COMP")
    mkswap "$dev"
    swapon --priority 100 "$dev"

    # Persist via /etc/default/zramswap
    cat > /etc/default/zramswap <<EOF
ALGO=$ZRAM_COMP
PERCENT=50
PRIORITY=100
EOF
    systemctl enable zramswap 2>/dev/null || true
    echo "ZRAM: ${dev} ${ZRAM_SIZE_MB}MB ${ZRAM_COMP}"
}

case "${1:-apply}" in apply) apply ;; esac
