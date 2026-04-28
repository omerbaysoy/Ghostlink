#!/usr/bin/env bash
# Hardware and chipset detection helpers

is_rpi5() {
    grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null
}

has_nvme() {
    [[ -b /dev/nvme0n1 ]] || lsblk | grep -q nvme
}

usb_wifi_count() {
    lsusb | grep -cE "Realtek|Ralink|Atheros|MediaTek" || true
}

# Returns chipset name for a given USB ID (vendor:product)
# Usage: chipset_for_usb_id "0bda:8812"
chipset_for_usb_id() {
    local usb_id="$1"
    source "${GHOSTLINK_CONF:-/etc/ghostlink}/sources.conf" 2>/dev/null || \
        source "$(dirname "${BASH_SOURCE[0]}")/../../config/sources.conf"

    for id in $DRIVER_RTL8812AU_USB_IDS;  do [[ "$usb_id" == "$id" ]] && echo "rtl8812au"  && return; done
    for id in $DRIVER_RTL88X2BU_USB_IDS;  do [[ "$usb_id" == "$id" ]] && echo "rtl88x2bu"  && return; done
    for id in $DRIVER_RTL8188EUS_USB_IDS; do [[ "$usb_id" == "$id" ]] && echo "rtl8188eus" && return; done
    echo "unknown"
}

# Returns space-separated list of detected chipsets from lsusb
detected_chipsets() {
    local chipsets=()
    while IFS= read -r line; do
        local usb_id
        usb_id=$(echo "$line" | grep -oE '[0-9a-f]{4}:[0-9a-f]{4}')
        [[ -z "$usb_id" ]] && continue
        local chip
        chip=$(chipset_for_usb_id "$usb_id")
        [[ "$chip" != "unknown" ]] && chipsets+=("$chip")
    done < <(lsusb)
    printf '%s\n' "${chipsets[@]}" | sort -u
}

# Check if interface supports monitor mode
supports_monitor() {
    local iface="$1"
    iw phy "$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')" info 2>/dev/null \
        | grep -q "monitor"
}

# Check if interface supports AP mode
supports_ap() {
    local iface="$1"
    iw phy "$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')" info 2>/dev/null \
        | grep -q "AP"
}

# Returns onboard interface name (BCM chip, not USB)
onboard_interface() {
    for iface in $(iw dev | awk '/Interface/{print $2}'); do
        local driver
        driver=$(readlink -f /sys/class/net/"$iface"/device/driver 2>/dev/null | xargs basename 2>/dev/null)
        [[ "$driver" == "brcmfmac" ]] && echo "$iface" && return
    done
}
