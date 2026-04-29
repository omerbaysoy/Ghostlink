#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
source "$(dirname "$0")/../lib/net.sh"
source "$(dirname "$0")/../lib/detect.sh"
REPO_ROOT="${1:?}"
CONF="$REPO_ROOT/config/ghostlink.conf"

gl_step "Installing network packages..."
${GL_PKG_INSTALL:-apt-get install -y -qq} \
    hostapd dnsmasq iptables iptables-persistent gettext-base

if ! $DRY_RUN; then
    systemctl stop hostapd dnsmasq 2>/dev/null || true
fi

if $DRY_RUN; then
    gl_info "[dry-run] Would detect existing gl-mgmt connection"
    gl_info "[dry-run] Would prompt for hotspot SSID/password if not set"
    gl_info "[dry-run] Would generate hostapd.conf, dnsmasq.conf"
    gl_info "[dry-run] Would set up NAT"
    gl_success "Network configuration complete (dry-run)"
    exit 0
fi

# ── Management WiFi (gl-mgmt) ─────────────────────────────────────────────────
echo ""
gl_info "Management interface (gl-mgmt) configuration"
gl_info "This is the interface used for SSH and dashboard access."
echo ""

# Check if gl-mgmt already has an IP (already connected — most common case)
MGMT_IP=""
if ip link show gl-mgmt &>/dev/null; then
    MGMT_IP=$(ip -4 addr show gl-mgmt 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
fi

if [[ -n "$MGMT_IP" ]]; then
    gl_success "gl-mgmt is already connected (IP: $MGMT_IP)"
    gl_info "Default action: KEEP the existing connection"
    gl_info "Your SSH session will remain active."
    echo ""

    if gl_confirm "Keep the existing gl-mgmt connection? (recommended)"; then
        gl_info "Keeping current gl-mgmt connection at $MGMT_IP"
        # Read current SSID and persist it to config
        local_ssid=$(iwgetid gl-mgmt -r 2>/dev/null || \
                     nmcli -g GENERAL.CONNECTION device show gl-mgmt 2>/dev/null | head -1 || \
                     echo "")
        [[ -n "$local_ssid" ]] && sed -i "s/^ssid=.*/ssid=${local_ssid}/" "$CONF" || true
        sed -i "s/^mode=.*/mode=existing/" "$CONF"
        gl_success "Existing management WiFi kept"
    else
        gl_warn "Reconfiguring gl-mgmt WiFi — you may temporarily lose SSH access"
        gl_prompt "New WiFi SSID" mgmt_ssid
        gl_prompt_secret "WiFi Password" mgmt_pass
        sed -i "s/^mode=.*/mode=existing/" "$CONF"
        sed -i "s/^ssid=.*/ssid=${mgmt_ssid}/" "$CONF"
        sed -i "s/^password=.*/password=${mgmt_pass}/" "$CONF"
        gl_info "New management WiFi will be applied by gl-network.service at boot"
        gl_info "Or run: ghostlink mgmt configure $mgmt_ssid"
    fi
else
    gl_warn "gl-mgmt has no IP address — it is not connected to a WiFi network"
    echo ""

    if gl_confirm "Connect gl-mgmt to an existing WiFi network?"; then
        gl_prompt "WiFi SSID" mgmt_ssid
        gl_prompt_secret "WiFi Password" mgmt_pass
        sed -i "s/^mode=.*/mode=existing/" "$CONF"
        sed -i "s/^ssid=.*/ssid=${mgmt_ssid}/" "$CONF"
        sed -i "s/^password=.*/password=${mgmt_pass}/" "$CONF"
        gl_info "Config written — connecting now..."
        bash "$REPO_ROOT/network/mgmt.sh" configure "$mgmt_ssid" "$mgmt_pass" 2>/dev/null || \
            gl_warn "Connect attempt failed — check SSID/password and retry: ghostlink mgmt configure"
    else
        gl_prompt "Static IP SSID (gl-mgmt will create its own AP)" mgmt_ssid "GhostAdmin"
        sed -i "s/^mode=.*/mode=custom/" "$CONF"
        sed -i "s/^ssid=.*/ssid=${mgmt_ssid}/" "$CONF"
        gl_info "gl-mgmt will use static IP 192.168.10.1 at boot"
    fi
fi

# ── Hotspot (gl-hotspot / gl-aux fallback) ───────────────────────────────────
echo ""
gl_info "Distribution hotspot (gl-hotspot) configuration"
gl_info "Preferred: RTL88x2BU (gl-hotspot). Fallback: RTL8188EUS (gl-aux) if enabled."
gl_info "Client devices connect here and share internet from gl-upstream."
# Show which hotspot adapter is present
if ip link show gl-hotspot &>/dev/null; then
    gl_success "gl-hotspot (RTL88x2BU) detected — preferred adapter"
elif ip link show gl-aux &>/dev/null; then
    gl_warn "gl-hotspot not found; gl-aux (RTL8188EUS) available as fallback"
    gl_warn "Enable fallback: set [aux] fallback_hotspot=true in $CONF"
else
    gl_warn "No hotspot adapter found — hotspot will not start until adapter is plugged in"
fi
echo ""

EXISTING_HS_SSID=$(awk -F'=' '/^\[hotspot\]/{s=1} s && /^ssid=/{print $2; exit}' "$CONF")
EXISTING_HS_PASS=$(awk -F'=' '/^\[hotspot\]/{s=1} s && /^password=/{print $2; exit}' "$CONF")

if [[ -n "$EXISTING_HS_SSID" && "$EXISTING_HS_SSID" != "Ghostlink-AP" && -n "$EXISTING_HS_PASS" && "$EXISTING_HS_PASS" != "ghostlink1234" ]]; then
    gl_info "Hotspot already configured: SSID=$EXISTING_HS_SSID"
    if ! gl_confirm "Reconfigure hotspot?"; then
        hs_ssid="$EXISTING_HS_SSID"
        hs_pass="$EXISTING_HS_PASS"
    else
        gl_prompt "Hotspot SSID" hs_ssid "Ghostlink-AP"
        gl_prompt_secret "Hotspot Password (min 8 chars)" hs_pass
        sed -i "s/^ssid=.*/ssid=${hs_ssid}/" "$CONF"
        sed -i "s/^password=.*/password=${hs_pass}/" "$CONF"
    fi
else
    gl_prompt "Hotspot SSID" hs_ssid "Ghostlink-AP"
    gl_prompt_secret "Hotspot Password (min 8 chars)" hs_pass
    sed -i "s/^ssid=Ghostlink-AP/ssid=${hs_ssid}/" "$CONF"
    sed -i "s/^password=ghostlink1234/password=${hs_pass}/" "$CONF"
fi

# ── Generate hostapd/dnsmasq configs ──────────────────────────────────────────
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

# ── Initial NAT rules ─────────────────────────────────────────────────────────
gl_step "Applying initial NAT rules..."
bash "$REPO_ROOT/network/nat.sh" up 2>/dev/null || \
    gl_warn "NAT setup skipped — will be applied by gl-network.service at boot"

gl_success "Network configuration complete"
