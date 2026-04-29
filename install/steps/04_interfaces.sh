#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
source "$(dirname "$0")/../lib/detect.sh"
REPO_ROOT="${1:?}"

gl_step "Running hardware inventory..."
bash "$REPO_ROOT/network/hw_inventory.sh" text 2>/dev/null | while IFS='=' read -r key val; do
    [[ "$key" == "---" ]] && echo "" && continue
    [[ "$key" == "IFACE" ]] && gl_info "  Found interface: $val" && continue
    [[ "$key" =~ ^(DRIVER|TYPE|USB_ID|ROLE)$ ]] && echo "    $key=$val"
done || true

gl_step "Writing interface naming rules..."
bash "$REPO_ROOT/network/classify.sh" --write-link --write-udev

gl_step "Reloading udev rules..."
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=net 2>/dev/null || true

gl_step "Waiting for interfaces to appear..."
sleep 3

echo ""
for iface in gl-mgmt gl-upstream gl-hotspot; do
    if ip link show "$iface" &>/dev/null; then
        state=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null || echo "unknown")
        driver=$(basename "$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null)" 2>/dev/null || echo "n/a")
        gl_success "$iface ready  (state=$state driver=$driver)"
    else
        gl_warn "$iface not yet visible — may appear after reboot or adapter plug-in"
        gl_info "  (udev + systemd .link rules written — will apply on next boot)"
    fi
done
echo ""

gl_success "Interface classification complete"
