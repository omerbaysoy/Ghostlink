#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
REPO_ROOT="${1:?}"
source "$REPO_ROOT/config/sources.conf"

STATIC_DIR="$GHOSTLINK_DASHBOARD/static"
mkdir -p "$STATIC_DIR/css" "$STATIC_DIR/js"

# ── Copy dashboard source ─────────────────────────────────────────────────────
gl_step "Installing dashboard..."
cp -r "$REPO_ROOT/dashboard/." "$GHOSTLINK_DASHBOARD/"

# ── Download frontend assets (pinned versions, no bundled JS) ─────────────────
gl_step "Downloading xterm.js v${XTERM_VERSION}..."
wget -q "$XTERM_JS_URL"        -O "$STATIC_DIR/js/xterm.js"
wget -q "$XTERM_CSS_URL"       -O "$STATIC_DIR/css/xterm.css"
wget -q "$XTERM_ADDON_FIT_URL" -O "$STATIC_DIR/js/xterm-addon-fit.js"
gl_success "xterm.js downloaded"

gl_step "Downloading Pico.css v${PICO_VERSION}..."
wget -q "$PICO_CSS_URL" -O "$STATIC_DIR/css/pico.min.css"
gl_success "Pico.css downloaded"

# ── TLS cert ──────────────────────────────────────────────────────────────────
gl_step "Generating self-signed TLS certificate..."
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout /etc/ghostlink/dashboard.key \
    -out    /etc/ghostlink/dashboard.crt \
    -subj   "/CN=ghostlink" \
    -addext "subjectAltName=IP:$(hostname -I | awk '{print $1}')" \
    2>/dev/null
gl_success "TLS cert generated"

# ── ghostlink CLI symlink ─────────────────────────────────────────────────────
ln -sf "$REPO_ROOT/ghostlink" /usr/local/bin/ghostlink
chmod +x "$REPO_ROOT/ghostlink"

# ── Systemd services ──────────────────────────────────────────────────────────
gl_step "Installing systemd services..."
for svc in "$REPO_ROOT"/services/*.service "$REPO_ROOT"/services/*.target; do
    cp "$svc" /etc/systemd/system/
done
systemctl daemon-reload
systemctl enable ghostlink.target
systemctl start  ghostlink.target
gl_success "Ghostlink services enabled and started"
