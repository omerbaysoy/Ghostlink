#!/usr/bin/env bash
# Hardware and OS detection helpers

# ── OS Detection ──────────────────────────────────────────────────────────────

# Returns: rpi-bookworm | rpi-trixie | dietpi | kali | debian | ubuntu | unknown
detect_os() {
    local id="" codename="" id_like=""
    if [[ -f /etc/os-release ]]; then
        id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | xargs)
        codename=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"' | xargs)
        id_like=$(grep "^ID_LIKE=" /etc/os-release | cut -d= -f2 | tr -d '"' | xargs)
    fi

    # DietPi first — it identifies as debian/raspbian underneath
    if [[ -f /etc/dietpi/.installed ]] || [[ -f /etc/dietpi/dietpi.txt ]]; then
        echo "dietpi"; return
    fi

    # Kali
    if [[ "$id" == "kali" ]]; then
        echo "kali"; return
    fi

    # Raspberry Pi OS: 32-bit uses ID=raspbian, 64-bit uses ID=debian but has RPi hw
    if [[ "$id" == "raspbian" ]] || { [[ "$id" == "debian" ]] && is_rpi; }; then
        case "$codename" in
            trixie)   echo "rpi-trixie" ;;
            *)        echo "rpi-bookworm" ;;
        esac
        return
    fi

    # Ubuntu
    if [[ "$id" == "ubuntu" ]]; then
        echo "ubuntu"; return
    fi

    # Generic Debian or Debian-based
    if [[ "$id" == "debian" ]] || [[ "$id_like" == *"debian"* ]]; then
        echo "debian"; return
    fi

    echo "unknown"
}

os_pretty() {
    case "${1:-$(detect_os)}" in
        rpi-bookworm) echo "Raspberry Pi OS Bookworm (64-bit)" ;;
        rpi-trixie)   echo "Raspberry Pi OS Trixie (64-bit)" ;;
        dietpi)       echo "DietPi" ;;
        kali)         echo "Kali Linux" ;;
        debian)       echo "Debian" ;;
        ubuntu)       echo "Ubuntu" ;;
        *)            echo "Unknown OS" ;;
    esac
}

# ── Hardware Detection ────────────────────────────────────────────────────────

is_rpi() {
    [[ -f /proc/device-tree/model ]] && grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null && return 0
    grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null
}

is_rpi5() {
    [[ -f /proc/device-tree/model ]] && grep -q "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null && return 0
    grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null
}

has_nvme() {
    [[ -b /dev/nvme0n1 ]] || lsblk -d -o NAME 2>/dev/null | grep -q "^nvme"
}

usb_wifi_count() {
    lsusb 2>/dev/null | grep -cE "Realtek|Ralink|Atheros|MediaTek|NETGEAR|TP-LINK|Edimax|D-Link|ALFA" || echo 0
}

# True if the given interface is attached via USB
is_usb_iface() {
    local iface="$1"
    readlink -f /sys/class/net/"$iface"/device 2>/dev/null | grep -q "/usb[0-9]"
}

# ── Chipset / Driver Detection ────────────────────────────────────────────────

chipset_for_usb_id() {
    local usb_id="$1"
    local src
    if [[ -f /etc/ghostlink/sources.conf ]]; then
        src=/etc/ghostlink/sources.conf
    else
        src="$(dirname "${BASH_SOURCE[0]}")/../../config/sources.conf"
    fi
    # shellcheck source=/dev/null
    source "$src" 2>/dev/null || return 1

    for id in $DRIVER_RTL8812AU_USB_IDS;  do [[ "$usb_id" == "$id" ]] && echo "rtl8812au"  && return; done
    for id in $DRIVER_RTL88X2BU_USB_IDS;  do [[ "$usb_id" == "$id" ]] && echo "rtl88x2bu"  && return; done
    for id in $DRIVER_RTL8188EUS_USB_IDS; do [[ "$usb_id" == "$id" ]] && echo "rtl8188eus" && return; done
    echo "unknown"
}

detected_chipsets() {
    local chipsets=()
    while IFS= read -r line; do
        local usb_id
        usb_id=$(echo "$line" | grep -oE '[0-9a-f]{4}:[0-9a-f]{4}')
        [[ -z "$usb_id" ]] && continue
        local chip
        chip=$(chipset_for_usb_id "$usb_id")
        [[ "$chip" != "unknown" ]] && chipsets+=("$chip")
    done < <(lsusb 2>/dev/null)
    printf '%s\n' "${chipsets[@]}" | sort -u
}

# True if the kernel module is loaded and has at least one live interface
driver_functional() {
    local module="$1"
    lsmod 2>/dev/null | grep -q "^${module}[[:space:]]" || return 1
    for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
        local drv
        drv=$(readlink -f /sys/class/net/"$iface"/device/driver 2>/dev/null | xargs basename 2>/dev/null)
        [[ "$drv" == "$module" ]] && return 0
    done
    return 1
}

# True if ANY interface driven by this module reports monitor mode capability
module_has_monitor() {
    local module="$1"
    for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
        local drv phy
        drv=$(readlink -f /sys/class/net/"$iface"/device/driver 2>/dev/null | xargs basename 2>/dev/null)
        [[ "$drv" == "$module" ]] || continue
        phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
        iw phy "$phy" info 2>/dev/null | grep -q "monitor" && return 0
    done
    return 1
}

# True if iface supports monitor mode
supports_monitor() {
    local iface="$1"
    local phy
    phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
    iw phy "$phy" info 2>/dev/null | grep -q "monitor"
}

# True if iface supports AP mode
supports_ap() {
    local iface="$1"
    local phy
    phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
    iw phy "$phy" info 2>/dev/null | grep -q " AP$\| AP "
}

# First non-USB WiFi interface (works on RPi, laptops, etc.)
onboard_interface() {
    for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
        is_usb_iface "$iface" || { echo "$iface"; return; }
    done
}

# True if a binary is on PATH (fast tool presence check)
tool_exists() {
    command -v "$1" &>/dev/null
}
