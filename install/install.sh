#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/net.sh"
source "$REPO_ROOT/config/sources.conf"

STEPS=(
    "01_preflight.sh:Preflight Check"
    "02_system.sh:System Optimization"
    "03_drivers.sh:Driver Installation"
    "04_interfaces.sh:Interface Classification"
    "05_identity.sh:Identity System"
    "06_network.sh:Network Configuration"
    "07_tools.sh:Pentest Tools"
    "08_dashboard.sh:Dashboard & Services"
)

main() {
    [[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0"; exit 1; }

    bash "$REPO_ROOT/system/banner.sh"

    local total=${#STEPS[@]}
    local step=0

    for entry in "${STEPS[@]}"; do
        local file="${entry%%:*}"
        local name="${entry##*:}"
        step=$((step + 1))

        gl_section "[${step}/${total}] ${name}"
        bash "$SCRIPT_DIR/steps/$file" "$REPO_ROOT"
    done

    gl_success "Ghostlink installation complete."
    bash "$REPO_ROOT/system/banner.sh"
    echo ""
    gl_info "Dashboard : https://$(hostname -I | awk '{print $1}'):8080"
    gl_info "CLI       : ghostlink status"
}

main "$@"
