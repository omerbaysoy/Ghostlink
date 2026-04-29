#!/usr/bin/env bash
# GhostLink Tool Registry
# Provides: ghostlink tools list / info / run / doctor wifite

REPO="${GHOSTLINK_BASE:-/opt/ghostlink}"
CONF="${GHOSTLINK_CONF:-/etc/ghostlink}/ghostlink.conf"
TOOLS_LOG_DIR="/var/log/ghostlink/tools"

# Tool definition format: NAME|BINARY|PACKAGE|CATEGORY|DESCRIPTION|WORKFLOW
_TOOL_DEFS=(
    # ── Wireless ──────────────────────────────────────────────────────────────
    "aircrack-ng|aircrack-ng|aircrack-ng|wireless|WPA/WEP key recovery from captured handshakes|handshake-crack"
    "airodump-ng|airodump-ng|aircrack-ng|wireless|802.11 packet capture and network scanner|scan"
    "aireplay-ng|aireplay-ng|aircrack-ng|wireless|802.11 packet injection and deauthentication|deauth"
    "airmon-ng|airmon-ng|aircrack-ng|wireless|Monitor mode management — prefer ghostlink upstream monitor|monitor"
    "hcxdumptool|hcxdumptool|hcxdumptool|wireless|PMKID and EAPOL handshake capture tool|pmkid-capture"
    "hcxpcapngtool|hcxpcapngtool|hcxtools|wireless|Convert PCAPNG captures to hashcat format|pmkid-convert"
    "reaver|reaver|reaver|wireless|WPS brute-force attack tool|wps"
    "bully|bully|bully|wireless|WPS brute-force (alternative to reaver)|wps"
    "wifite|wifite|wifite2|wireless|Automated wireless attack suite — use ghostlink tools run wifite|managed"
    "bettercap|bettercap|bettercap|wireless|Network attack and MITM framework (optional)|optional"
    "hashcat|hashcat|hashcat|wireless|GPU/CPU password hash cracker|handshake-crack"
    "macchanger|macchanger|macchanger|wireless|MAC address spoofer — use ghostlink identity rotate|identity"
    # ── Network Discovery ─────────────────────────────────────────────────────
    "nmap|nmap|nmap|network-discovery|Network and port scanner|host-discovery"
    "arp-scan|arp-scan|arp-scan|network-discovery|ARP-based host discovery on local subnets|host-discovery"
    "netdiscover|netdiscover|netdiscover|network-discovery|Passive/active ARP host discovery|host-discovery"
    # ── Network Diagnostics ───────────────────────────────────────────────────
    "tcpdump|tcpdump|tcpdump|network-diagnostics|Command-line packet capture|capture"
    "iperf3|iperf3|iperf3|network-diagnostics|Network bandwidth measurement|throughput"
    "mtr|mtr|mtr|network-diagnostics|Traceroute with continuous ping statistics|path-trace"
    "traceroute|traceroute|traceroute|network-diagnostics|Classic network path tracer|path-trace"
    "dig|dig|dnsutils|network-diagnostics|DNS lookup tool|dns"
    "whois|whois|whois|network-diagnostics|WHOIS domain/IP registry query|osint"
    "ethtool|ethtool|ethtool|network-diagnostics|NIC/Ethernet adapter diagnostics|diagnostics"
    # ── System / Adapter ──────────────────────────────────────────────────────
    "iw|iw|iw|system|Wireless interface configuration tool|management"
    "iwconfig|iwconfig|wireless-tools|system|Legacy wireless configuration|management"
    "rfkill|rfkill|rfkill|system|RF killswitch management|management"
    "lsusb|lsusb|usbutils|system|USB device lister|diagnostics"
)

# ── Helper: find entry by tool name ─────────────────────────────────────────────
_find_tool() {
    local name="${1,,}"
    for entry in "${_TOOL_DEFS[@]}"; do
        local tname="${entry%%|*}"
        [[ "${tname,,}" == "$name" ]] && echo "$entry" && return 0
    done
    return 1
}

# ── Helper: resolve wifite binary (venv preferred, then system) ─────────────────
_wifite_bin() {
    if [[ -f "$REPO/venv/bin/wifite" ]]; then
        echo "$REPO/venv/bin/wifite"
    elif command -v wifite &>/dev/null; then
        command -v wifite
    else
        echo ""
    fi
}

# ── cmd_list ─────────────────────────────────────────────────────────────────────
cmd_list() {
    local filter_cat="${1:-}"
    local prev_cat=""

    echo ""
    echo "  GhostLink Tool Registry"
    echo "  ════════════════════════════════════════════════════════════════"
    printf "  %-18s %-12s %-20s %s\n" "Tool" "Category" "Status" "Package"
    echo "  ────────────────────────────────────────────────────────────────"

    for entry in "${_TOOL_DEFS[@]}"; do
        IFS='|' read -r tname binary pkg cat desc workflow <<< "$entry"
        [[ -n "$filter_cat" && "$cat" != "$filter_cat" ]] && continue

        if [[ "$cat" != "$prev_cat" ]]; then
            echo ""
            case "$cat" in
                wireless)           echo "  ── Wireless ─────────────────────────────────────────────────────" ;;
                network-discovery)  echo "  ── Network Discovery ────────────────────────────────────────────" ;;
                network-diagnostics) echo "  ── Network Diagnostics ──────────────────────────────────────────" ;;
                system)             echo "  ── System / Adapter ─────────────────────────────────────────────" ;;
            esac
            prev_cat="$cat"
        fi

        local status path
        if command -v "$binary" &>/dev/null; then
            path=$(command -v "$binary")
            status="installed"
        elif [[ "$tname" == "wifite" && -n "$(_wifite_bin)" ]]; then
            path=$(_wifite_bin)
            status="installed"
        else
            status="missing"
            path="(not found)"
        fi

        printf "  %-18s %-12s %-20s %s\n" "$tname" "$status" "$path" "($pkg)"
    done

    echo ""
    echo "  ── Legend ───────────────────────────────────────────────────────"
    echo "  ghostlink tools info <tool>          Show details and examples"
    echo "  ghostlink tools run <tool> -- <args> Run tool (preserves native behavior)"
    echo "  ghostlink tools doctor wifite        Check wifite prerequisites"
    echo ""
}

# ── cmd_info ─────────────────────────────────────────────────────────────────────
cmd_info() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Usage: ghostlink tools info <tool>"
        exit 1
    fi

    local entry
    if ! entry=$(_find_tool "$name"); then
        echo "  [tools] Unknown tool: $name"
        echo "  Run: ghostlink tools list"
        exit 1
    fi

    IFS='|' read -r tname binary pkg cat desc workflow <<< "$entry"

    local status path version
    if command -v "$binary" &>/dev/null; then
        path=$(command -v "$binary")
        status="installed"
        version=$("$binary" --version 2>&1 | head -1 || echo "n/a")
    elif [[ "$tname" == "wifite" ]]; then
        local wb
        wb=$(_wifite_bin)
        if [[ -n "$wb" ]]; then
            path="$wb"
            status="installed"
            version=$("$wb" --version 2>&1 | head -1 || echo "n/a")
        else
            path="(not found)"
            status="missing"
            version="n/a"
        fi
    else
        path="(not found)"
        status="missing"
        version="n/a"
    fi

    echo ""
    echo "  ── Tool: $tname ──────────────────────────────────────────────────"
    echo "  Binary      : $binary"
    echo "  Package     : $pkg"
    echo "  Category    : $cat"
    echo "  Status      : $status"
    echo "  Path        : $path"
    echo "  Version     : $version"
    echo "  Description : $desc"
    echo "  Workflow    : $workflow"
    echo ""

    # Print tool-specific examples
    case "$tname" in
        nmap)
            echo "  Examples:"
            echo "    ghostlink tools run nmap -- -sV -p 22,80,443 192.168.50.0/24"
            echo "    ghostlink tools run nmap -- -sn 192.168.50.0/24"
            echo "    sudo nmap -sV <target>   (native, also works)"
            ;;
        arp-scan)
            echo "  Examples:"
            echo "    ghostlink tools run arp-scan -- --interface=gl-hotspot --localnet"
            echo "    sudo arp-scan -l           (native)"
            ;;
        aircrack-ng)
            echo "  Examples:"
            echo "    ghostlink tools run aircrack-ng -- -w /opt/ghostlink/wordlists/rockyou.txt capture.cap"
            echo "    sudo aircrack-ng -w rockyou.txt capture.cap   (native)"
            ;;
        airodump-ng)
            echo "  Examples:"
            echo "    ghostlink tools run airodump-ng -- gl-upstream"
            echo "    sudo airodump-ng gl-upstream   (native)"
            ;;
        hcxdumptool)
            echo "  Examples:"
            echo "    ghostlink tools run hcxdumptool -- -i gl-upstream -o capture.pcapng --enable_status=3"
            echo "    sudo hcxdumptool -i gl-upstream -o out.pcapng   (native)"
            ;;
        reaver)
            echo "  Examples:"
            echo "    ghostlink tools run reaver -- -i gl-upstream -b <bssid> -vv"
            echo "    sudo reaver -i gl-upstream -b AA:BB:CC:DD:EE:FF -vv   (native)"
            ;;
        bully)
            echo "  Examples:"
            echo "    ghostlink tools run bully -- -b <bssid> -c <channel> gl-upstream"
            echo "    sudo bully -b AA:BB:CC:DD:EE:FF -c 6 gl-upstream   (native)"
            ;;
        wifite)
            echo "  Examples:"
            echo "    ghostlink tools run wifite -- --wpa --dict /opt/ghostlink/wordlists/rockyou.txt"
            echo "    ghostlink pentest wifi        (managed launch, safety checks)"
            echo "    sudo wifite                   (native — may mis-handle gl-* interfaces)"
            echo ""
            echo "  NOTE: Use 'ghostlink tools run wifite' or 'ghostlink pentest wifi' for"
            echo "        management-safe interface selection and monitor mode handling."
            ;;
        hashcat)
            echo "  Examples:"
            echo "    ghostlink tools run hashcat -- -m 22000 hash.hc22000 rockyou.txt"
            echo "    sudo hashcat -m 22000 capture.hc22000 rockyou.txt   (native)"
            ;;
        tcpdump)
            echo "  Examples:"
            echo "    ghostlink tools run tcpdump -- -i gl-upstream -w /tmp/capture.pcap"
            echo "    sudo tcpdump -i gl-upstream   (native)"
            ;;
        mtr)
            echo "  Examples:"
            echo "    ghostlink tools run mtr -- --report 8.8.8.8"
            echo "    sudo mtr 8.8.8.8   (native)"
            ;;
        netdiscover)
            echo "  Examples:"
            echo "    ghostlink tools run netdiscover -- -i gl-hotspot -r 192.168.50.0/24"
            echo "    sudo netdiscover -i gl-hotspot -r 192.168.50.0/24   (native)"
            ;;
        *)
            echo "  Run: $binary --help"
            ;;
    esac
    echo ""
}

# ── cmd_run ───────────────────────────────────────────────────────────────────────
cmd_run() {
    local name="${1:-}"
    shift || true

    if [[ -z "$name" ]]; then
        echo "Usage: ghostlink tools run <tool> -- <args...>"
        exit 1
    fi

    # Consume the optional -- separator
    if [[ "${1:-}" == "--" ]]; then shift; fi

    # Special case: wifite → safe wrapper
    if [[ "${name,,}" == "wifite" ]]; then
        bash "$REPO/pentest/wifite_wrapper.sh" "$@"
        return
    fi

    local entry
    if ! entry=$(_find_tool "$name"); then
        echo "  [tools] Unknown tool: $name — run 'ghostlink tools list'"
        exit 1
    fi

    IFS='|' read -r tname binary pkg cat desc workflow <<< "$entry"

    # Resolve binary path
    local bin_path=""
    if command -v "$binary" &>/dev/null; then
        bin_path=$(command -v "$binary")
    else
        echo "  [tools] $tname is not installed."
        echo "  Install: apt-get install -y $pkg"
        exit 1
    fi

    # Log invocation
    mkdir -p "$TOOLS_LOG_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $tname $*" >> "$TOOLS_LOG_DIR/tool_runs.log" 2>/dev/null || true

    # Execute natively — full control preserved
    exec "$bin_path" "$@"
}

# ── cmd_doctor_wifite ─────────────────────────────────────────────────────────────
cmd_doctor_wifite() {
    echo ""
    echo "  ── Wifite Prerequisites Check ────────────────────────────────────"

    local fail=0

    # 1. Wifite binary
    local wb
    wb=$(_wifite_bin)
    if [[ -n "$wb" ]]; then
        local ver
        ver=$("$wb" --version 2>&1 | head -1 || echo "unknown version")
        echo "  wifite         : OK ($wb — $ver)"
    else
        echo "  wifite         : MISSING — run: ghostlink update-tools"
        fail=1
    fi

    # 2. Aircrack suite
    for bin in aircrack-ng airodump-ng aireplay-ng airmon-ng; do
        if command -v "$bin" &>/dev/null; then
            echo "  $bin       : OK ($(command -v "$bin"))"
        else
            echo "  $bin       : MISSING"
            fail=1
        fi
    done

    # 3. hcxdumptool
    if command -v hcxdumptool &>/dev/null; then
        echo "  hcxdumptool    : OK"
    else
        echo "  hcxdumptool    : MISSING (optional but recommended)"
    fi

    # 4. Interface candidates
    echo ""
    echo "  ── Interface candidates (upstream / aux) ─────────────────────────"
    local has_candidate=0
    for role in gl-upstream gl-aux; do
        local actual_iface
        actual_iface=$(grep "^${role}=" /var/lib/ghostlink/interfaces.map 2>/dev/null | cut -d= -f2 || echo "")
        [[ -z "$actual_iface" ]] && actual_iface="$role"

        if ip link show "$actual_iface" &>/dev/null 2>&1; then
            local driver
            driver=$(basename "$(readlink -f "/sys/class/net/$actual_iface/device/driver" 2>/dev/null)" 2>/dev/null || echo "n/a")
            local phy
            phy=$(iw dev "$actual_iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
            local mon_cap="no"
            if [[ -n "$phy" ]]; then
                iw phy "$phy" info 2>/dev/null | grep -qiE '^\s+\* monitor' && mon_cap="yes"
            fi
            local ssid
            ssid=$(iwgetid "$actual_iface" -r 2>/dev/null || echo "")
            local connected_note=""
            [[ -n "$ssid" ]] && connected_note=" (connected: $ssid)"
            echo "  $role → $actual_iface  driver=$driver  monitor=$mon_cap$connected_note"
            [[ "$mon_cap" == "yes" ]] && has_candidate=1
        else
            echo "  $role             : NOT PRESENT"
        fi
    done

    echo ""
    if [[ $fail -eq 0 && $has_candidate -eq 1 ]]; then
        echo "  Result : OK — wifite is ready for managed launch"
        echo "  Run   : ghostlink pentest wifi"
    elif [[ $has_candidate -eq 0 ]]; then
        echo "  Result : NO monitor-capable interface found"
        echo "  Fix   : ghostlink drivers fix rtl8812au"
        exit 1
    else
        echo "  Result : Some prerequisites missing — see above"
        exit 1
    fi
    echo ""
}

# ── Dispatch ─────────────────────────────────────────────────────────────────────
case "${1:-list}" in
    list)         shift; cmd_list "${@:-}"        ;;
    info)         shift; cmd_info "${@:-}"         ;;
    run)          shift; cmd_run  "${@:-}"         ;;
    doctor)
        shift
        sub="${1:-wifite}"; shift || true
        case "$sub" in
            wifite) cmd_doctor_wifite ;;
            *)      echo "Usage: ghostlink tools doctor wifite" ;;
        esac
        ;;
    *)
        echo "Usage: ghostlink tools {list|info <tool>|run <tool> -- <args>|doctor wifite}"
        ;;
esac
