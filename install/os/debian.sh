#!/usr/bin/env bash
# OS Profile: Debian (generic)
# STATUS: Template — structure in place, not production-ready
# TODO: Test on Debian 12 Bookworm and Debian 13 Trixie

GL_OS_PROFILE="debian"
GL_OS_PRETTY="Debian"
GL_OS_FAMILY="debian"

GL_ENABLE_FAN=false
GL_ENABLE_ZRAM=false
GL_ENABLE_NVME=false
GL_HW_STRICT=false

GL_PKG_UPDATE="apt-get update -qq"
GL_PKG_INSTALL="apt-get install -y -qq"
GL_PKG_CHECK="dpkg -l"

GL_DRIVER_CHECK_FIRST=true
GL_DRIVER_BUILD_DKMS=true
GL_DRIVER_PREFER_PKG=false
GL_HEADERS_PKG="linux-headers-$(uname -r)"
GL_HEADERS_PKG_ALT=""

GL_TOOLS_CHECK_FIRST=true
GL_TOOLS_ALWAYS_INSTALL=false

GL_MGMT_TYPE="auto"

GL_HEADLESS_MODE="auto"
GL_DISABLE_DISPLAY=false

# TEMPLATE NOTE: The following steps are NOT fully tested on generic Debian.
# Before enabling production use, verify:
# - apt repository availability of pentest tools
# - DKMS kernel header naming
# - systemd service behavior
# - Network interface naming conventions
GL_OS_TEMPLATE_ONLY=true
