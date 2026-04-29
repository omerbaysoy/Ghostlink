#!/usr/bin/env bash
# OS Profile: Ubuntu (generic)
# STATUS: Template — structure in place, not production-ready
# TODO: Test on Ubuntu 24.04 LTS (Noble) and 22.04 LTS (Jammy)

GL_OS_PROFILE="ubuntu"
GL_OS_PRETTY="Ubuntu"
GL_OS_FAMILY="debian"

GL_ENABLE_FAN=false
GL_ENABLE_ZRAM=false        # Ubuntu 22.04+ has zswap by default; avoid conflict
GL_ENABLE_NVME=false
GL_HW_STRICT=false

GL_PKG_UPDATE="apt-get update -qq"
GL_PKG_INSTALL="apt-get install -y -qq"
GL_PKG_CHECK="dpkg -l"

GL_DRIVER_CHECK_FIRST=true
GL_DRIVER_BUILD_DKMS=true
GL_DRIVER_PREFER_PKG=false
GL_HEADERS_PKG="linux-headers-$(uname -r)"
GL_HEADERS_PKG_ALT="linux-headers-generic"

GL_TOOLS_CHECK_FIRST=true
GL_TOOLS_ALWAYS_INSTALL=false

GL_MGMT_TYPE="auto"

GL_HEADLESS_MODE="auto"
GL_DISABLE_DISPLAY=false

# TEMPLATE NOTE: Not production-ready. Verify before enabling:
# - Universe/Multiverse repos may be needed for aircrack-ng, hashcat, etc.
# - AppArmor profiles may interfere with hostapd/dnsmasq
# - UFW may block hotspot NAT rules
GL_OS_TEMPLATE_ONLY=true
