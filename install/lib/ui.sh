#!/usr/bin/env bash
# Terminal output helpers

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; GRAY='\033[0;37m'; BOLD='\033[1m'; RESET='\033[0m'

gl_section() { echo -e "\n${BOLD}${CYAN}━━ $1 ━━${RESET}"; }
gl_step()    { echo -e "  ${GRAY}→${RESET} $1"; }
gl_success() { echo -e "  ${GREEN}✓${RESET} $1"; }
gl_warn()    { echo -e "  ${YELLOW}⚠${RESET} $1"; }
gl_error()   { echo -e "  ${RED}✗${RESET} $1" >&2; }
gl_info()    { echo -e "  ${CYAN}•${RESET} $1"; }

gl_prompt() {
    local question="$1" var="$2" default="${3:-}"
    if [[ -n "$default" ]]; then
        echo -ne "  ${CYAN}?${RESET} ${question} [${default}]: "
        read -r answer
        printf -v "$var" '%s' "${answer:-$default}"
    else
        echo -ne "  ${CYAN}?${RESET} ${question}: "
        read -r answer
        printf -v "$var" '%s' "$answer"
    fi
}

gl_prompt_secret() {
    local question="$1" var="$2"
    echo -ne "  ${CYAN}?${RESET} ${question}: "
    read -rs answer; echo ""
    printf -v "$var" '%s' "$answer"
}

gl_confirm() {
    local question="$1"
    echo -ne "  ${CYAN}?${RESET} ${question} [y/N]: "
    read -r answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}
