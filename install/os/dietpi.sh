#!/usr/bin/env bash
# OS Profile: DietPi
# Minimal base — preserve lightweight nature, install only what GhostLink needs

GL_OS_PROFILE="dietpi"
GL_OS_PRETTY="DietPi"
GL_OS_FAMILY="debian"

# ── Hardware feature flags ───────────────────────────────────────────────────
# Enable only if running on RPi hardware
GL_ENABLE_FAN=false         # Overridden to true at runtime if is_rpi5
GL_ENABLE_ZRAM=true         # DietPi often has zram-swap pre-configured
GL_ENABLE_NVME=false        # Overridden to true if NVMe detected
GL_HW_STRICT=false

# ── Package manager ──────────────────────────────────────────────────────────
# DietPi includes apt-get but G_AGI is the DietPi wrapper (checks/installs)
# We use apt-get directly for compatibility
GL_PKG_UPDATE="apt-get update -qq"
GL_PKG_INSTALL="apt-get install -y -qq"
GL_PKG_CHECK="dpkg -l"

# ── Driver handling ──────────────────────────────────────────────────────────
GL_DRIVER_CHECK_FIRST=true
GL_DRIVER_BUILD_DKMS=true
GL_HEADERS_PKG="linux-headers-$(uname -r)"
GL_HEADERS_PKG_ALT="raspberrypi-kernel-headers"

# ── Tool handling ────────────────────────────────────────────────────────────
# Check first — DietPi may have some tools pre-installed via dietpi-software
GL_TOOLS_CHECK_FIRST=true
GL_TOOLS_ALWAYS_INSTALL=false

# ── Interface classification ─────────────────────────────────────────────────
# DietPi on RPi uses onboard WiFi; on other hardware may use ethernet
GL_MGMT_TYPE="auto"         # auto = prefer ethernet, fall back to WiFi

# ── Headless ────────────────────────────────────────────────────────────────
# DietPi is headless by design
GL_HEADLESS_MODE="native"
GL_DISABLE_DISPLAY=false    # Nothing to disable; already headless

# ── DietPi extras ───────────────────────────────────────────────────────────
# DietPi ships without some standard tools — these will always be installed
GL_DIETPI_BASE_PKGS="curl wget git jq python3 python3-venv"
