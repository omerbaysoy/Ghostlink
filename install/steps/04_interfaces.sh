#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
source "$(dirname "$0")/../lib/detect.sh"
REPO_ROOT="${1:?}"

gl_step "Probing interface capabilities..."
bash "$REPO_ROOT/network/classify.sh" --write-udev

gl_step "Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger

gl_step "Waiting for interfaces..."
sleep 3

for iface in gl-mgmt gl-upstream gl-hotspot; do
    if ip link show "$iface" &>/dev/null; then
        gl_success "$iface ready"
    else
        gl_warn "$iface not yet visible — may appear after reboot"
    fi
done

gl_success "Interface classification complete"
