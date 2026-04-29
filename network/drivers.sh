#!/usr/bin/env bash
# RTL8812AU driver audit, fix, WiFi health check, and monitor mode test
# Usage: drivers.sh {status|audit|fix-rtl8812au [--force]|wifi-doctor|monitor-test [iface]}

set -euo pipefail

REPO="/opt/ghostlink"
CONF="/etc/ghostlink/ghostlink.conf"
MAP_FILE="/var/lib/ghostlink/interfaces.map"

source "$REPO/identity/mgmt_guard.sh" 2>/dev/null || true

# ── Constants ─────────────────────────────────────────────────────────────────

RTL8812AU_MODS=(88XXau 8812au rtl8812au)
RTL88X2BU_MODS=(88x2bu rtl88x2bu)
RTL8188EUS_MODS=(8188eu r8188eu rtl8188eus)
CONFLICT_MODS=(rtl8xxxu rtw88_8812au rtw88_usb rtw88_8822bu)

RTL8812AU_IDS=(0bda:8812 0bda:881a 0bda:8811 2357:0101 2357:0103 0bda:a811)
RTL88X2BU_IDS=(0bda:b812 0bda:b820 0bda:b82c 2001:331e 0bda:c820)
RTL8188EUS_IDS=(0bda:8179 0bda:8178 0bda:817e 0bda:0179 2001:3311 2357:010c)

log()      { echo "  [drivers] $*"; }
log_ok()   { echo "  [drivers] ✓ $*"; }
log_err()  { echo "  [drivers] ✗ $*" >&2; }
log_warn() { echo "  [drivers] ⚠ $*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

resolve_role() {
    local role="gl-${1#gl-}"
    if [[ -f "$MAP_FILE" ]]; then
        local val
        val=$(grep "^${role}=" "$MAP_FILE" 2>/dev/null | cut -d= -f2)
        [[ -n "$val" ]] && echo "$val" && return
    fi
    [[ -d "/sys/class/net/$role" ]] && echo "$role" && return
    echo ""
}

iface_driver() {
    local iface="$1"
    local drv_link="/sys/class/net/$iface/device/driver"
    [[ -L "$drv_link" ]] || { echo "unknown"; return; }
    basename "$(readlink -f "$drv_link")"
}

iface_usb_id() {
    local iface="$1"
    local dev_path curr
    dev_path=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || echo "")
    curr="$dev_path"
    while [[ "$curr" != "/" && -n "$curr" ]]; do
        if [[ -f "$curr/idVendor" && -f "$curr/idProduct" ]]; then
            local vid pid
            vid=$(tr -d '[:space:]' < "$curr/idVendor")
            pid=$(tr -d '[:space:]' < "$curr/idProduct")
            echo "${vid}:${pid}"
            return
        fi
        curr=$(dirname "$curr")
    done
    echo ""
}

iface_phy() {
    local iface="$1"
    iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}' | head -1
}

phy_supports_monitor() {
    local phy="$1"
    [[ -z "$phy" ]] && return 1
    iw phy "$phy" info 2>/dev/null | awk '
        /Supported interface modes:/{f=1; next}
        f && /\* monitor/{ok=1}
        f && /Supported commands:/{f=0}
        END{exit ok ? 0 : 1}
    '
}

phy_supports_ap() {
    local phy="$1"
    [[ -z "$phy" ]] && return 1
    iw phy "$phy" info 2>/dev/null | awk '
        /Supported interface modes:/{f=1; next}
        f && /\* AP/{ok=1}
        f && /Supported commands:/{f=0}
        END{exit ok ? 0 : 1}
    '
}

mod_loaded() {
    lsmod 2>/dev/null | grep -q "^${1}[[:space:]]"
}

first_loaded_mod() {
    local mods=("$@")
    for m in "${mods[@]}"; do
        mod_loaded "$m" && echo "$m" && return
    done
    echo ""
}

usb_detected() {
    local ids=("$@")
    for id in "${ids[@]}"; do
        local vid="${id%%:*}" pid="${id##*:}"
        lsusb 2>/dev/null | grep -qi "ID ${vid}:${pid}" && return 0
    done
    return 1
}

# ── Command: status ───────────────────────────────────────────────────────────

cmd_status() {
    echo ""
    echo "  Driver Status"
    echo "  ──────────────────────────────────────────────────────"

    for role_spec in "mgmt:brcmfmac" "upstream:88XXau/8812au" "hotspot:88x2bu" "aux:8188eu"; do
        local role="${role_spec%%:*}"
        local expected="${role_spec##*:}"
        local actual driver loaded_mod

        actual=$(resolve_role "$role")

        if [[ -n "$actual" && -d "/sys/class/net/$actual" ]]; then
            driver=$(iface_driver "$actual")
            case "$role" in
                upstream) loaded_mod=$(first_loaded_mod "${RTL8812AU_MODS[@]}") ;;
                hotspot)  loaded_mod=$(first_loaded_mod "${RTL88X2BU_MODS[@]}") ;;
                aux)      loaded_mod=$(first_loaded_mod "${RTL8188EUS_MODS[@]}") ;;
                mgmt)     mod_loaded brcmfmac && loaded_mod=brcmfmac || loaded_mod="" ;;
            esac
            printf "  %-12s → %-10s  driver=%-12s  expected=%-14s  module=%s\n" \
                "gl-$role" "$actual" "$driver" "$expected" "${loaded_mod:-(none)}"
        else
            printf "  %-12s → %-10s  (interface not found)\n" "gl-$role" "${actual:-(none)}"
        fi
    done

    echo ""
    echo "  Conflicting modules:"
    local found_conflict=false
    for m in "${CONFLICT_MODS[@]}"; do
        if mod_loaded "$m"; then
            log_warn "  LOADED: $m (conflicts with 88XXau/88x2bu)"
            found_conflict=true
        fi
    done
    $found_conflict || log_ok "  No conflicting modules loaded"
    echo ""
}

# ── Command: audit ────────────────────────────────────────────────────────────

cmd_audit() {
    echo ""
    echo "  RTL8812AU / WiFi Driver Audit"
    echo "  ══════════════════════════════════════════════════════"

    echo ""
    echo "  ── USB WiFi Adapters ─────────────────────────────────"
    lsusb 2>/dev/null | grep -iE "0bda|2357|realtek|tp-link" || echo "  (none detected)"

    echo ""
    echo "  ── RTL8812AU (gl-upstream / pentest) ─────────────────"

    local upstream_actual
    upstream_actual=$(resolve_role upstream)

    if usb_detected "${RTL8812AU_IDS[@]}"; then
        log_ok "RTL8812AU USB adapter detected on USB bus"
    else
        log_warn "RTL8812AU NOT detected on USB bus"
        log "  Expected USB IDs: ${RTL8812AU_IDS[*]}"
    fi

    echo ""
    if [[ -n "$upstream_actual" && -d "/sys/class/net/$upstream_actual" ]]; then
        local driver usb_id phy mode
        driver=$(iface_driver "$upstream_actual")
        usb_id=$(iface_usb_id "$upstream_actual")
        phy=$(iface_phy "$upstream_actual")
        mode=$(iw dev "$upstream_actual" info 2>/dev/null | awk '/type/{print $2}' || echo "unknown")

        echo "  Interface    : $upstream_actual"
        echo "  Driver       : $driver"
        echo "  USB ID       : ${usb_id:-(none)}"
        echo "  phy          : ${phy:-(none)}"
        echo "  Current mode : $mode"

        if [[ -n "$phy" ]]; then
            local mon_cap ap_cap
            phy_supports_monitor "$phy" && mon_cap="YES" || mon_cap="NO"
            phy_supports_ap "$phy"      && ap_cap="YES"  || ap_cap="NO"
            echo "  Monitor cap  : $mon_cap"
            echo "  AP cap       : $ap_cap"
        fi

        if [[ -L "/sys/class/net/$upstream_actual/device/driver" ]]; then
            echo "  Driver sysfs : $(readlink -f "/sys/class/net/$upstream_actual/device/driver")"
        fi

        if command -v ethtool &>/dev/null; then
            echo ""
            echo "  ethtool -i:"
            ethtool -i "$upstream_actual" 2>/dev/null | awk '{print "    "$0}' || echo "    (unavailable)"
        fi
    else
        log_warn "gl-upstream interface not found (map: ${upstream_actual:-(none)})"
        log "  Plug in RTL8812AU adapter and run: ghostlink interfaces roles"
    fi

    echo ""
    echo "  ── Loaded Module ─────────────────────────────────────"
    local loaded_mod
    loaded_mod=$(first_loaded_mod "${RTL8812AU_MODS[@]}")
    if [[ -n "$loaded_mod" ]]; then
        log_ok "Module loaded: $loaded_mod"
        local ver src
        ver=$(modinfo "$loaded_mod" 2>/dev/null | awk '/^version:/{print $2}' | head -1)
        src=$(modinfo "$loaded_mod" 2>/dev/null | awk '/^filename:/{print $2}' | head -1)
        echo "  version  : ${ver:-(unknown)}"
        echo "  filename : ${src:-(unknown)}"
    else
        log_warn "No RTL8812AU module loaded (checked: ${RTL8812AU_MODS[*]})"
    fi

    echo ""
    echo "  ── DKMS Status ───────────────────────────────────────"
    dkms status 2>/dev/null | grep -iE "8812au|88xxau|rtl8812" | awk '{print "  "$0}' || \
        echo "  (no DKMS entry for RTL8812AU)"

    echo ""
    echo "  ── Conflicting Modules ───────────────────────────────"
    local conflict_found=false
    for m in "${CONFLICT_MODS[@]}"; do
        if mod_loaded "$m"; then
            log_warn "LOADED: $m — conflicts with 88XXau"
            conflict_found=true
        else
            echo "  not loaded : $m"
        fi
    done

    echo ""
    echo "  ── Other Adapters ────────────────────────────────────"
    for role_spec in "hotspot:RTL88x2BU" "aux:RTL8188EUS"; do
        local role chip actual drv
        role="${role_spec%%:*}"
        chip="${role_spec##*:}"
        actual=$(resolve_role "$role")
        if [[ -n "$actual" && -d "/sys/class/net/$actual" ]]; then
            drv=$(iface_driver "$actual")
            printf "  gl-%-10s  iface=%-10s  driver=%s\n" "$role" "$actual" "$drv"
        else
            printf "  gl-%-10s  iface=(none)\n" "$role"
        fi
    done

    echo ""
    echo "  ── Recommendation ────────────────────────────────────"
    _print_recommendation "$loaded_mod" "$upstream_actual" "$conflict_found"
    echo ""
}

_print_recommendation() {
    local loaded_mod="$1" upstream_actual="$2" conflict_found="$3"

    if [[ "$conflict_found" == "true" ]]; then
        log_warn "Conflicting in-tree Realtek modules are loaded."
        log "  Run: ghostlink drivers fix rtl8812au"
        log "  Or:  rmmod rtl8xxxu rtw88_8812au rtw88_usb 2>/dev/null; modprobe 88XXau"
        return
    fi

    if [[ -z "$loaded_mod" ]]; then
        log_err "No RTL8812AU module loaded."
        log "  Try: modprobe 88XXau  (if DKMS driver is installed)"
        log "  Or:  ghostlink drivers fix rtl8812au"
        return
    fi

    if [[ -z "$upstream_actual" || ! -d "/sys/class/net/$upstream_actual" ]]; then
        log_warn "Module $loaded_mod loaded but gl-upstream interface not found."
        log "  Plug in RTL8812AU adapter or check: ghostlink interfaces roles"
        return
    fi

    local phy
    phy=$(iface_phy "$upstream_actual")
    if [[ -n "$phy" ]] && phy_supports_monitor "$phy"; then
        log_ok "RTL8812AU driver ($loaded_mod) functional — monitor mode confirmed."
    else
        log_warn "RTL8812AU driver ($loaded_mod) loaded but monitor mode not confirmed."
        log "  Run: ghostlink drivers fix rtl8812au"
    fi
}

# ── Command: fix-rtl8812au ────────────────────────────────────────────────────

cmd_fix_rtl8812au() {
    local force="${1:-}"
    echo ""
    echo "  RTL8812AU Driver Fix"
    echo "  ─────────────────────────────────────────────"
    echo ""

    # Safety: verify management is still reachable
    local mgmt_actual mgmt_ip
    mgmt_actual=$(resolve_role mgmt)
    if [[ -n "$mgmt_actual" && -d "/sys/class/net/$mgmt_actual" ]]; then
        mgmt_ip=$(ip -4 addr show "$mgmt_actual" 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1];exit}')
        [[ -n "$mgmt_ip" ]] && log_ok "Management alive on $mgmt_actual ($mgmt_ip)"
    fi

    # Step 1: check current state
    local loaded_mod
    loaded_mod=$(first_loaded_mod "${RTL8812AU_MODS[@]}")
    local upstream_actual
    upstream_actual=$(resolve_role upstream)

    if [[ -n "$loaded_mod" && -n "$upstream_actual" && -d "/sys/class/net/$upstream_actual" ]]; then
        local phy
        phy=$(iface_phy "$upstream_actual")
        if [[ -n "$phy" ]] && phy_supports_monitor "$phy"; then
            log_ok "RTL8812AU driver ($loaded_mod) working with monitor mode"
            if [[ "$force" != "--force" ]]; then
                log "No fix needed. Use --force to reinstall anyway."
                echo ""
                return 0
            fi
            log "Reinstalling with --force..."
        fi
    fi

    # Step 2: remove conflicting modules (do not touch 8188eu or 88x2bu)
    log "Checking for conflicting modules..."
    for m in "${CONFLICT_MODS[@]}"; do
        if mod_loaded "$m"; then
            log "  Removing conflicting module: $m"
            rmmod "$m" 2>/dev/null || log_warn "  Could not rmmod $m (may be in use; will be blacklisted)"
        fi
    done

    # Step 3: unload current RTL8812AU module
    for m in "${RTL8812AU_MODS[@]}"; do
        if mod_loaded "$m"; then
            log "  Unloading: $m"
            rmmod "$m" 2>/dev/null || true
        fi
    done

    # Step 4: check DKMS state
    local dkms_installed=false
    local dkms_out
    dkms_out=$(dkms status 2>/dev/null | grep -iE "8812au|88xxau|rtl8812" || echo "")
    if echo "$dkms_out" | grep -q "installed"; then
        log_ok "DKMS driver already installed: $(echo "$dkms_out" | head -1)"
        dkms_installed=true
    elif [[ -n "$dkms_out" ]]; then
        log_warn "DKMS entry exists but not fully installed: $dkms_out"
    fi

    # Step 5: build DKMS driver if needed (or forced)
    if ! $dkms_installed || [[ "$force" == "--force" ]]; then
        log "Building RTL8812AU DKMS driver..."
        _build_rtl8812au_dkms || {
            log_err "Driver build failed — management access preserved"
            log_err "Check: dkms status && journalctl -b | grep -i dkms"
            echo ""
            return 1
        }
    fi

    # Step 6: write/refresh blacklist
    _write_rtl8812au_blacklist
    depmod -a 2>/dev/null || true

    # Step 7: load module
    log "Loading module..."
    local loaded=false
    for m in "${RTL8812AU_MODS[@]}"; do
        if modprobe "$m" 2>/dev/null; then
            log_ok "Module loaded: $m"
            loaded=true
            break
        fi
    done

    if ! $loaded; then
        log_err "Failed to load any RTL8812AU module"
        dkms status 2>/dev/null | awk '{print "  "$0}'
        echo ""
        return 1
    fi

    # Step 8: verify (allow 2s for udev to create interface)
    sleep 2
    upstream_actual=$(resolve_role upstream)
    if [[ -n "$upstream_actual" && -d "/sys/class/net/$upstream_actual" ]]; then
        local phy
        phy=$(iface_phy "$upstream_actual")
        if [[ -n "$phy" ]] && phy_supports_monitor "$phy"; then
            log_ok "Fix complete — monitor mode confirmed on $upstream_actual"
        else
            log_warn "Module loaded but monitor mode not confirmed on $upstream_actual"
            log "  Try: iw phy $phy info | grep -A20 'Supported interface modes'"
        fi
    else
        log_warn "Module loaded but gl-upstream interface not yet visible"
        log "  Unplug and replug the RTL8812AU adapter"
    fi
    echo ""
}

_build_rtl8812au_dkms() {
    local src_conf="$REPO/config/sources.conf"
    [[ -f "$src_conf" ]] || { log_err "sources.conf not found: $src_conf"; return 1; }

    # shellcheck source=/dev/null
    source "$src_conf"

    local url="${DRIVER_RTL8812AU_URL:-https://github.com/aircrack-ng/rtl8812au}"
    local branch="${DRIVER_RTL8812AU_BRANCH:-v5.6.4.2}"
    local dest="${GHOSTLINK_DRIVERS:-/opt/ghostlink/drivers}/rtl8812au"

    # Dependencies
    apt-get install -y -qq dkms git bc libelf-dev 2>/dev/null || true

    # Kernel headers
    local hdr_pkg="linux-headers-$(uname -r)"
    if ! dpkg -l "$hdr_pkg" 2>/dev/null | grep -q "^ii"; then
        log "  Installing kernel headers ($hdr_pkg)..."
        apt-get install -y -qq "$hdr_pkg" 2>/dev/null || \
            log_warn "  Could not install $hdr_pkg — DKMS build may fail"
    fi

    # Remove stale DKMS entries (RTL8812AU only — do not touch 8188eu, 88x2bu)
    for m in 88XXau 8812au rtl8812au; do
        local ver
        ver=$(dkms status 2>/dev/null | grep -iE "^${m}/" | awk -F'[/,]' '{print $2}' | head -1 | tr -d ' ')
        if [[ -n "$ver" ]]; then
            log "  Removing stale DKMS entry: $m/$ver"
            dkms remove "$m/$ver" --all 2>/dev/null || true
        fi
    done

    # Remove stale /usr/src entries (GhostLink-owned only — must have our Makefile marker)
    for d in /usr/src/8812au-* /usr/src/88XXau-* /usr/src/rtl8812au-*; do
        [[ -d "$d" ]] || continue
        if grep -q "CONFIG_PLATFORM" "$d/Makefile" 2>/dev/null; then
            log "  Removing stale /usr/src: $d"
            rm -rf "$d"
        fi
    done

    # Clone or update
    if [[ -d "$dest/.git" ]]; then
        log "  Updating existing clone: $dest"
        git -C "$dest" fetch -q origin "$branch" 2>/dev/null || true
        git -C "$dest" checkout -q "$branch" 2>/dev/null || true
        git -C "$dest" reset -q --hard "origin/$branch" 2>/dev/null || true
    else
        mkdir -p "$(dirname "$dest")"
        log "  Cloning $url (branch: $branch)..."
        git clone -q --depth 1 --branch "$branch" "$url" "$dest" || {
            log_err "  Clone failed — check network"
            return 1
        }
    fi

    # aarch64 / RPi 5 Makefile patch
    if [[ "$(uname -m)" == "aarch64" && -f "$dest/Makefile" ]]; then
        log "  Applying aarch64 RPi Makefile patch..."
        sed -i 's/^CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' "$dest/Makefile"
        sed -i 's/^CONFIG_PLATFORM_ARM64_RPI = n/CONFIG_PLATFORM_ARM64_RPI = y/' "$dest/Makefile"
    fi

    # Parse dkms.conf
    local mod_name mod_ver
    mod_name=$(grep "^PACKAGE_NAME"    "$dest/dkms.conf" 2>/dev/null | cut -d= -f2 | tr -d '"')
    mod_ver=$(grep  "^PACKAGE_VERSION" "$dest/dkms.conf" 2>/dev/null | cut -d= -f2 | tr -d '"')

    if [[ -z "$mod_name" || -z "$mod_ver" ]]; then
        log_err "  Cannot parse dkms.conf in $dest"
        return 1
    fi

    dkms add "$dest" 2>/dev/null || true
    dkms build "$mod_name/$mod_ver" || { log_err "  DKMS build failed for $mod_name/$mod_ver"; return 1; }
    dkms install "$mod_name/$mod_ver"
    log_ok "DKMS installed: $mod_name/$mod_ver"
}

_write_rtl8812au_blacklist() {
    cat > /etc/modprobe.d/ghostlink-realtek.conf <<'CONF'
# Ghostlink Realtek USB WiFi policy
# Blacklist in-tree drivers that conflict with the DKMS monitor-capable drivers.
# Prevents rtl8xxxu/rtw88 from shadowing 88XXau (RTL8812AU) and 88x2bu (RTL88x2BU).
blacklist rtl8xxxu
blacklist rtw88_8822bu
blacklist rtw88_usb
blacklist rtw88_8812au
CONF
    log_ok "Conflict blacklist: /etc/modprobe.d/ghostlink-realtek.conf"
}

# ── Command: wifi-doctor ──────────────────────────────────────────────────────

cmd_wifi_doctor() {
    echo ""
    echo "  WiFi Interface Health"
    echo "  ══════════════════════════════════════════════════════"

    local all_ok=true

    for role_spec in "mgmt:management (SSH/control)" "upstream:pentest/upstream client" "hotspot:distribution AP" "aux:auxiliary/fallback"; do
        local role="${role_spec%%:*}"
        local desc="${role_spec##*:}"
        local actual driver phy state ip mode

        actual=$(resolve_role "$role")

        echo ""
        printf "  gl-%-10s  (%s)\n" "$role" "$desc"
        echo "  ─────────────────────────────────────────"

        if [[ -z "$actual" || ! -d "/sys/class/net/$actual" ]]; then
            log_err "Interface not found  (expected: ${actual:-(none in map)})"
            all_ok=false
            continue
        fi

        echo "  Interface : $actual"
        state=$(cat "/sys/class/net/$actual/operstate" 2>/dev/null || echo "unknown")
        echo "  State     : $state"

        driver=$(iface_driver "$actual")
        echo "  Driver    : $driver"

        ip=$(ip -4 addr show "$actual" 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1];exit}')
        [[ -n "$ip" ]] && echo "  IP        : $ip"

        phy=$(iface_phy "$actual")
        if [[ -n "$phy" ]]; then
            local mon_y ap_y
            phy_supports_monitor "$phy" && mon_y="yes" || { mon_y="NO"; [[ "$role" == "upstream" || "$role" == "aux" ]] && all_ok=false; }
            phy_supports_ap "$phy"      && ap_y="yes"  || ap_y="no"
            echo "  Monitor   : $mon_y"
            echo "  AP mode   : $ap_y"
        fi

        mode=$(iw dev "$actual" info 2>/dev/null | awk '/type/{print $2}')
        [[ -n "$mode" ]] && echo "  Mode      : $mode"

        if type is_protected_iface &>/dev/null; then
            if is_protected_iface "$actual" 2>/dev/null; then
                echo "  Protected : YES (management guard)"
            else
                echo "  Protected : no"
            fi
        fi
    done

    echo ""
    echo "  ── Conflicting modules ───────────────────────────────"
    local conflict_found=false
    for m in "${CONFLICT_MODS[@]}"; do
        if mod_loaded "$m"; then
            log_warn "LOADED (conflict): $m"
            conflict_found=true
            all_ok=false
        fi
    done
    $conflict_found || log_ok "No conflicting modules"

    echo ""
    if $all_ok; then
        log_ok "WiFi health check passed"
    else
        log_warn "Issues detected — run: ghostlink drivers audit  for full diagnostic"
        log "  RTL8812AU fix:  ghostlink drivers fix rtl8812au"
    fi
    echo ""
}

# ── Command: monitor-test ─────────────────────────────────────────────────────

cmd_monitor_test() {
    local target_iface="${1:-}"

    echo ""
    echo "  Monitor Mode Test"
    echo "  ─────────────────────────────────────────────"

    # Resolve interface
    local iface
    if [[ -n "$target_iface" ]]; then
        iface="$target_iface"
    else
        iface=$(resolve_role upstream)
        [[ -z "$iface" ]] && iface="gl-upstream"
    fi

    # Reject management interface by name
    if [[ "$iface" == "gl-mgmt" ]]; then
        log_err "REFUSED: will not test monitor mode on management interface (gl-mgmt)"
        return 1
    fi

    # Reject protected interfaces via mgmt_guard
    if type is_protected_iface &>/dev/null; then
        if is_protected_iface "$iface" 2>/dev/null; then
            log_err "REFUSED: $iface is protected (management guard)"
            log_err "Monitor mode test must not run on management/trusted interface"
            return 1
        fi
    fi

    # Reject if interface carries default route and not explicitly upstream/aux role
    local mgmt_actual
    mgmt_actual=$(resolve_role mgmt)
    if [[ -n "$mgmt_actual" && "$iface" == "$mgmt_actual" ]]; then
        log_err "REFUSED: $iface is the management interface ($mgmt_actual)"
        return 1
    fi

    if ! [[ -d "/sys/class/net/$iface" ]]; then
        log_err "Interface not found: $iface"
        return 1
    fi

    log "Testing monitor mode on: $iface"

    local prev_mode
    prev_mode=$(iw dev "$iface" info 2>/dev/null | awk '/type/{print $2}' || echo "managed")
    log "Previous mode: ${prev_mode:-(unknown)}"

    # Switch to monitor
    ip link set dev "$iface" down
    if ! iw dev "$iface" set type monitor 2>/dev/null; then
        log_err "Failed to switch $iface to monitor mode"
        ip link set dev "$iface" up 2>/dev/null || true
        return 1
    fi
    ip link set dev "$iface" up

    local mode
    mode=$(iw dev "$iface" info 2>/dev/null | awk '/type/{print $2}')
    if [[ "$mode" == "monitor" ]]; then
        log_ok "Monitor mode active on $iface"
    else
        log_err "Mode switch failed (current: ${mode:-(unknown)})"
    fi

    # Always restore to managed mode
    log "Restoring to managed mode..."
    ip link set dev "$iface" down
    iw dev "$iface" set type managed 2>/dev/null || true
    ip link set dev "$iface" up

    mode=$(iw dev "$iface" info 2>/dev/null | awk '/type/{print $2}')
    log_ok "Restored: $iface → ${mode:-(unknown)}"
    echo ""
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
    status)        cmd_status                             ;;
    audit)         cmd_audit                              ;;
    fix-rtl8812au) shift; cmd_fix_rtl8812au "${@:-}"     ;;
    wifi-doctor)   cmd_wifi_doctor                        ;;
    monitor-test)  shift; cmd_monitor_test "${1:-}"       ;;
    *)
        echo "Usage: drivers.sh {status|audit|fix-rtl8812au [--force]|wifi-doctor|monitor-test [iface]}" >&2
        exit 1
        ;;
esac
