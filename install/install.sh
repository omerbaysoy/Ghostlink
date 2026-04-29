#!/usr/bin/env bash
# Ghostlink Installer
# Usage: sudo ./install.sh [options]
#   --os <profile>     Force OS profile (auto|rpi-bookworm|rpi-trixie|dietpi|kali|debian|ubuntu)
#   --dry-run          Print what would be done without making changes
#   --headless         Enable headless mode (disable display manager, Kali only)
#   --skip-drivers     Skip driver installation step
#   --skip-tools       Skip pentest tool installation step

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/net.sh"
source "$REPO_ROOT/config/sources.conf"

# ── Defaults ──────────────────────────────────────────────────────────────────
OS_OVERRIDE=""
export DRY_RUN=false
export GL_HEADLESS=false
SKIP_DRIVERS=false
SKIP_TOOLS=false

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --os)         OS_OVERRIDE="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --headless)   GL_HEADLESS=true; shift ;;
        --skip-drivers) SKIP_DRIVERS=true; shift ;;
        --skip-tools)   SKIP_TOOLS=true; shift ;;
        -h|--help)
            echo "Usage: sudo $0 [--os <profile>] [--dry-run] [--headless] [--skip-drivers] [--skip-tools]"
            echo ""
            echo "OS profiles: auto rpi-bookworm rpi-trixie dietpi kali debian ubuntu"
            exit 0
            ;;
        *) gl_warn "Unknown argument: $1"; shift ;;
    esac
done

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0 $*"; exit 1; }

# ── OS detection / profile loading ───────────────────────────────────────────
if [[ -n "$OS_OVERRIDE" && "$OS_OVERRIDE" != "auto" ]]; then
    export GL_OS="$OS_OVERRIDE"
else
    export GL_OS="$(detect_os)"
fi

PROFILE_FILE="$SCRIPT_DIR/os/${GL_OS}.sh"
if [[ ! -f "$PROFILE_FILE" ]]; then
    gl_warn "No profile for OS '$GL_OS' — using generic debian profile"
    PROFILE_FILE="$SCRIPT_DIR/os/debian.sh"
fi

# shellcheck source=/dev/null
source "$PROFILE_FILE"
export GL_OS_PROFILE GL_OS_FAMILY GL_OS_PRETTY
export GL_ENABLE_FAN GL_ENABLE_ZRAM GL_ENABLE_NVME GL_HW_STRICT
export GL_PKG_UPDATE GL_PKG_INSTALL GL_PKG_CHECK
export GL_DRIVER_CHECK_FIRST GL_DRIVER_BUILD_DKMS GL_DRIVER_PREFER_PKG
export GL_HEADERS_PKG GL_HEADERS_PKG_ALT
export GL_TOOLS_CHECK_FIRST GL_MGMT_TYPE GL_HEADLESS_MODE

# Runtime overrides: detect NVMe and RPi5 even on non-RPi profiles
if has_nvme;  then export GL_ENABLE_NVME=true; fi
if is_rpi5;   then export GL_ENABLE_FAN=true;  fi

# ── Warn about template-only profiles ────────────────────────────────────────
if [[ "${GL_OS_TEMPLATE_ONLY:-false}" == "true" ]]; then
    echo ""
    gl_warn "═══════════════════════════════════════════════════════"
    gl_warn "  $GL_OS_PRETTY support is a TEMPLATE — not fully tested."
    gl_warn "  Installation will proceed but may need manual fixes."
    gl_warn "═══════════════════════════════════════════════════════"
    echo ""
    if ! $DRY_RUN; then
        if ! gl_confirm "Continue anyway?"; then
            echo "Aborted."; exit 0
        fi
    fi
fi

# ── Build step list ───────────────────────────────────────────────────────────
STEPS=()
STEPS+=("01_preflight.sh:Preflight Check")
STEPS+=("02_system.sh:System Optimization")
$SKIP_DRIVERS || STEPS+=("03_drivers.sh:Driver Installation")
STEPS+=("04_interfaces.sh:Interface Classification")
STEPS+=("05_identity.sh:Identity System")
STEPS+=("06_network.sh:Network Configuration")
$SKIP_TOOLS   || STEPS+=("07_tools.sh:Pentest Tools")
STEPS+=("08_dashboard.sh:Dashboard & Services")

# ── Banner ────────────────────────────────────────────────────────────────────
bash "$REPO_ROOT/system/banner.sh" 2>/dev/null || true
echo ""
gl_info "OS detected  : $(os_pretty "$GL_OS")"
gl_info "Profile      : $GL_OS_PROFILE"
gl_info "Fan daemon   : $GL_ENABLE_FAN"
gl_info "ZRAM         : $GL_ENABLE_ZRAM"
gl_info "NVMe tuning  : $GL_ENABLE_NVME"
$DRY_RUN && gl_warn "DRY-RUN MODE — no changes will be made"
echo ""

# ── Run steps ────────────────────────────────────────────────────────────────
total=${#STEPS[@]}
step=0

for entry in "${STEPS[@]}"; do
    file="${entry%%:*}"
    name="${entry##*:}"
    step=$((step + 1))

    gl_section "[${step}/${total}] ${name}"
    if $DRY_RUN; then
        echo "  [dry] would run: $SCRIPT_DIR/steps/$file $REPO_ROOT"
    else
        bash "$SCRIPT_DIR/steps/$file" "$REPO_ROOT"
    fi
done

# ── Headless mode (Kali) ──────────────────────────────────────────────────────
if $GL_HEADLESS && [[ "$GL_OS" == "kali" ]]; then
    gl_section "Headless Mode"
    if ! $DRY_RUN; then
        bash "$SCRIPT_DIR/steps/99_headless.sh" "$REPO_ROOT"
    else
        echo "  [dry] would enable headless mode"
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
gl_success "Ghostlink installation complete."
if ! $DRY_RUN; then
    bash "$REPO_ROOT/system/banner.sh" 2>/dev/null || true
    echo ""
    gl_info "Dashboard : https://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):8080"
    gl_info "CLI       : ghostlink status"
fi
