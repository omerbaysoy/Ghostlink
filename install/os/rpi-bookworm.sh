#!/usr/bin/env bash
# OS Profile: Raspberry Pi OS Bookworm (64-bit)
# Primary target — fullest feature set

GL_OS_PROFILE="rpi-bookworm"
GL_OS_PRETTY="Raspberry Pi OS Bookworm"
GL_OS_FAMILY="debian"

# ── Hardware feature flags ───────────────────────────────────────────────────
GL_ENABLE_FAN=true          # RPi 5 PWM fan via /sys/class/hwmon
GL_ENABLE_ZRAM=true         # ZRAM swap (zstd)
GL_ENABLE_NVME=true         # NVMe I/O tuning
GL_HW_STRICT=false          # Warn but don't fail on missing NVMe/fan

# ── Package manager ──────────────────────────────────────────────────────────
GL_PKG_UPDATE="apt-get update -qq"
GL_PKG_INSTALL="apt-get install -y -qq"
GL_PKG_CHECK="dpkg -l"

# ── Driver handling ──────────────────────────────────────────────────────────
# Always check whether the driver already works before building
GL_DRIVER_CHECK_FIRST=true
# Build + install via DKMS if not working
GL_DRIVER_BUILD_DKMS=true
# Headers package for this OS
GL_HEADERS_PKG="linux-headers-$(uname -r)"
# Raspberry Pi specific: raspberrypi-kernel-headers may be preferred
GL_HEADERS_PKG_ALT="raspberrypi-kernel-headers"

# ── Tool handling ────────────────────────────────────────────────────────────
# Most tools must be installed — not pre-shipped by RPi OS
GL_TOOLS_CHECK_FIRST=true
# Tools that are safe to assume missing and install without checking
GL_TOOLS_ALWAYS_INSTALL=false

# ── Interface classification ─────────────────────────────────────────────────
# Onboard WiFi is BCM43455 via brcmfmac; detect by non-USB
GL_MGMT_TYPE="wifi"         # Use onboard WiFi for management

# ── Headless ────────────────────────────────────────────────────────────────
# RPi OS Lite is headless by default; nothing to disable
GL_HEADLESS_MODE="auto"     # auto = already headless if Lite
GL_DISABLE_DISPLAY=false
