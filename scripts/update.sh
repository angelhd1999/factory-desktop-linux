#!/usr/bin/env bash
#
# factory-desktop-update — Check for new versions and rebuild
#
# Usage:
#   factory-desktop-update           Check, confirm, then update
#   factory-desktop-update --force   Rebuild even if same version
#   factory-desktop-update --check   Only check, don't build
#

set -euo pipefail

# ── Resolve paths ───────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/factory-desktop-update"
REPO_DIR="$CACHE_DIR/repo"
REPO_URL="https://github.com/angelhd1999/factory-desktop-linux.git"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Get latest version from Factory API ─────────────────────────────

get_latest_version() {
    curl -sf "https://api.factory.ai/api/desktop/latest-version" 2>/dev/null | \
        grep -oP '"latestVersion"\s*:\s*"\K[^"]+' || echo ""
}

# ── Get currently installed version ─────────────────────────────────

get_current_version() {
    dpkg-query -W -f='${Version}' factory-desktop 2>/dev/null || echo "0"
}

# ── Ensure repo is available ────────────────────────────────────────

ensure_repo() {
    mkdir -p "$CACHE_DIR"
    if [ -d "$REPO_DIR/.git" ]; then
        cd "$REPO_DIR"
        git fetch origin --quiet 2>/dev/null || true
        git reset --hard origin/main --quiet 2>/dev/null || true
    else
        rm -rf "$REPO_DIR"
        git clone --depth 1 "$REPO_URL" "$REPO_DIR" 2>/dev/null || {
            echo -e "${RED}Error: Could not clone repository.${NC}"
            echo "Make sure git is installed and you have internet access."
            exit 1
        }
    fi
}

# ── Main ────────────────────────────────────────────────────────────

ARG="${1:-}"

if [ "$ARG" = "--check" ]; then
    CHECK_ONLY=1
elif [ "$ARG" = "--force" ]; then
    FORCE=1
fi

CURRENT=$(get_current_version)
LATEST=$(get_latest_version)

if [ -z "$LATEST" ]; then
    echo -e "${RED}Error: Could not fetch latest version from Factory API${NC}"
    echo "Check your internet connection and try again."
    exit 1
fi

echo "Current: v$CURRENT"
echo "Latest:  v$LATEST"

if [ "$CURRENT" = "$LATEST" ] && [ "${FORCE:-}" != "1" ]; then
    echo -e "${GREEN}Already up to date.${NC}"
    echo "Use --force to rebuild anyway."
    exit 0
fi

if [ "${CHECK_ONLY:-}" = "1" ]; then
    if [ "$CURRENT" != "$LATEST" ]; then
        echo -e "${YELLOW}Update available: v$CURRENT → v$LATEST${NC}"
        echo "Run without --check to install."
        exit 1
    fi
    exit 0
fi

echo ""
echo -e "${YELLOW}Updating from v$CURRENT to v$LATEST...${NC}"
echo ""

# ── Confirmation ────────────────────────────────────────────────────

read -r -p "Proceed with update? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Update cancelled."
    exit 0
fi

# ── Stop running instance ───────────────────────────────────────────

echo "[0/4] Stopping running Factory Desktop..."
killall -q -TERM factory-desktop-bin 2>/dev/null || true
echo "  Done."

# ── Rebuild ─────────────────────────────────────────────────────────

ensure_repo
cd "$CACHE_DIR"

echo "[1/4] Cleaning old build..."
rm -f "$CACHE_DIR/Factory-arm64.dmg"

echo "[2/4] Downloading v$LATEST..."
curl -L -o "$CACHE_DIR/Factory-arm64.dmg" \
    "https://app.factory.ai/api/desktop?platform=darwin&architecture=arm64" \
    -w "\nHTTP %{http_code} | %{size_download} bytes\n"

echo "[3/4] Building..."
cd "$REPO_DIR"
cp "$CACHE_DIR/Factory-arm64.dmg" "$REPO_DIR/"
make patch asar electron assemble package VERSION="$LATEST"

echo "[4/4] Installing..."
sudo dpkg -i "$REPO_DIR/dist/factory-desktop_${LATEST}_amd64.deb"

echo "$LATEST" > "$REPO_DIR/.current-version"

echo ""
echo -e "${GREEN}Updated to v$LATEST!${NC}"
echo "Launch with: factory-desktop"
