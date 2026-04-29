#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
source "$(dirname "$0")/../lib/detect.sh"
REPO_ROOT="${1:?}"

# ── Package index update ──────────────────────────────────────────────────────
gl_step "Updating package index..."
${GL_PKG_UPDATE:-apt-get update -qq}

# ── Base packages always needed ───────────────────────────────────────────────
gl_step "Installing base dependencies..."
BASE_PKGS="curl wget git jq python3 python3-venv build-essential iw wireless-tools"

# DietPi base (may be missing more than usual)
if [[ "${GL_OS:-}" == "dietpi" ]]; then
    BASE_PKGS="$BASE_PKGS ${GL_DIETPI_BASE_PKGS:-}"
fi

# shellcheck disable=SC2086
${GL_PKG_INSTALL:-apt-get install -y -qq} $BASE_PKGS
gl_success "Base packages installed"

# ── ZRAM ─────────────────────────────────────────────────────────────────────
if [[ "${GL_ENABLE_ZRAM:-false}" == "true" ]]; then
    gl_step "Configuring ZRAM swap..."

    # Check if zram is already configured (DietPi may pre-configure it)
    if swapon --show | grep -q zram 2>/dev/null; then
        gl_info "ZRAM already active — skipping"
    else
        ${GL_PKG_INSTALL:-apt-get install -y -qq} zram-tools 2>/dev/null || \
            ${GL_PKG_INSTALL:-apt-get install -y -qq} zramswap 2>/dev/null || \
            gl_warn "zram-tools not found in repo — skipping"
        bash "$REPO_ROOT/system/zram.sh" apply 2>/dev/null || gl_warn "ZRAM setup skipped"
    fi
else
    gl_info "ZRAM disabled for this OS profile — skipping"
fi

# ── NVMe I/O tuning ───────────────────────────────────────────────────────────
if [[ "${GL_ENABLE_NVME:-false}" == "true" ]]; then
    gl_step "Optimizing NVMe I/O..."
    bash "$REPO_ROOT/system/ssd.sh" apply
    gl_success "NVMe I/O optimized"
else
    gl_info "NVMe tuning disabled for this OS profile — skipping"
fi

# ── Kernel parameters ─────────────────────────────────────────────────────────
gl_step "Applying kernel parameters..."
cp "$REPO_ROOT/system/99-ghostlink.conf" /etc/sysctl.d/
sysctl -q -p /etc/sysctl.d/99-ghostlink.conf || gl_warn "Some sysctl parameters could not be applied"
gl_success "Kernel parameters applied"

# ── Fan control (RPi 5 only) ──────────────────────────────────────────────────
if [[ "${GL_ENABLE_FAN:-false}" == "true" ]]; then
    gl_step "Installing fan control service..."
    bash "$REPO_ROOT/system/fan.sh" install
    gl_success "Fan control installed"
else
    gl_info "Fan control not enabled for this OS profile — skipping"
fi

gl_success "System optimization complete"
