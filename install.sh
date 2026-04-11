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

info()  { echo "  $1"; }
error() { echo "Error: $1" >&2; exit 1; }

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
    local cache_dir="$HOME/.claude/plugins/cache/${MARKETPLACE_NAME}"
    if [ -d "$cache_dir" ]; then
        info "Clearing plugin cache at ${cache_dir}..."
        rm -rf "$cache_dir"
    fi
}

install_plugin() {
    local source="$1"

    require_claude

    # Remove existing marketplace and cache for a clean install
    if marketplace_exists; then
        info "Removing existing marketplace '${MARKETPLACE_NAME}'..."
        if plugin_installed; then
            claude plugin uninstall "${PLUGIN_NAME}@${MARKETPLACE_NAME}" 2>/dev/null || true
        fi
        claude plugin marketplace remove "${MARKETPLACE_NAME}" 2>/dev/null || true
    fi
    clear_plugin_cache

    info "Adding marketplace '${MARKETPLACE_NAME}' (source: ${source})..."
    claude plugin marketplace add "${source}" --scope user

    info "Installing plugin '${PLUGIN_NAME}@${MARKETPLACE_NAME}'..."
    claude plugin install "${PLUGIN_NAME}@${MARKETPLACE_NAME}"
}

install_plan_executor_local() {
    local submodule_dir="$1"
    info "Updating plan-executor submodule..."
    git submodule update --init --remote "${submodule_dir}"
    info "Running plan-executor installer..."
    bash "${submodule_dir}/install.sh"
}

install_plan_executor_remote() {
    local tmpdir
    tmpdir=$(mktemp -d)
    info "Cloning plan-executor..."
    gh repo clone "${PLAN_EXECUTOR_SLUG}" "${tmpdir}/plan-executor" -- --quiet
    info "Running plan-executor installer..."
    bash "${tmpdir}/plan-executor/install.sh"
    rm -rf "${tmpdir}"
}

install_sjv_local() {
    local submodule_dir="$1"
    info "Updating stream-json-view submodule..."
    git submodule update --init --remote "${submodule_dir}"
    info "Running sjv installer..."
    (cd "${submodule_dir}" && bash install.sh)
}

install_sjv_remote() {
    local tmpdir
    tmpdir=$(mktemp -d)
    info "Cloning stream-json-view..."
    gh repo clone "${SJV_SLUG}" "${tmpdir}/stream-json-view" -- --quiet
    info "Running sjv installer..."
    (cd "${tmpdir}/stream-json-view" && bash install.sh)
    rm -rf "${tmpdir}"
}

# When run from inside the repo, install from the local directory.
# Otherwise (one-liner / piped via bash -c), point Claude at the GitHub repo.
if [ -f ".claude-plugin/marketplace.json" ] && [ -d ".git" ]; then
    install_plugin "$(pwd)"
    if [ -d "plan-executor" ]; then
        install_plan_executor_local "plan-executor"
    else
        install_plan_executor_remote
    fi
    if [ -z "$SKIP_SJV" ]; then
        if [ -d "stream-json-view" ]; then
            install_sjv_local "stream-json-view"
        else
            install_sjv_remote
        fi
    else
        info "Skipping stream-json-view (SKIP_SJV is set)"
    fi
else
    install_plugin "${REPO_SLUG}"
    install_plan_executor_remote
    if [ -z "$SKIP_SJV" ]; then
        install_sjv_remote
    else
        info "Skipping stream-json-view (SKIP_SJV is set)"
    fi
fi

info "Done. Restart Claude Code to apply changes."
