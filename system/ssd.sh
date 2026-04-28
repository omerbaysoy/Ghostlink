#!/usr/bin/env bash
# M.2 NVMe optimization

apply() {
    # I/O scheduler: none (NVMe bypasses elevator)
    for dev in /sys/block/nvme*/queue/scheduler; do
        [[ -f "$dev" ]] && echo none > "$dev"
    done

    # Queue depth and readahead
    for dev in /sys/block/nvme*; do
        [[ -f "$dev/queue/nr_requests" ]]   && echo 1024 > "$dev/queue/nr_requests"
        [[ -f "$dev/queue/read_ahead_kb" ]] && echo 8192 > "$dev/queue/read_ahead_kb"
    done

    # Persist via udev
    cat > /etc/udev/rules.d/60-nvme-ghostlink.rules <<'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/nr_requests}="1024"
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/read_ahead_kb}="8192"
EOF

    echo "NVMe: scheduler=none nr_requests=1024 readahead=8192KB"
}

case "${1:-apply}" in apply) apply ;; esac
