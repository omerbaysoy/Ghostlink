#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
REPO_ROOT="${1:?}"
source "$REPO_ROOT/config/sources.conf"

mkdir -p "$GHOSTLINK_TOOLS" "$GHOSTLINK_WORDLISTS"

# ── APT tools ────────────────────────────────────────────────────────────────
gl_step "Installing system pentest tools (apt)..."
# shellcheck disable=SC2086
apt-get install -y -qq $APT_PENTEST_TOOLS
gl_success "apt tools installed"

# ── wifite2 (git) ─────────────────────────────────────────────────────────────
gl_step "Installing wifite2..."
if [[ -d "$TOOL_WIFITE2_DEST/.git" ]]; then
    git -C "$TOOL_WIFITE2_DEST" pull -q
else
    git clone -q --depth 1 --branch "$TOOL_WIFITE2_BRANCH" \
        "$TOOL_WIFITE2_URL" "$TOOL_WIFITE2_DEST"
fi
"$GHOSTLINK_VENV/bin/pip" install -q -e "$TOOL_WIFITE2_DEST"
gl_success "wifite2 installed from $(git -C "$TOOL_WIFITE2_DEST" rev-parse --short HEAD)"

# ── bettercap ────────────────────────────────────────────────────────────────
gl_step "Installing bettercap..."
if apt-cache show bettercap &>/dev/null; then
    apt-get install -y -qq bettercap
    gl_success "bettercap installed via apt"
elif command -v go &>/dev/null; then
    go install "$TOOL_BETTERCAP_GO" 2>/dev/null
    gl_success "bettercap installed via go"
else
    gl_warn "bettercap skipped — install Go or add backports repo"
fi

# ── Python venv ───────────────────────────────────────────────────────────────
gl_step "Creating Python venv at $GHOSTLINK_VENV..."
python3 -m venv "$GHOSTLINK_VENV"
"$GHOSTLINK_VENV/bin/pip" install -q --upgrade pip
# shellcheck disable=SC2086
"$GHOSTLINK_VENV/bin/pip" install -q $PIP_PACKAGES
gl_success "Python venv ready"

# ── Wordlist ──────────────────────────────────────────────────────────────────
gl_step "Downloading rockyou.txt..."
if [[ ! -f "$GHOSTLINK_WORDLISTS/rockyou.txt" ]]; then
    wget -q "$WORDLIST_ROCKYOU_URL" -O "$GHOSTLINK_WORDLISTS/rockyou.txt"
    gl_success "rockyou.txt downloaded ($(du -sh "$GHOSTLINK_WORDLISTS/rockyou.txt" | cut -f1))"
else
    gl_success "rockyou.txt already present"
fi
