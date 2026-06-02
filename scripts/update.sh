#!/usr/bin/env bash
#
# factory-desktop-update — Check for new versions and rebuild
#
# Usage:
#   factory-desktop-update           Check and prompt if update available
#   factory-desktop-update --force   Rebuild even if same version
#   factory-desktop-update --check   Only check, don't build
#

set -euo pipefail

# ── Resolve paths ───────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# When installed, the script lives in /opt/factory-desktop (root-owned).
# Use a writable cache directory for downloads and builds.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/factory-desktop-update"
SOURCE_DIR="$HOME/projects/factory-desktop-linux"
VERSION_FILE="$SOURCE_DIR/.current-version"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Get latest version from Factory API ─────────────────────────────

get_latest_version() {
    curl -sf "https://api.factory.ai/api/desktop/latest-version" 2>/dev/null | \
        grep -oP '"latestVersion"\s*:\s*"\K[^"]+' || echo ""
}

# ── Get currently built version ─────────────────────────────────────

get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo "0.82.0"
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

# ── Stop running instance ───────────────────────────────────────────

echo "[0/4] Stopping running Factory Desktop..."
killall -q -TERM factory-desktop-bin 2>/dev/null || true
for i in $(seq 1 50); do
    killall -0 factory-desktop-bin 2>/dev/null || break
    sleep 0.1
done
killall -q -KILL factory-desktop-bin 2>/dev/null || true
echo "  Stopped."

# ── Rebuild ─────────────────────────────────────────────────────────

mkdir -p "$CACHE_DIR"
cd "$CACHE_DIR"

echo "[1/4] Cleaning old build..."
rm -f "$CACHE_DIR/Factory-arm64.dmg"

echo "[2/4] Downloading v$LATEST..."
curl -L -o "$CACHE_DIR/Factory-arm64.dmg" \
    "https://app.factory.ai/api/desktop?platform=darwin&architecture=arm64" \
    -w "\nHTTP %{http_code} | %{size_download} bytes\n"

echo "[3/4] Building..."
cd "$SOURCE_DIR"
# Copy DMG to source dir for the Makefile
cp "$CACHE_DIR/Factory-arm64.dmg" "$SOURCE_DIR/"
make patch asar electron assemble package VERSION="$LATEST"

echo "[4/4] Installing..."
pkill -f factory-desktop-bin 2>/dev/null || true
sleep 1

sudo dpkg -i "$SOURCE_DIR/dist/factory-desktop_${LATEST}_amd64.deb"

echo "$LATEST" > "$VERSION_FILE"

echo ""
echo -e "${GREEN}Updated to v$LATEST!${NC}"
echo "Launch with: factory-desktop"
