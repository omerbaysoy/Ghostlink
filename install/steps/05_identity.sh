#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
REPO_ROOT="${1:?}"

mkdir -p /var/lib/ghostlink /etc/ghostlink

gl_step "Backing up real MAC addresses..."
for iface in $(iw dev | awk '/Interface/{print $2}'); do
    mac=$(cat /sys/class/net/"$iface"/address 2>/dev/null)
    [[ -n "$mac" ]] && echo "$iface=$mac" >> /var/lib/ghostlink/real_macs
done
gl_success "MACs saved to /var/lib/ghostlink/real_macs"

gl_step "Installing device profiles..."
cp "$REPO_ROOT/config/device_profiles.json" /etc/ghostlink/
gl_success "$(jq length /etc/ghostlink/device_profiles.json) profiles installed"

gl_step "Applying initial identity to gl-upstream..."
bash "$REPO_ROOT/identity/rotate.sh" gl-upstream random

gl_success "Identity system ready"
