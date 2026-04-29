#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
source "$(dirname "$0")/../lib/net.sh"
REPO_ROOT="${1:?}"
CONF="$REPO_ROOT/config/ghostlink.conf"

gl_step "Installing network packages..."
${GL_PKG_INSTALL:-apt-get install -y -qq} hostapd dnsmasq iptables iptables-persistent

if ! $DRY_RUN; then
    systemctl stop hostapd dnsmasq 2>/dev/null || true
fi

# ── Management WiFi ───────────────────────────────────────────────────────────
if $DRY_RUN; then
    gl_info "[dry-run] Would prompt for gl-mgmt WiFi SSID/password"
    gl_info "[dry-run] Would prompt for hotspot SSID/password"
    gl_info "[dry-run] Would generate hostapd.conf, dnsmasq.conf"
    gl_info "[dry-run] Would set up NAT"
    gl_success "Network configuration complete (dry-run)"
    exit 0
fi

echo ""
gl_info "Management interface (gl-mgmt) configuration"
gl_info "This is how you'll SSH into and reach the dashboard."
echo ""

if gl_confirm "Connect gl-mgmt to your existing home/office network?"; then
    gl_prompt "WiFi SSID" mgmt_ssid
    gl_prompt_secret "WiFi Password" mgmt_pass
    sed -i "s/^mode=.*/mode=existing/" "$CONF"
    sed -i "s/^ssid=$/ssid=$mgmt_ssid/" "$CONF"
    sed -i "s/^password=$/password=$mgmt_pass/" "$CONF"
    gl_success "gl-mgmt will connect to: $mgmt_ssid"
else
    gl_prompt "Custom SSID for gl-mgmt" mgmt_ssid "GhostAdmin"
    gl_prompt_secret "Password for $mgmt_ssid" mgmt_pass
    sed -i "s/^mode=.*/mode=custom/" "$CONF"
    sed -i "s/^ssid=$/ssid=$mgmt_ssid/" "$CONF"
    sed -i "s/^password=$/password=$mgmt_pass/" "$CONF"
    gl_success "gl-mgmt will create SSID: $mgmt_ssid"
fi

# ── Hotspot ───────────────────────────────────────────────────────────────────
echo ""
gl_info "Distribution hotspot (gl-hotspot) configuration"
gl_info "Clients connect here to use internet through the upstream network."
echo ""

gl_prompt "Hotspot SSID" hs_ssid "GhostNet"
gl_prompt_secret "Hotspot Password (min 8 chars)" hs_pass
sed -i "s/^ssid=GhostNet/ssid=$hs_ssid/" "$CONF"
sed -i "s/^password=changeme/password=$hs_pass/" "$CONF"

# ── Generate configs ──────────────────────────────────────────────────────────
gl_step "Generating hostapd.conf..."
mkdir -p /etc/hostapd
HOTSPOT_IFACE=gl-hotspot \
HOTSPOT_SSID="$hs_ssid" \
HOTSPOT_PASS="$hs_pass" \
HOTSPOT_CHAN=6 \
envsubst < "$REPO_ROOT/network/templates/hostapd.conf.j2" > /etc/hostapd/hostapd.conf

gl_step "Generating dnsmasq.conf..."
HOTSPOT_IFACE=gl-hotspot \
envsubst < "$REPO_ROOT/network/templates/dnsmasq.conf.j2" > /etc/dnsmasq.conf

gl_step "Setting up NAT..."
enable_ip_forwarding
setup_nat gl-upstream gl-hotspot
netfilter-persistent save

gl_success "Network configuration complete"
