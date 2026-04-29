#!/usr/bin/env bash
source "$(dirname "$0")/../lib/ui.sh"
REPO_ROOT="${1:?}"
source "$REPO_ROOT/config/sources.conf"

STATIC_DIR="$GHOSTLINK_DASHBOARD/static"

# ── Install full project to /opt/ghostlink ────────────────────────────────────
# Services reference /opt/ghostlink/identity/, /opt/ghostlink/pentest/, etc.
# We rsync everything except runtime dirs, .git/, __pycache__/, and external/
gl_step "Installing Ghostlink to $GHOSTLINK_BASE..."
# Exclude runtime dirs created by earlier install steps so --delete doesn't wipe them.
# install/ is kept so 'ghostlink update-tools' can re-run 07_tools.sh from the installed copy.
rsync -a --delete \
    --exclude='.git/' \
    --exclude='__pycache__/' \
    --exclude='external/' \
    --exclude='venv/' \
    --exclude='tools/' \
    --exclude='wordlists/' \
    --exclude='drivers/' \
    "$REPO_ROOT/." "$GHOSTLINK_BASE/"

# Ensure all scripts are executable
find "$GHOSTLINK_BASE" -name '*.sh' -exec chmod +x {} \;
chmod +x "$GHOSTLINK_BASE/ghostlink"
gl_success "Ghostlink installed to $GHOSTLINK_BASE"

# Create static dir after rsync so --delete doesn't wipe it before assets are downloaded
mkdir -p "$STATIC_DIR"

# ── Download frontend assets (pinned versions, flat layout) ───────────────────
# All assets go directly into static/ (not static/js/ or static/css/)
# The HTML template references /static/xterm.js, /static/pico.min.css etc.

gl_step "Downloading xterm.js v${XTERM_VERSION}..."
wget -q "$XTERM_JS_URL"        -O "$STATIC_DIR/xterm.js"        || { gl_error "Failed to download xterm.js";     exit 1; }
wget -q "$XTERM_CSS_URL"       -O "$STATIC_DIR/xterm.css"       || { gl_error "Failed to download xterm.css";    exit 1; }
wget -q "$XTERM_ADDON_FIT_URL" -O "$STATIC_DIR/xterm-addon-fit.js" || { gl_error "Failed to download xterm fit addon"; exit 1; }
gl_success "xterm.js v${XTERM_VERSION} downloaded"

gl_step "Downloading Pico.css v${PICO_VERSION}..."
wget -q "$PICO_CSS_URL" -O "$STATIC_DIR/pico.min.css" || { gl_error "Failed to download Pico.css"; exit 1; }
gl_success "Pico.css v${PICO_VERSION} downloaded"

# ── TLS certificate ───────────────────────────────────────────────────────────
gl_step "Generating self-signed TLS certificate..."
mkdir -p /etc/ghostlink
CERT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout /etc/ghostlink/dashboard.key \
    -out    /etc/ghostlink/dashboard.crt \
    -subj   "/CN=ghostlink" \
    -addext "subjectAltName=IP:${CERT_IP},IP:127.0.0.1,DNS:ghostlink.local" \
    2>/dev/null
chmod 600 /etc/ghostlink/dashboard.key
gl_success "TLS certificate generated (CN=ghostlink, IP=${CERT_IP})"

# ── Install sources.conf to /etc/ghostlink ────────────────────────────────────
cp "$REPO_ROOT/config/sources.conf"      /etc/ghostlink/
cp "$REPO_ROOT/config/ghostlink.conf"    /etc/ghostlink/ 2>/dev/null || true

# Store OS profile for 'ghostlink version'
echo "${GL_OS_PROFILE:-${GL_OS:-unknown}}" > /etc/ghostlink/.os_profile

# ── ghostlink CLI symlink ─────────────────────────────────────────────────────
ln -sf "$GHOSTLINK_BASE/ghostlink" /usr/local/bin/ghostlink
gl_success "ghostlink CLI available at /usr/local/bin/ghostlink"

# ── Create runtime directories ────────────────────────────────────────────────
mkdir -p /run/ghostlink /var/log/ghostlink/reports /var/log/ghostlink/captures
chmod 750 /var/log/ghostlink

# ── Systemd services ──────────────────────────────────────────────────────────
gl_step "Installing systemd services..."
for svc in "$REPO_ROOT"/services/*.service "$REPO_ROOT"/services/*.target; do
    [[ -f "$svc" ]] || continue
    # Skip fan service on non-RPi5 hardware
    if [[ "$(basename "$svc")" == "gl-fan.service" ]]; then
        if [[ "${GL_ENABLE_FAN:-false}" != "true" ]]; then
            gl_info "Skipping gl-fan.service (not RPi 5)"
            continue
        fi
    fi
    cp "$svc" /etc/systemd/system/
done

systemctl daemon-reload
systemctl enable ghostlink.target
systemctl start  ghostlink.target || gl_warn "ghostlink.target did not start cleanly — check: journalctl -u ghostlink.target"

gl_success "Services installed and started"
