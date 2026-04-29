#!/usr/bin/env bash
# Pentest tool installation — OS-aware, installs only missing tools
source "$(dirname "$0")/../lib/ui.sh"
source "$(dirname "$0")/../lib/detect.sh"
REPO_ROOT="${1:?}"
source "$REPO_ROOT/config/sources.conf"

mkdir -p "$GHOSTLINK_TOOLS" "$GHOSTLINK_WORDLISTS"

PKG_INSTALL="${GL_PKG_INSTALL:-apt-get install -y -qq}"

# ── Smart install helper ──────────────────────────────────────────────────────
# Installs a package only if the binary is not already present
apt_install_if_missing() {
    local binary="$1"
    local pkg="${2:-$1}"

    if tool_exists "$binary"; then
        gl_info "$binary already present — skipping"
    else
        gl_step "Installing $pkg..."
        # shellcheck disable=SC2086
        $PKG_INSTALL "$pkg" && gl_success "$pkg installed" || gl_warn "$pkg installation failed"
    fi
}

# ── APT tools ────────────────────────────────────────────────────────────────
gl_step "Installing pentest tools (apt)..."
${GL_PKG_UPDATE:-apt-get update -qq}

# Map: binary_name → package_name
declare -A TOOL_MAP=(
    [aircrack-ng]=aircrack-ng
    [airodump-ng]=aircrack-ng
    [aireplay-ng]=aircrack-ng
    [airmon-ng]=aircrack-ng
    [hcxdumptool]=hcxdumptool
    [hcxpcapngtool]=hcxtools
    [hashcat]=hashcat
    [reaver]=reaver
    [macchanger]=macchanger
    [tcpdump]=tcpdump
    [iw]=iw
    [iwconfig]=wireless-tools
    [hostapd]=hostapd
    [dnsmasq]=dnsmasq
    [iptables]=iptables
    [netfilter-persistent]=iptables-persistent
    [openssl]=openssl
    [envsubst]=gettext-base
    [jq]=jq
)

# Kali native tools: verify presence without installing (they come with Kali)
KALI_VERIFY_ONLY="${GL_KALI_NATIVE_TOOLS:-}"

missing_count=0
for binary in "${!TOOL_MAP[@]}"; do
    pkg="${TOOL_MAP[$binary]}"

    # On Kali, for tools that should be pre-installed, just verify
    if [[ "${GL_OS:-}" == "kali" ]] && [[ " $KALI_VERIFY_ONLY " == *" $binary "* ]]; then
        if tool_exists "$binary"; then
            gl_info "$binary ✓ (Kali native)"
        else
            gl_warn "$binary not found on Kali — will install $pkg"
            apt_install_if_missing "$binary" "$pkg"
            missing_count=$((missing_count+1))
        fi
        continue
    fi

    # Standard install-if-missing
    if ! tool_exists "$binary"; then
        missing_count=$((missing_count+1))
    fi
    apt_install_if_missing "$binary" "$pkg"
done

gl_success "APT tools: $missing_count package(s) installed"

# ── wifite2 (git install) ─────────────────────────────────────────────────────
gl_step "Setting up wifite2..."
if [[ -d "$TOOL_WIFITE2_DEST/.git" ]]; then
    gl_info "wifite2 already cloned — pulling updates"
    git -C "$TOOL_WIFITE2_DEST" pull -q 2>/dev/null || true
else
    git clone -q --depth 1 --branch "$TOOL_WIFITE2_BRANCH" \
        "$TOOL_WIFITE2_URL" "$TOOL_WIFITE2_DEST"
fi

# ── Python venv ───────────────────────────────────────────────────────────────
gl_step "Creating Python venv at $GHOSTLINK_VENV..."
if [[ ! -d "$GHOSTLINK_VENV" ]]; then
    python3 -m venv "$GHOSTLINK_VENV"
fi
"$GHOSTLINK_VENV/bin/pip" install -q --upgrade pip

# Install wifite2 into venv
"$GHOSTLINK_VENV/bin/pip" install -q -e "$TOOL_WIFITE2_DEST"

# Install GhostLink Python deps
# shellcheck disable=SC2086
"$GHOSTLINK_VENV/bin/pip" install -q $PIP_PACKAGES
gl_success "Python venv ready ($(du -sh "$GHOSTLINK_VENV" | cut -f1))"

# ── bettercap ────────────────────────────────────────────────────────────────
gl_step "Checking bettercap..."
if tool_exists bettercap; then
    gl_info "bettercap already present — skipping"
elif apt-cache show bettercap &>/dev/null 2>&1; then
    $PKG_INSTALL bettercap && gl_success "bettercap installed via apt"
elif command -v go &>/dev/null; then
    go install "$TOOL_BETTERCAP_GO" 2>/dev/null && gl_success "bettercap installed via go"
else
    gl_warn "bettercap not available — install manually if needed"
fi

# ── Wordlist ──────────────────────────────────────────────────────────────────
gl_step "Checking wordlist..."
ROCKYOU_PATH="$GHOSTLINK_WORDLISTS/rockyou.txt"
ROCKYOU_GZ="/usr/share/wordlists/rockyou.txt.gz"
ROCKYOU_KALI="/usr/share/wordlists/rockyou.txt"

if [[ -f "$ROCKYOU_PATH" ]]; then
    gl_info "rockyou.txt already present ($(du -sh "$ROCKYOU_PATH" | cut -f1))"
elif [[ -f "$ROCKYOU_KALI" ]]; then
    # Kali ships rockyou.txt
    ln -sf "$ROCKYOU_KALI" "$ROCKYOU_PATH"
    gl_success "rockyou.txt linked from Kali wordlists"
elif [[ -f "$ROCKYOU_GZ" ]]; then
    gl_step "Decompressing rockyou.txt.gz..."
    gunzip -c "$ROCKYOU_GZ" > "$ROCKYOU_PATH"
    gl_success "rockyou.txt extracted from system wordlists"
else
    gl_step "Downloading rockyou.txt..."
    wget -q "$WORDLIST_ROCKYOU_URL" -O "$ROCKYOU_PATH" && \
        gl_success "rockyou.txt downloaded ($(du -sh "$ROCKYOU_PATH" | cut -f1))" || \
        gl_warn "rockyou.txt download failed — set wordlist path manually in ghostlink.conf"
fi

gl_success "Tool installation complete"
