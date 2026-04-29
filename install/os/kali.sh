#!/usr/bin/env bash
# OS Profile: Kali Linux
# Key differences:
#   - Many pentest tools already installed → check before installing
#   - RTL8812AU may already work via in-tree or Kali-patched kernel → check first
#   - May have a desktop environment → support headless mode
#   - DKMS build still needed if driver is missing/broken

GL_OS_PROFILE="kali"
GL_OS_PRETTY="Kali Linux"
GL_OS_FAMILY="debian"

# ── Hardware feature flags ───────────────────────────────────────────────────
GL_ENABLE_FAN=false         # Not RPi; no PWM fan daemon
GL_ENABLE_ZRAM=false        # Not default on Kali; don't force it
GL_ENABLE_NVME=false        # Detect at runtime — don't assume
GL_HW_STRICT=false          # Not RPi5 — relax all hardware requirements

# ── Package manager ──────────────────────────────────────────────────────────
GL_PKG_UPDATE="apt-get update -qq"
GL_PKG_INSTALL="apt-get install -y -qq"
GL_PKG_CHECK="dpkg -l"

# ── Driver handling ──────────────────────────────────────────────────────────
# CRITICAL: always check whether driver already works before touching it
GL_DRIVER_CHECK_FIRST=true
GL_DRIVER_BUILD_DKMS=true
# Kali ships realtek-rtl88xxau-dkms in its repos — prefer that over building
GL_DRIVER_PREFER_PKG=true   # Try apt package before git+DKMS
GL_HEADERS_PKG="linux-headers-$(uname -r)"
GL_HEADERS_PKG_ALT=""

# ── Tool handling ────────────────────────────────────────────────────────────
# CRITICAL: Kali pre-ships aircrack-ng, hashcat, hcxtools, etc.
# Always check existence before attempting install
GL_TOOLS_CHECK_FIRST=true
GL_TOOLS_ALWAYS_INSTALL=false
# Tools that Kali almost certainly has (skip install attempt, just verify)
GL_KALI_NATIVE_TOOLS="aircrack-ng airodump-ng aireplay-ng airmon-ng hashcat hcxdumptool hcxtools macchanger tcpdump iw wireless-tools"

# ── Interface classification ─────────────────────────────────────────────────
# On Kali (laptop/desktop), ethernet is the preferred management interface
GL_MGMT_TYPE="auto"         # auto = prefer ethernet, fall back to non-USB WiFi

# ── Headless ────────────────────────────────────────────────────────────────
# Kali may have GNOME/XFCE/KDE — support disabling it for headless operation
GL_HEADLESS_MODE="optional" # User can request headless via --headless flag
GL_DISABLE_DISPLAY=false    # Set to true via --headless flag
