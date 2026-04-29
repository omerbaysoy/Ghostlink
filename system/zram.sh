#!/usr/bin/env bash
# ZRAM setup — 2GB zstd, priority 100
# Raspberry Pi deployments only — skipped safely on generic Debian/Ubuntu/Kali
# Idempotent: skips if ZRAM is already active

ZRAM_SIZE_MB=2048
ZRAM_COMP=zstd

is_rpi() {
    [[ -f /proc/device-tree/model ]] && grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null && return 0
    grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null
}

apply() {
    # Non-RPi systems: skip with a clear message
    if ! is_rpi; then
        echo "ZRAM: not a Raspberry Pi — skipping GhostLink ZRAM setup"
        echo "ZRAM: (configure system ZRAM manually if needed)"
        return 0
    fi

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

    echo "ZRAM: ${dev} ${ZRAM_SIZE_MB}MB ${ZRAM_COMP} priority=100 (Raspberry Pi)"
}

case "${1:-apply}" in apply) apply ;; esac
