#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
source "$(dirname "$0")/../lib/detect.sh"
source "$(dirname "$0")/../lib/net.sh"
REPO_ROOT="${1:?}"
source "$REPO_ROOT/config/sources.conf"

errors=0
warnings=0

# ── Board / OS ────────────────────────────────────────────────────────────────
gl_step "Checking operating system..."
gl_success "Detected: $(os_pretty "${GL_OS:-$(detect_os)}")"

if is_rpi5; then
    gl_success "Raspberry Pi 5 detected"
elif is_rpi; then
    gl_info "Raspberry Pi (not RPi 5) — fan daemon will be skipped if no PWM"
elif [[ "${GL_OS:-}" == "kali" ]]; then
    gl_info "Kali Linux — hardware checks relaxed"
elif [[ "${GL_OS:-}" == "dietpi" ]]; then
    gl_info "DietPi — minimal mode"
else
    gl_info "Generic system — proceeding with available hardware"
fi

# ── NVMe ─────────────────────────────────────────────────────────────────────
gl_step "Checking storage..."
if has_nvme; then
    gl_success "NVMe SSD detected"
elif [[ "${GL_HW_STRICT:-false}" == "true" ]]; then
    gl_error "NVMe SSD not found (required for this profile)"
    errors=$((errors+1))
else
    gl_warn "No NVMe SSD — NVMe optimizations will be skipped"
    warnings=$((warnings+1))
fi

# ── USB WiFi adapters ─────────────────────────────────────────────────────────
gl_step "Checking USB WiFi adapters..."
count=$(usb_wifi_count)
if [[ $count -ge 2 ]]; then
    gl_success "${count} USB WiFi adapter(s) detected"
elif [[ $count -eq 1 ]]; then
    gl_warn "Only 1 USB WiFi adapter — hotspot distribution AP will not be available"
    warnings=$((warnings+1))
else
    # On Kali/Debian/Ubuntu, user may be using a built-in adapter
    if [[ "${GL_OS:-}" == "kali" ]] || [[ "${GL_OS:-}" == "debian" ]] || [[ "${GL_OS:-}" == "ubuntu" ]]; then
        gl_warn "No USB WiFi adapters detected — onboard adapter will be used for pentest"
        warnings=$((warnings+1))
    else
        gl_error "No USB WiFi adapters detected — at least 1 required"
        errors=$((errors+1))
    fi
fi

# ── Internet ──────────────────────────────────────────────────────────────────
gl_step "Checking internet connectivity..."
if has_internet; then
    gl_success "Internet reachable"
else
    gl_error "No internet — connect via ethernet and retry"
    errors=$((errors+1))
fi

# ── Disk space ────────────────────────────────────────────────────────────────
gl_step "Checking disk space..."
free_mb=$(df -m / | awk 'NR==2{print $4}')
min_mb=4096
if has_nvme; then min_mb=8192; fi

if [[ $free_mb -ge $min_mb ]]; then
    gl_success "${free_mb} MB free (need ${min_mb} MB)"
else
    gl_error "Only ${free_mb} MB free — need at least ${min_mb} MB"
    errors=$((errors+1))
fi

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $errors -gt 0 ]]; then
    gl_error "Preflight failed: ${errors} error(s), ${warnings} warning(s). Fix errors and retry."
    exit 1
fi
[[ $warnings -gt 0 ]] && gl_warn "Preflight passed with ${warnings} warning(s)"
gl_success "Preflight checks passed"
