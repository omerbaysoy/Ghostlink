#!/usr/bin/env bash
# Enable headless mode — disable desktop environment and display manager
# Called only when --headless flag is passed and OS supports it (primarily Kali)
source "$(dirname "$0")/../lib/ui.sh"
REPO_ROOT="${1:?}"

gl_section "Headless Mode Configuration"
gl_info "Setting system default target to multi-user (no graphical login)"

# Set boot target
systemctl set-default multi-user.target
gl_success "Default target: multi-user.target"

# Stop and disable common display managers
for dm in gdm3 gdm sddm lightdm xdm lxdm slim; do
    if systemctl list-unit-files "${dm}.service" 2>/dev/null | grep -q "^${dm}"; then
        if systemctl is-enabled "${dm}" 2>/dev/null | grep -qE "enabled|static"; then
            systemctl disable --now "${dm}" 2>/dev/null || true
            gl_success "Disabled display manager: $dm"
        fi
    fi
done

# Ensure SSH is running for remote access
if systemctl list-unit-files ssh.service 2>/dev/null | grep -q ssh; then
    systemctl enable --now ssh 2>/dev/null || true
    gl_success "SSH enabled"
elif systemctl list-unit-files sshd.service 2>/dev/null | grep -q sshd; then
    systemctl enable --now sshd 2>/dev/null || true
    gl_success "SSHd enabled"
fi

gl_warn "A reboot is required for headless mode to take full effect"
gl_info "After reboot: dashboard will be at https://<ip>:8080"
gl_info "Remote SSH access is preserved"
