#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
source "$(dirname "$0")/../lib/detect.sh"
REPO_ROOT="${1:?}"
source "$REPO_ROOT/config/sources.conf"

gl_step "Installing kernel build dependencies..."
apt-get install -y -qq linux-headers-"$(uname -r)" build-essential dkms git

gl_step "Detecting USB WiFi chipsets..."
mapfile -t chipsets < <(detected_chipsets)

if [[ ${#chipsets[@]} -eq 0 ]]; then
    gl_warn "No recognized RTL chipsets found — skipping driver installation"
    exit 0
fi

install_driver() {
    local name="$1" url="$2" branch="$3"
    local dest="$GHOSTLINK_DRIVERS/$name"

    gl_step "Installing driver: $name"

    if [[ -d "$dest/.git" ]]; then
        gl_step "Updating existing clone..."
        git -C "$dest" fetch -q origin "$branch"
        git -C "$dest" checkout -q "$branch"
        git -C "$dest" pull -q
    else
        mkdir -p "$GHOSTLINK_DRIVERS"
        git clone -q --depth 1 --branch "$branch" "$url" "$dest"
    fi

    # DKMS needs the module name from dkms.conf
    local mod_name mod_ver
    mod_name=$(grep "^PACKAGE_NAME" "$dest/dkms.conf" | cut -d= -f2 | tr -d '"')
    mod_ver=$(grep "^PACKAGE_VERSION" "$dest/dkms.conf" | cut -d= -f2 | tr -d '"')

    dkms remove "$mod_name/$mod_ver" --all 2>/dev/null || true
    dkms add "$dest"
    dkms build "$mod_name/$mod_ver" || { gl_error "DKMS build failed for $name — aborting"; exit 1; }
    dkms install "$mod_name/$mod_ver"

    gl_success "$name installed via DKMS (auto-rebuilds on kernel upgrade)"
}

for chip in "${chipsets[@]}"; do
    case "$chip" in
        rtl8812au)  install_driver rtl8812au  "$DRIVER_RTL8812AU_URL"  "$DRIVER_RTL8812AU_BRANCH" ;;
        rtl88x2bu)  install_driver rtl88x2bu  "$DRIVER_RTL88X2BU_URL"  "$DRIVER_RTL88X2BU_BRANCH" ;;
        rtl8188eus) install_driver rtl8188eus "$DRIVER_RTL8188EUS_URL" "$DRIVER_RTL8188EUS_BRANCH" ;;
    esac
done

gl_step "Probing new modules..."
for chip in "${chipsets[@]}"; do
    modprobe "$chip" 2>/dev/null && gl_success "$chip loaded" || gl_warn "Could not modprobe $chip (may need reboot)"
done
