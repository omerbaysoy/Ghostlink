#!/usr/bin/env bash
# Ghostlink CLI Banner

RED='\033[0;31m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
GRAY='\033[0;37m'
RESET='\033[0m'
BOLD='\033[1m'

ghostlink_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'

          ▓▓▓▓▓
        ▓▓▓▓▓▓▓▓▓
    (( ▓▓  ◉ ◉  ▓▓ ))
   ((( ▓▓   ▿   ▓▓ )))
    (( ▓▓▓▓▓▓▓▓▓▓▓ ))
       ▓▓ ▓▓▓ ▓▓
       ▓▓▓▓ ▓▓▓▓

EOF
    echo -e "${WHITE}${BOLD}"
    cat << 'EOF'
  ██████╗ ██╗  ██╗ ██████╗ ███████╗████████╗██╗     ██╗███╗   ██╗██╗  ██╗
 ██╔════╝ ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝██║     ██║████╗  ██║██║ ██╔╝
 ██║  ███╗███████║██║   ██║███████╗   ██║   ██║     ██║██╔██╗ ██║█████╔╝
 ██║   ██║██╔══██║██║   ██║╚════██║   ██║   ██║     ██║██║╚██╗██║██╔═██╗
 ╚██████╔╝██║  ██║╚██████╔╝███████║   ██║   ███████╗██║██║ ╚████║██║  ██╗
  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝   ╚══════╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝
EOF
    echo -e "${RESET}"
    echo -e "${DIM}${CYAN}         [ WiFi Pentest & Intelligence Platform | Raspberry Pi 5 ]${RESET}"
    echo -e "${DIM}         ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

ghostlink_status_line() {
    local state_file="/var/lib/ghostlink/identity.state"

    if [[ -f "$state_file" ]]; then
        local profile mac vendor model
        profile=$(grep '^PROFILE=' "$state_file" | cut -d= -f2)
        mac=$(grep '^MAC='     "$state_file" | cut -d= -f2)
        vendor=$(grep '^VENDOR=' "$state_file" | cut -d= -f2)
        model=$(grep '^MODEL='  "$state_file" | cut -d= -f2)
        echo -e "${GRAY}  Identity : ${CYAN}${profile}${RESET}  ${DIM}${mac}  ${vendor} ${model}${RESET}"
    else
        echo -e "${GRAY}  Identity : ${DIM}factory (not spoofed)${RESET}"
    fi

    for iface in gl-mgmt gl-upstream gl-hotspot; do
        local s addr
        s=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null || echo "missing")
        addr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}')
        if [[ "$s" == "up" ]]; then
            echo -e "  ${CYAN}●${RESET} ${WHITE}${iface}${RESET}  ${CYAN}${addr:-up}${RESET}"
        else
            echo -e "  ${DIM}○ ${iface}  ${s}${RESET}"
        fi
    done
    echo ""
}

ghostlink_banner
ghostlink_status_line
