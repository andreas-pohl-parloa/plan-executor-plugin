#!/bin/bash
# Install script for plan-executor plugin
#
# One-line install:
#   bash -c "$(gh api 'repos/andreas-pohl-parloa/plan-executor-plugin/contents/install.sh' --header 'Accept: application/vnd.github.raw')"

set -e

REPO_SLUG="andreas-pohl-parloa/plan-executor-plugin"
PLAN_EXECUTOR_SLUG="andreas-pohl-parloa/plan-executor"
SJV_SLUG="andreas-pohl-parloa/stream-json-view"
MARKETPLACE_NAME="plan-executor"
PLUGIN_NAME="plan-executor"

SKIP_SJV="${SKIP_SJV:-}"

info()  { printf "  %s\n" "$1"; }
ok()    { printf "  \033[32m✔\033[0m %s\n" "$1"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$1"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
error() { printf "\033[31mError:\033[0m %s\n" "$1" >&2; exit 1; }

# ── plugin install ────────────────────────────────────────────────────────

require_claude() {
    command -v claude >/dev/null 2>&1 || error "claude CLI not found. Install Claude Code first."
}

marketplace_exists() {
    claude plugin marketplace list 2>/dev/null | grep -q "❯ ${MARKETPLACE_NAME}"
}

plugin_installed() {
    claude plugin list 2>/dev/null | grep -q "❯ ${PLUGIN_NAME}@${MARKETPLACE_NAME}"
}

clear_plugin_cache() {
    local base="$HOME/.claude/plugins"
    rm -rf "${base}/cache/${MARKETPLACE_NAME}" 2>/dev/null || true
    rm -rf "${base}/marketplaces/${MARKETPLACE_NAME}" 2>/dev/null || true
}

install_plugin() {
    local source="$1"

    require_claude

    # Always remove existing marketplace, plugin, and cache for a clean install
    if plugin_installed; then
        claude plugin uninstall "${PLUGIN_NAME}@${MARKETPLACE_NAME}" >/dev/null 2>&1 || true
    fi
    if marketplace_exists; then
        claude plugin marketplace remove "${MARKETPLACE_NAME}" >/dev/null 2>&1 || true
    fi
    clear_plugin_cache

    info "Installing plugin..."
    claude plugin marketplace add "${source}" --scope user >/dev/null 2>&1
    claude plugin install "${PLUGIN_NAME}@${MARKETPLACE_NAME}" >/dev/null 2>&1
    ok "Plugin installed (${PLUGIN_NAME}@${MARKETPLACE_NAME})"
}

# ── binary helpers ────────────────────────────────────────────────────────

HOME_BIN="$HOME/bin"
LOCAL_BIN="$HOME/.local/bin"

detect_platform() {
    local os arch
    os="$(uname -s)"; arch="$(uname -m)"
    case "$os" in Darwin) os="macos";; Linux) os="linux";; *) echo ""; return;; esac
    case "$arch" in x86_64|amd64) arch="x86_64";; arm64|aarch64) arch="arm64";; *) echo ""; return;; esac
    echo "${os}-${arch}"
}

get_install_dir() {
    if [ -d "$HOME_BIN" ]; then echo "$HOME_BIN"
    elif [ -d "$LOCAL_BIN" ]; then echo "$LOCAL_BIN"
    else mkdir -p "$LOCAL_BIN"; echo "$LOCAL_BIN"
    fi
}

get_installed_version() {
    local file="$1"
    [ -f "$file" ] && cat "$file" || echo ""
}

get_latest_version() {
    local repo="$1"
    local tag
    tag="$(gh release view --repo "$repo" --json tagName --jq '.tagName' 2>/dev/null || echo "")"
    echo "${tag#v}"
}

# Install or update a binary from GitHub releases.
# Usage: install_binary <name> <repo> <version_file> <state_dir>
# Prints one of: installed, updated, exists, failed
install_binary() {
    local name="$1" repo="$2" version_file="$3" state_dir="$4"
    local platform target installed latest

    platform="$(detect_platform)"
    [ -z "$platform" ] && { echo "failed"; return; }

    target="$(get_install_dir)/$name"
    installed="$(get_installed_version "$version_file")"
    latest="$(get_latest_version "$repo")"

    [ -z "$latest" ] && {
        # Can't determine latest version — if binary exists, keep it
        if command -v "$name" >/dev/null 2>&1; then
            echo "exists"
        else
            echo "failed"
        fi
        return
    }

    # Already installed and up to date
    if command -v "$name" >/dev/null 2>&1 && [ -n "$installed" ] && [ "$installed" = "$latest" ]; then
        echo "exists"
        return
    fi

    local asset="${name}-${platform}.zip"
    local tmpdir
    tmpdir="$(mktemp -d)"

    if ! gh release download "v${latest}" --repo "$repo" --pattern "$asset" --dir "$tmpdir" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        if command -v "$name" >/dev/null 2>&1; then echo "exists"; else echo "failed"; fi
        return
    fi

    if ! unzip -q "$tmpdir/$asset" -d "$tmpdir" 2>/dev/null; then
        rm -rf "$tmpdir"
        if command -v "$name" >/dev/null 2>&1; then echo "exists"; else echo "failed"; fi
        return
    fi

    [ -f "$tmpdir/$name" ] || {
        rm -rf "$tmpdir"
        if command -v "$name" >/dev/null 2>&1; then echo "exists"; else echo "failed"; fi
        return
    }

    mkdir -p "$(dirname "$target")"
    cp "$tmpdir/$name" "$target"
    chmod 755 "$target"
    rm -rf "$tmpdir"

    # macOS: re-sign for Gatekeeper
    if [ "$(uname -s)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
        codesign --force --sign - "$target" 2>/dev/null || true
    fi

    # Track version
    mkdir -p "$state_dir"
    echo "$latest" > "$version_file"

    if [ -n "$installed" ] && [ "$installed" != "$latest" ]; then
        echo "updated"
    else
        echo "installed"
    fi
}

# ── plan-executor specific setup ──────────────────────────────────────────

setup_plan_executor() {
    local base_dir="$HOME/.plan-executor"
    local config="$base_dir/config.json"

    # Ensure config exists
    if [ ! -f "$config" ]; then
        mkdir -p "$base_dir"
        cat > "$config" << EOCFG
{
  "watch_dirs": ["~/workspace/code", "~/tools"],
  "plan_patterns": ["**/.my/plans/*.md"],
  "auto_execute": false
}
EOCFG
    fi

    # Add shell hook if not present
    local hook='command -v plan-executor >/dev/null 2>&1 && plan-executor ensure 2>/dev/null'
    local marker="# plan-executor"
    local hook_added=false
    for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
        [ -f "$rc" ] || continue
        if grep -qF "plan-executor ensure" "$rc" 2>/dev/null; then
            hook_added=true
            break
        fi
    done

    if [ "$hook_added" = "false" ]; then
        local rc
        case "$(basename "${SHELL:-zsh}")" in
            zsh)  rc="$HOME/.zshrc" ;;
            bash) rc="${HOME}/.bash_profile"; [ -f "$HOME/.bashrc" ] && rc="$HOME/.bashrc" ;;
            *)    rc="$HOME/.profile" ;;
        esac
        echo "" >> "$rc"
        echo "$marker" >> "$rc"
        echo "$hook" >> "$rc"
    fi

    # Stop existing daemon, start fresh
    plan-executor stop >/dev/null 2>&1 || true
    plan-executor daemon >/dev/null 2>&1 || true
}

# ── main ──────────────────────────────────────────────────────────────────

# Determine plugin source
if [ -f ".claude-plugin/marketplace.json" ] && [ -d ".git" ]; then
    install_plugin "$(pwd)"
else
    install_plugin "${REPO_SLUG}"
fi

# Install plan-executor binary
info "Installing plan-executor binary..."
pe_result="$(install_binary "plan-executor" "$PLAN_EXECUTOR_SLUG" "$HOME/.plan-executor/installed-version" "$HOME/.plan-executor")"
case "$pe_result" in
    installed) ok "Binary installed." ; setup_plan_executor ;;
    updated)   ok "Binary updated."   ; setup_plan_executor ;;
    exists)    ok "Binary up to date." ;;
    *)         fail "Binary install failed. Run manually: gh repo clone ${PLAN_EXECUTOR_SLUG} && cd plan-executor && bash install.sh" ;;
esac

# Install sjv binary
if [ -z "$SKIP_SJV" ]; then
    info "Installing sjv binary..."
    sjv_result="$(install_binary "sjv" "$SJV_SLUG" "$HOME/.sjv/installed-version" "$HOME/.sjv")"
    case "$sjv_result" in
        installed) ok "Binary installed." ;;
        updated)   ok "Binary updated."   ;;
        exists)    ok "Binary up to date." ;;
        *)         warn "Binary install failed (optional). Install manually: gh repo clone ${SJV_SLUG} && cd stream-json-view && bash install.sh" ;;
    esac
else
    info "Skipping sjv (SKIP_SJV is set)"
fi

echo ""
ok "Done. Restart Claude Code to apply changes."
