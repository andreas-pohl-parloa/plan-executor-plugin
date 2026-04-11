#!/usr/bin/env bash
# SessionStart hook: ensures plan-executor and sjv are installed and up to date.
# - Missing binary: runs the upstream install.sh (full bootstrap).
# - Outdated binary: downloads the new binary in-place without restarting the daemon.
#   The daemon picks up the new binary on its next natural restart.

set -euo pipefail

PE_REPO="andreas-pohl-parloa/plan-executor"
PE_BINARY="plan-executor"
PE_VERSION_FILE="$HOME/.plan-executor/installed-version"

SJV_REPO="andreas-pohl-parloa/stream-json-view"
SJV_BINARY="sjv"
SJV_VERSION_FILE="$HOME/.sjv/installed-version"

HOME_BIN="$HOME/bin"
LOCAL_BIN="$HOME/.local/bin"

# ── helpers ──────────────────────────────────────────────────────────────

get_latest_version() {
    local repo="$1"
    local tag
    tag="$(gh release view --repo "$repo" --json tagName --jq '.tagName' 2>/dev/null || echo "")"
    echo "${tag#v}"
}

get_installed_version() {
    local file="$1"
    [ -f "$file" ] && cat "$file" || echo ""
}

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

# Download install.sh from a GitHub repo and run it (full bootstrap).
run_remote_installer() {
    local repo="$1"
    command -v gh >/dev/null 2>&1 || { echo "  gh CLI not found." >&2; return 1; }
    local script
    script="$(gh api "repos/${repo}/contents/install.sh" \
        --header 'Accept: application/vnd.github.raw' 2>/dev/null)" || { return 1; }
    bash -c "$script" || { return 1; }
}

# Download only the binary from the latest release (no daemon restart).
update_binary_only() {
    local repo="$1" binary="$2" version_file="$3" latest="$4"
    local platform asset tmpdir target

    platform="$(detect_platform)"
    [ -z "$platform" ] && return 1

    asset="${binary}-${platform}.zip"
    tmpdir="$(mktemp -d)"

    gh release download "v${latest}" --repo "$repo" --pattern "$asset" --dir "$tmpdir" 2>/dev/null || {
        rm -rf "$tmpdir"; return 1
    }
    unzip -q "$tmpdir/$asset" -d "$tmpdir" || { rm -rf "$tmpdir"; return 1; }
    [ -f "$tmpdir/$binary" ] || { rm -rf "$tmpdir"; return 1; }

    target="$(get_install_dir)/$binary"
    cp "$tmpdir/$binary" "$target"
    chmod 755 "$target"
    rm -rf "$tmpdir"

    # macOS: re-sign for Gatekeeper
    if [ "$(uname -s)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
        codesign --force --sign - "$target" 2>/dev/null || true
    fi

    # Update version tracking
    local version_dir
    version_dir="$(dirname "$version_file")"
    mkdir -p "$version_dir"
    echo "$latest" > "$version_file"
}

# Check a binary: install if missing, update in-place if outdated.
check_binary() {
    local binary="$1" repo="$2" version_file="$3"

    if ! command -v "$binary" >/dev/null 2>&1; then
        if run_remote_installer "$repo"; then
            echo "installed"
        else
            echo "FAIL:not found and auto-install failed"
        fi
        return
    fi

    # Installed — check for updates
    command -v gh >/dev/null 2>&1 || { echo "ok (update check skipped, no gh)"; return; }

    local installed latest
    installed="$(get_installed_version "$version_file")"
    latest="$(get_latest_version "$repo")"

    [ -z "$latest" ] && { echo "ok (update check skipped)"; return; }
    [ -n "$installed" ] && [ "$installed" = "$latest" ] && { echo "ok ($installed)"; return; }

    # Outdated — update binary only, do NOT restart daemon
    if update_binary_only "$repo" "$binary" "$version_file" "$latest"; then
        echo "updated ($installed -> $latest)"
    else
        echo "ok (update to $latest failed, keeping ${installed:-unknown})"
    fi
}

# ── main ─────────────────────────────────────────────────────────────────

pe_status="$(check_binary "$PE_BINARY" "$PE_REPO" "$PE_VERSION_FILE")"
sjv_status="$(check_binary "$SJV_BINARY" "$SJV_REPO" "$SJV_VERSION_FILE")"

summary="$PE_BINARY: $pe_status, $SJV_BINARY: $sjv_status"

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "plan-executor plugin dependency check: $summary"
  }
}
EOF

exit 0
