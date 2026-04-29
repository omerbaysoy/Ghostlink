#!/usr/bin/env bash
# GhostLink Self-Update
# Usage: ghostlink update [--dry-run] [--no-clean] [--force]
#        sudo ./install/install.sh --update --os <profile>
#
# Preserves: /etc/ghostlink/, /var/lib/ghostlink/, venv/, tools/, wordlists/, drivers/
# Safe cleanup: only __pycache__ and .pyc files
# Never: rotates identity, resets state, breaks management access

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Source ui helpers if available
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/ui.sh" 2>/dev/null || {
    gl_step()    { echo "  [update] $*"; }
    gl_info()    { echo "  [update] $*"; }
    gl_success() { echo "  [update] OK: $*"; }
    gl_warn()    { echo "  [update] WARN: $*"; }
    gl_error()   { echo "  [update] ERROR: $*"; }
}

GHOSTLINK_BASE="/opt/ghostlink"
STATE_DIR="/var/lib/ghostlink"
BACKUP_ROOT="$STATE_DIR/backups"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"

DRY=false
NO_CLEAN=false
FORCE=false
OS_OVERRIDE=""
SKIP_DRIVERS=false
SKIP_TOOLS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY=true;          shift ;;
        --no-clean)     NO_CLEAN=true;     shift ;;
        --force)        FORCE=true;        shift ;;
        --os)           OS_OVERRIDE="$2";  shift 2 ;;
        --skip-drivers) SKIP_DRIVERS=true; shift ;;
        --skip-tools)   SKIP_TOOLS=true;   shift ;;
        -h|--help)
            echo "Usage: ghostlink update [--dry-run] [--no-clean] [--force]"
            echo ""
            echo "  --dry-run       Show what would be done without making changes"
            echo "  --no-clean      Skip cleanup of build artifacts"
            echo "  --force         Hard-reset to remote HEAD (discards local changes)"
            exit 0
            ;;
        *) gl_warn "Unknown option: $1"; shift ;;
    esac
done

[[ $EUID -ne 0 ]] && { echo "[update] Must run as root."; exit 1; }

$DRY && gl_warn "DRY-RUN MODE — no changes will be made"

# ── Preflight ──────────────────────────────────────────────────────────────────
gl_step "Preflight checks..."

SOURCE_REPO="$REPO_ROOT"
[[ -d "$SOURCE_REPO" ]] || { gl_error "$SOURCE_REPO not found"; exit 1; }
[[ -d "$SOURCE_REPO/.git" ]] || { gl_error "$SOURCE_REPO is not a git repository"; exit 1; }

GIT_REMOTE=$(git -C "$SOURCE_REPO" remote get-url origin 2>/dev/null || echo "")
GIT_BRANCH=$(git -C "$SOURCE_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
GIT_COMMIT_BEFORE=$(git -C "$SOURCE_REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown")

gl_info "Source repo    : $SOURCE_REPO"
gl_info "Remote         : ${GIT_REMOTE:-none}"
gl_info "Branch         : $GIT_BRANCH"
gl_info "Current commit : $GIT_COMMIT_BEFORE"

# Check management interface is alive
MGMT_IP=$(ip -4 addr show gl-mgmt 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1];exit}' || echo "")
if [[ -n "$MGMT_IP" ]]; then
    gl_info "Management IP  : $MGMT_IP (SSH will remain accessible)"
else
    gl_warn "gl-mgmt has no IP — management access may not be active"
fi

# ── Backup ────────────────────────────────────────────────────────────────────
gl_step "Backing up /etc/ghostlink → $BACKUP_DIR..."
if $DRY; then
    echo "  [dry] mkdir -p $BACKUP_DIR && cp -a /etc/ghostlink/. $BACKUP_DIR/"
else
    mkdir -p "$BACKUP_DIR"
    cp -a /etc/ghostlink/. "$BACKUP_DIR/" 2>/dev/null || true
    gl_success "Backup written to $BACKUP_DIR"
fi

# ── Fetch latest code ─────────────────────────────────────────────────────────
if [[ -z "$GIT_REMOTE" ]]; then
    gl_warn "No git remote configured — skipping fetch (working with local code)"
else
    gl_step "Fetching from $GIT_REMOTE ($GIT_BRANCH)..."
    if $DRY; then
        echo "  [dry] git -C $SOURCE_REPO fetch origin -q"
        echo "  [dry] git -C $SOURCE_REPO merge --ff-only origin/$GIT_BRANCH"
    else
        git -C "$SOURCE_REPO" fetch origin -q 2>/dev/null || gl_warn "Fetch failed — offline?"
        if $FORCE; then
            gl_warn "Force mode: resetting to origin/$GIT_BRANCH"
            git -C "$SOURCE_REPO" reset --hard "origin/$GIT_BRANCH" 2>/dev/null || true
        else
            git -C "$SOURCE_REPO" merge --ff-only "origin/$GIT_BRANCH" 2>/dev/null || \
                gl_warn "Fast-forward merge failed — local divergence. Use --force to override."
        fi
    fi
fi

GIT_COMMIT_AFTER=$(git -C "$SOURCE_REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown")
gl_info "Commit after   : $GIT_COMMIT_AFTER"

# ── Install updated code → /opt/ghostlink ─────────────────────────────────────
gl_step "Syncing updated code to $GHOSTLINK_BASE..."
if $DRY; then
    echo "  [dry] rsync -a --delete (excludes: .git/ external/ venv/ tools/ wordlists/ drivers/)"
else
    rsync -a --delete \
        --exclude='.git/' \
        --exclude='__pycache__/' \
        --exclude='external/' \
        --exclude='venv/' \
        --exclude='tools/' \
        --exclude='wordlists/' \
        --exclude='drivers/' \
        "$SOURCE_REPO/." "$GHOSTLINK_BASE/"
    find "$GHOSTLINK_BASE" -name '*.sh' -exec chmod +x {} \;
    chmod +x "$GHOSTLINK_BASE/ghostlink"
    gl_success "Code synced to $GHOSTLINK_BASE"
fi

# ── Restore configs (never overwrite user config) ─────────────────────────────
gl_step "Checking configuration files..."
if $DRY; then
    echo "  [dry] Preserve /etc/ghostlink/ghostlink.conf"
    echo "  [dry] Update   /etc/ghostlink/sources.conf"
else
    if [[ ! -f /etc/ghostlink/ghostlink.conf ]]; then
        cp -n "$GHOSTLINK_BASE/config/ghostlink.conf" /etc/ghostlink/ 2>/dev/null || true
        gl_info "ghostlink.conf restored (was missing)"
    else
        gl_info "ghostlink.conf unchanged (user config preserved)"
    fi
    cp -f "$GHOSTLINK_BASE/config/sources.conf" /etc/ghostlink/
    gl_success "sources.conf updated"
fi

# ── Re-install missing tools (skip if present) ────────────────────────────────
if ! $SKIP_TOOLS; then
    gl_step "Checking pentest tools for missing entries..."
    if $DRY; then
        echo "  [dry] bash $GHOSTLINK_BASE/install/steps/07_tools.sh $GHOSTLINK_BASE"
    else
        GL_PKG_UPDATE="true"  # skip apt-get update during update run (already fresh)
        export GL_PKG_UPDATE
        bash "$GHOSTLINK_BASE/install/steps/07_tools.sh" "$GHOSTLINK_BASE" 2>&1 | \
            grep -E 'already|installed|WARN|ERROR|OK' | sed 's/^/  /' || true
        unset GL_PKG_UPDATE
        gl_success "Tool check done"
    fi
fi

# ── Ensure CLI symlink ────────────────────────────────────────────────────────
gl_step "Ensuring CLI symlink..."
if $DRY; then
    echo "  [dry] ln -sf $GHOSTLINK_BASE/ghostlink /usr/local/bin/ghostlink"
else
    ln -sf "$GHOSTLINK_BASE/ghostlink" /usr/local/bin/ghostlink
    chmod +x "$GHOSTLINK_BASE/ghostlink"
    gl_success "Symlink: /usr/local/bin/ghostlink → $GHOSTLINK_BASE/ghostlink"
fi

# ── Reload systemd units ──────────────────────────────────────────────────────
gl_step "Reloading systemd units..."
if $DRY; then
    echo "  [dry] systemctl daemon-reload && systemctl try-restart ghostlink.target"
else
    systemctl daemon-reload
    systemctl try-restart ghostlink.target 2>/dev/null || \
        gl_warn "ghostlink.target restart skipped (may not be running)"
    gl_success "Systemd units reloaded"
fi

# ── Safe cleanup ──────────────────────────────────────────────────────────────
if ! $NO_CLEAN; then
    gl_step "Cleaning build artifacts (__pycache__, .pyc)..."
    if $DRY; then
        echo "  [dry] find $GHOSTLINK_BASE -type d -name '__pycache__' | wc -l directories"
    else
        find "$GHOSTLINK_BASE" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
        find "$GHOSTLINK_BASE" -name '*.pyc' -delete 2>/dev/null || true
        gl_success "Build artifacts cleaned"
    fi
fi

# ── Record update state ───────────────────────────────────────────────────────
if ! $DRY; then
    mkdir -p "$STATE_DIR"
    {
        echo "LAST_UPDATE=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "UPDATE_COMMIT=$GIT_COMMIT_AFTER"
        echo "UPDATE_BRANCH=$GIT_BRANCH"
        echo "PREV_COMMIT=$GIT_COMMIT_BEFORE"
    } > "$STATE_DIR/update.state"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  ── GhostLink Update Summary ─────────────────────────────────────────"
echo "  Install path   : $GHOSTLINK_BASE"
echo "  Symlink        : $(readlink -f /usr/local/bin/ghostlink 2>/dev/null || echo 'not installed')"
echo "  Git remote     : ${GIT_REMOTE:-none}"
echo "  Branch         : $GIT_BRANCH"
echo "  Commit (before): $GIT_COMMIT_BEFORE"
echo "  Commit (after) : $GIT_COMMIT_AFTER"
if ! $DRY; then
    echo "  Backup         : $BACKUP_DIR"
fi
echo ""
if $DRY; then
    echo "  [dry-run] No changes were made."
else
    if [[ "$GIT_COMMIT_BEFORE" != "$GIT_COMMIT_AFTER" ]]; then
        echo "  Updated: $GIT_COMMIT_BEFORE → $GIT_COMMIT_AFTER"
    else
        echo "  Already up to date."
    fi
    echo "  Run: ghostlink doctor"
fi
echo ""
