#!/usr/bin/env bash
# Driver installation — OS-aware, smart (skips working drivers)
source "$(dirname "$0")/../lib/ui.sh"
source "$(dirname "$0")/../lib/detect.sh"
REPO_ROOT="${1:?}"
source "$REPO_ROOT/config/sources.conf"

# ── Detect chipsets present in USB bus ───────────────────────────────────────
gl_step "Detecting USB WiFi chipsets..."
mapfile -t chipsets < <(detected_chipsets)

if [[ ${#chipsets[@]} -eq 0 ]]; then
    gl_info "No known RTL chipsets found on USB bus"
    # On Kali this is expected if adapter is already enumerated under a different ID
    if [[ "${GL_OS:-}" == "kali" ]]; then
        gl_info "On Kali — checking for already-loaded RTL modules..."
        for mod in 88XXau 8812au rtl8812au rtl88x2bu 8188eu rtl8188eus; do
            if lsmod 2>/dev/null | grep -q "^${mod}[[:space:]]"; then
                gl_success "Module $mod already loaded — driver is functional"
            fi
        done
    fi
    gl_info "Driver installation step complete (nothing to install)"
    exit 0
fi

gl_success "Detected chipsets: ${chipsets[*]}"

# ── Realtek driver conflict blacklist ─────────────────────────────────────────
# CRITICAL (KROVEX lesson): in-tree Realtek drivers (rtl8xxxu, rtw88_*) can
# shadow our DKMS-built monitor-capable drivers. Blacklist them first.
write_realtek_blacklist() {
    cat > /etc/modprobe.d/ghostlink-realtek.conf <<'CONF'
# Ghostlink Realtek USB WiFi policy
# Blacklist in-tree drivers that conflict with the monitor-capable DKMS drivers.
# Prevents rtl8xxxu/rtw88 from shadowing 88XXau (RTL8812AU) and 88x2bu (RTL88x2BU).
blacklist rtl8xxxu
blacklist rtw88_8822bu
blacklist rtw88_usb
blacklist rtw88_8812au
CONF
    gl_success "Realtek conflict blacklist written: /etc/modprobe.d/ghostlink-realtek.conf"
}
write_realtek_blacklist

# ── Chipset → module name mapping ─────────────────────────────────────────────
module_for_chipset() {
    case "$1" in
        rtl8812au)  echo "88XXau" ;;    # aircrack-ng tree uses 88XXau
        rtl88x2bu)  echo "88x2bu" ;;
        rtl8188eus) echo "8188eu" ;;
        *)          echo "$1" ;;
    esac
}

# ── Check if driver is already working ────────────────────────────────────────
# RTL8812AU and RTL88x2BU: require monitor mode capability (pentest adapters).
# RTL8188EUS (gl-aux): require only functional driver + interface — monitor mode
# is a bonus, not a requirement (it's used for aux scan and fallback AP).
driver_works() {
    local chip="$1"
    local mod
    mod=$(module_for_chipset "$chip")

    # Check various module name variants
    for m in "$mod" "$chip" "${chip/rtl/}" "${chip/eus/eu}"; do
        if driver_functional "$m" 2>/dev/null; then
            if [[ "$chip" == "rtl8188eus" ]]; then
                return 0    # gl-aux: functional driver + interface is sufficient
            fi
            if module_has_monitor "$m" 2>/dev/null; then
                return 0    # pentest adapters: need monitor mode too
            fi
        fi
    done
    return 1
}

# ── Kali: try apt package before building from source ────────────────────────
try_apt_driver() {
    local chip="$1"
    case "$chip" in
        rtl8812au)
            for pkg in realtek-rtl88xxau-dkms rtl8812au-dkms; do
                if apt-cache show "$pkg" &>/dev/null 2>&1; then
                    gl_step "Installing $pkg from apt..."
                    ${GL_PKG_INSTALL:-apt-get install -y -qq} "$pkg" && return 0
                fi
            done
            ;;
        rtl88x2bu)
            for pkg in realtek-rtl88xxau-dkms rtl88x2bu-dkms; do
                if apt-cache show "$pkg" &>/dev/null 2>&1; then
                    gl_step "Installing $pkg from apt..."
                    ${GL_PKG_INSTALL:-apt-get install -y -qq} "$pkg" && return 0
                fi
            done
            ;;
        rtl8188eus)
            for pkg in realtek-rtl8188eus-dkms rtl8188eus-dkms; do
                if apt-cache show "$pkg" &>/dev/null 2>&1; then
                    gl_step "Installing $pkg from apt..."
                    ${GL_PKG_INSTALL:-apt-get install -y -qq} "$pkg" && return 0
                fi
            done
            ;;
    esac
    return 1
}

# ── Install kernel headers ────────────────────────────────────────────────────
install_headers() {
    local primary="${GL_HEADERS_PKG:-linux-headers-$(uname -r)}"
    local alt="${GL_HEADERS_PKG_ALT:-}"

    if dpkg -l "$primary" 2>/dev/null | grep -q "^ii"; then
        gl_info "Kernel headers already installed ($primary)"
        return 0
    fi

    gl_step "Installing kernel headers ($primary)..."
    if ${GL_PKG_INSTALL:-apt-get install -y -qq} "$primary" 2>/dev/null; then
        gl_success "Headers installed: $primary"
        return 0
    fi

    if [[ -n "$alt" ]]; then
        gl_step "Trying alternate headers package ($alt)..."
        if ${GL_PKG_INSTALL:-apt-get install -y -qq} "$alt" 2>/dev/null; then
            gl_success "Headers installed: $alt"
            return 0
        fi
    fi

    gl_error "Could not install kernel headers — DKMS build will fail"
    return 1
}

# ── Build and install via DKMS ────────────────────────────────────────────────
build_driver_dkms() {
    local name="$1" url="$2" branch="$3"
    local dest="$GHOSTLINK_DRIVERS/$name"

    # Install headers if not present
    install_headers || return 1

    ${GL_PKG_INSTALL:-apt-get install -y -qq} dkms git bc libelf-dev

    if [[ -d "$dest/.git" ]]; then
        gl_step "Updating existing $name clone..."
        git -C "$dest" fetch -q origin "$branch"
        git -C "$dest" checkout -q "$branch"
        git -C "$dest" reset -q --hard "origin/$branch"
    else
        mkdir -p "$GHOSTLINK_DRIVERS"
        gl_step "Cloning $name from $url (branch: $branch)..."
        git clone -q --depth 1 --branch "$branch" "$url" "$dest"
    fi

    # CRITICAL (KROVEX lesson): RTL8812AU aircrack-ng driver requires an explicit
    # aarch64/RPi platform flag in the Makefile. Without this the build either
    # fails or produces a broken module on RPi 5 (aarch64).
    if [[ "$name" == "rtl8812au" && "$(uname -m)" == "aarch64" && -f "$dest/Makefile" ]]; then
        gl_step "Applying aarch64 (RPi) Makefile patch for RTL8812AU..."
        sed -i 's/^CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' "$dest/Makefile"
        sed -i 's/^CONFIG_PLATFORM_ARM64_RPI = n/CONFIG_PLATFORM_ARM64_RPI = y/' "$dest/Makefile"
        gl_success "aarch64 Makefile patch applied"
    fi

    local mod_name mod_ver
    mod_name=$(grep "^PACKAGE_NAME"    "$dest/dkms.conf" 2>/dev/null | cut -d= -f2 | tr -d '"')
    mod_ver=$(grep  "^PACKAGE_VERSION" "$dest/dkms.conf" 2>/dev/null | cut -d= -f2 | tr -d '"')

    if [[ -z "$mod_name" || -z "$mod_ver" ]]; then
        gl_error "Could not parse dkms.conf in $dest"
        return 1
    fi

    dkms remove "$mod_name/$mod_ver" --all 2>/dev/null || true
    dkms add    "$dest"
    dkms build  "$mod_name/$mod_ver" || { gl_error "DKMS build failed for $name"; return 1; }
    dkms install "$mod_name/$mod_ver"

    gl_success "$name installed via DKMS (rebuilds on kernel upgrade)"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
for chip in "${chipsets[@]}"; do
    gl_step "Processing chipset: $chip"

    # Skip if driver already works
    if [[ "${GL_DRIVER_CHECK_FIRST:-true}" == "true" ]]; then
        if driver_works "$chip"; then
            if [[ "$chip" == "rtl8188eus" ]]; then
                gl_success "$chip driver already functional (gl-aux) — skipping installation"
            else
                gl_success "$chip driver already functional with monitor mode — skipping installation"
            fi
            continue
        fi
        if [[ "$chip" == "rtl8188eus" ]]; then
            gl_info "$chip driver not functional — installing (gl-aux / fallback AP)"
        else
            gl_info "$chip driver not functional or missing monitor mode — installing"
        fi
    fi

    # Kali: try apt package first (cleaner, system-integrated)
    if [[ "${GL_DRIVER_PREFER_PKG:-false}" == "true" ]]; then
        if try_apt_driver "$chip"; then
            gl_success "$chip installed via apt package"
            continue
        fi
        gl_info "No apt package for $chip — falling back to DKMS build"
    fi

    # Build from source via DKMS
    if [[ "${GL_DRIVER_BUILD_DKMS:-true}" == "true" ]]; then
        case "$chip" in
            rtl8812au)
                build_driver_dkms rtl8812au "$DRIVER_RTL8812AU_URL" "$DRIVER_RTL8812AU_BRANCH"
                ;;
            rtl88x2bu)
                build_driver_dkms rtl88x2bu "$DRIVER_RTL88X2BU_URL" "$DRIVER_RTL88X2BU_BRANCH"
                ;;
            rtl8188eus)
                build_driver_dkms rtl8188eus "$DRIVER_RTL8188EUS_URL" "$DRIVER_RTL8188EUS_BRANCH"
                ;;
            *)
                gl_warn "No build recipe for chipset: $chip"
                ;;
        esac
    fi
done

# ── Probe modules ─────────────────────────────────────────────────────────────
gl_step "Probing modules..."
for chip in "${chipsets[@]}"; do
    mod=$(module_for_chipset "$chip")
    modprobe "$mod" 2>/dev/null && \
        gl_success "$mod loaded" || \
        gl_warn "$mod could not be probed (may need reboot)"
done

gl_success "Driver installation step complete"
