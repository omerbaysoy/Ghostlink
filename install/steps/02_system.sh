#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
REPO_ROOT="${1:?}"

gl_step "Updating package index..."
apt-get update -qq

gl_step "Installing base packages..."
apt-get install -y -qq zram-tools curl wget git build-essential

gl_step "Configuring ZRAM..."
bash "$REPO_ROOT/system/zram.sh"

gl_step "Optimizing NVMe I/O..."
bash "$REPO_ROOT/system/ssd.sh"

gl_step "Applying kernel parameters..."
cp "$REPO_ROOT/system/99-ghostlink.conf" /etc/sysctl.d/
sysctl -p /etc/sysctl.d/99-ghostlink.conf

gl_step "Installing fan control service..."
bash "$REPO_ROOT/system/fan.sh" install

gl_success "System optimization complete"
