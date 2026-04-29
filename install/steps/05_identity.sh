#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
REPO_ROOT="${1:?}"

mkdir -p /var/lib/ghostlink /etc/ghostlink

gl_step "Backing up real MAC addresses..."
for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
    mac=$(cat /sys/class/net/"$iface"/address 2>/dev/null)
    [[ -n "$mac" ]] && echo "$iface=$mac" >> /var/lib/ghostlink/real_macs
done
gl_success "MACs saved to /var/lib/ghostlink/real_macs"

gl_step "Installing device profiles..."
cp "$REPO_ROOT/config/device_profiles.json" /etc/ghostlink/
gl_success "$(jq length /etc/ghostlink/device_profiles.json) profiles installed"

# ── Hostname repair ───────────────────────────────────────────────────────────
# Read management hostname from config (default: Ghostlink) and ensure it is set.
# This repairs any hostname drift (e.g. from a previous MiPad-5-6215 spoof).
CONF="$REPO_ROOT/config/ghostlink.conf"
MGMT_HOSTNAME=$(awk -F'=' '/^\[management\]/{s=1} s && /^hostname=/{print $2; exit}' "$CONF" 2>/dev/null || echo "Ghostlink")
MGMT_HOSTNAME="${MGMT_HOSTNAME:-Ghostlink}"

gl_step "Repairing hostname to: $MGMT_HOSTNAME"
PREV_HOSTNAME=$(hostname 2>/dev/null || echo "")

hostnamectl set-hostname "$MGMT_HOSTNAME" 2>/dev/null || echo "$MGMT_HOSTNAME" > /etc/hostname

# Ensure /etc/hosts has a valid 127.0.1.1 entry so sudo doesn't warn "unable to resolve host"
if grep -qE '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${MGMT_HOSTNAME}/" /etc/hosts
else
    echo -e "127.0.1.1\t${MGMT_HOSTNAME}" >> /etc/hosts
fi

if [[ "$PREV_HOSTNAME" != "$MGMT_HOSTNAME" ]]; then
    gl_success "Hostname repaired: $PREV_HOSTNAME → $MGMT_HOSTNAME"
else
    gl_success "Hostname already correct: $MGMT_HOSTNAME"
fi

gl_info "Identity profiles installed. Operational identity (gl-upstream) is inactive."
gl_info "Identity will be applied by gl-identity.service at boot when auto_rotate=true."
gl_info "To rotate manually: ghostlink identity rotate"

gl_success "Identity system ready"
