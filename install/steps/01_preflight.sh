#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
source "$(dirname "$0")/../lib/detect.sh"
source "$(dirname "$0")/../lib/net.sh"
REPO_ROOT="${1:?}"
source "$REPO_ROOT/config/sources.conf"

errors=0

gl_step "Checking board model..."
if is_rpi5; then
    gl_success "Raspberry Pi 5 detected"
else
    gl_warn "Not a Raspberry Pi 5 — proceed with caution"
fi

gl_step "Checking NVMe SSD..."
if has_nvme; then
    gl_success "NVMe SSD detected"
else
    gl_error "NVMe SSD not found — check M.2 adapter connection"
    errors=$((errors+1))
fi

gl_step "Checking USB WiFi adapters..."
count=$(usb_wifi_count)
if [[ $count -ge 2 ]]; then
    gl_success "${count} USB WiFi adapter(s) detected"
else
    gl_error "Found ${count} USB WiFi adapter(s) — minimum 2 required"
    errors=$((errors+1))
fi

gl_step "Checking internet connectivity..."
if has_internet; then
    gl_success "Internet reachable"
else
    gl_error "No internet — connect via ethernet and retry"
    errors=$((errors+1))
fi

gl_step "Checking disk space..."
free_mb=$(df -m / | awk 'NR==2{print $4}')
if [[ $free_mb -ge 8192 ]]; then
    gl_success "${free_mb} MB free"
else
    gl_error "Only ${free_mb} MB free — need at least 8 GB"
    errors=$((errors+1))
fi

[[ $errors -gt 0 ]] && { gl_error "Preflight failed with ${errors} error(s). Fix and retry."; exit 1; }
gl_success "All preflight checks passed"
