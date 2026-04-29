#!/usr/bin/env bash
# OS Profile: Raspberry Pi OS Trixie (64-bit) — testing/next release
# Essentially identical to Bookworm profile; kept separate for future divergence

GL_OS_PROFILE="rpi-trixie"
GL_OS_PRETTY="Raspberry Pi OS Trixie"
GL_OS_FAMILY="debian"

GL_ENABLE_FAN=true
GL_ENABLE_ZRAM=true
GL_ENABLE_NVME=true
GL_HW_STRICT=false

GL_PKG_UPDATE="apt-get update -qq"
GL_PKG_INSTALL="apt-get install -y -qq"
GL_PKG_CHECK="dpkg -l"

GL_DRIVER_CHECK_FIRST=true
GL_DRIVER_BUILD_DKMS=true
GL_HEADERS_PKG="linux-headers-$(uname -r)"
GL_HEADERS_PKG_ALT="raspberrypi-kernel-headers"

GL_TOOLS_CHECK_FIRST=true
GL_TOOLS_ALWAYS_INSTALL=false

GL_MGMT_TYPE="wifi"

GL_HEADLESS_MODE="auto"
GL_DISABLE_DISPLAY=false
