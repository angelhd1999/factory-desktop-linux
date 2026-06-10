#!/usr/bin/env bash
#
# Build a .deb package for Factory Desktop (Linux)
#
# Usage: ./scripts/build-deb.sh [VERSION]
#   VERSION defaults to "0.82.0" (from the macOS DMG metadata)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
DIST_DIR="${PROJECT_DIR}/dist"
ICON_SOURCE="${PROJECT_DIR}/assets/factory-desktop.svg"

VERSION="${1:-0.82.0}"
PACKAGE_NAME="factory-desktop"
DEB_NAME="${PACKAGE_NAME}_${VERSION}_amd64"
PACKAGE_DIR="${BUILD_DIR}/${DEB_NAME}"

# ── Validate ────────────────────────────────────────────────────────

if [ ! -f "${BUILD_DIR}/electron/electron" ]; then
    echo "ERROR: Linux Electron binary not found. Run 'make electron' first." >&2
    exit 1
fi

if [ ! -f "${BUILD_DIR}/app.asar" ]; then
    echo "ERROR: patched app.asar not found. Run 'make patch' and 'make asar' first." >&2
    exit 1
fi

if [ ! -f "${ICON_SOURCE}" ]; then
    echo "ERROR: Factory icon not found at ${ICON_SOURCE}" >&2
    exit 1
fi

# ── Create package structure ────────────────────────────────────────

echo "[build-deb] Creating package structure for ${DEB_NAME}..."

rm -rf "${PACKAGE_DIR}"
mkdir -p "${PACKAGE_DIR}/opt/${PACKAGE_NAME}"
mkdir -p "${PACKAGE_DIR}/usr/share/applications"
mkdir -p "${PACKAGE_DIR}/usr/share/icons/hicolor/scalable/apps"
mkdir -p "${PACKAGE_DIR}/usr/share/pixmaps"
mkdir -p "${PACKAGE_DIR}/usr/bin"
mkdir -p "${PACKAGE_DIR}/DEBIAN"

# ── Copy app files ──────────────────────────────────────────────────

echo "[build-deb] Copying application files..."

# Electron runtime — copy everything, rename electron binary so app.isPackaged returns true
cp -r "${BUILD_DIR}/electron/"* "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/"
# Rename: Electron's app.isPackaged returns false if executable is named "electron"
mv "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/electron" "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/factory-desktop-bin"
# Remove default Electron app.asar (we use our own patched one)
rm -f "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/resources/default_app.asar"

# App resources
mkdir -p "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/resources"
cp "${BUILD_DIR}/app.asar" "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/resources/"

# Droid CLI binary
# The macOS DMG bundles a Mach-O binary that won't run on Linux.
# Use a wrapper that calls the system-installed 'droid' from PATH.
mkdir -p "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/resources/bin"
cat > "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/resources/bin/droid" << 'WRAPPER'
#!/usr/bin/env bash
# Factory Desktop Linux — droid wrapper
# Calls the system-installed droid CLI, filtering flags not supported
# by the local droid version. Logs dropped flags for debuggability.
set -euo pipefail

LOG_DIR="${HOME}/.local/state/factory-desktop"
mkdir -p "$LOG_DIR"
DEBUG_LOG="$LOG_DIR/droid-wrapper.log"

args=()
dropped=()
for arg in "$@"; do
    case "$arg" in
        --enable-code-server)
            dropped+=("$arg")
            ;;
        *)
            args+=("$arg")
            ;;
    esac
done

if [ ${#dropped[@]} -gt 0 ]; then
    echo "[$(date -Iseconds)] WARNING: dropped unsupported flags: ${dropped[*]}" >> "$DEBUG_LOG"
    echo "[$(date -Iseconds)] retained flags: ${args[*]}" >> "$DEBUG_LOG"
fi

exec droid "${args[@]}"
WRAPPER
chmod 755 "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/resources/bin/droid"

# Launcher wrapper
cp "${SCRIPT_DIR}/launcher.sh" "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/factory-desktop"
chmod 755 "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/factory-desktop"

# Update helper
cp "${SCRIPT_DIR}/update.sh" "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/factory-desktop-update"
chmod 755 "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/factory-desktop-update"

# Update check helper (daily systemd timer)
cp "${SCRIPT_DIR}/factory-desktop-update-check.sh" "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/factory-desktop-update-check"
chmod 755 "${PACKAGE_DIR}/opt/${PACKAGE_NAME}/factory-desktop-update-check"

# Systemd user service and timer
mkdir -p "${PACKAGE_DIR}/usr/lib/systemd/user"
cp "${SCRIPT_DIR}/factory-desktop-update-check.service" "${PACKAGE_DIR}/usr/lib/systemd/user/"
cp "${SCRIPT_DIR}/factory-desktop-update-check.timer" "${PACKAGE_DIR}/usr/lib/systemd/user/"

# ── Create symlinks in /usr/bin ─────────────────────────────────────

ln -sf "/opt/${PACKAGE_NAME}/factory-desktop" "${PACKAGE_DIR}/usr/bin/${PACKAGE_NAME}"
ln -sf "/opt/${PACKAGE_NAME}/factory-desktop-update" "${PACKAGE_DIR}/usr/bin/${PACKAGE_NAME}-update"

cp "${ICON_SOURCE}" "${PACKAGE_DIR}/usr/share/icons/hicolor/scalable/apps/${PACKAGE_NAME}.svg"
cp "${ICON_SOURCE}" "${PACKAGE_DIR}/usr/share/pixmaps/${PACKAGE_NAME}.svg"

cat > "${PACKAGE_DIR}/usr/share/applications/${PACKAGE_NAME}.desktop" << DESKTOP
[Desktop Entry]
Name=Factory
Comment=AI-powered development agent
GenericName=AI Coding Agent
Exec=/opt/${PACKAGE_NAME}/factory-desktop
Icon=${PACKAGE_NAME}
Type=Application
Categories=Development;IDE;
Keywords=AI;agent;coding;droid;factory;
StartupWMClass=Factory
Terminal=false
DESKTOP

# ── Create DEBIAN control file ──────────────────────────────────────

cat > "${PACKAGE_DIR}/DEBIAN/control" << CONTROL
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: devel
Priority: optional
Architecture: amd64
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0, libsecret-1-0, libdrm2, libgbm1, libasound2
Recommends: droid-cli
Maintainer: Factory Desktop Linux Community <community@factory.ai>
Description: Factory Desktop — AI-powered development agent
 Factory Desktop provides a native interface for Factory Droids,
 AI software development agents that automate tasks across the
 entire software lifecycle.
 .
 This is an unofficial community port for Linux. The official
 desktop app is available for macOS and Windows.
 Homepage: https://github.com/YOUR_USER/factory-desktop-linux
CONTROL

# ── DEBIAN maintainer scripts ───────────────────────────────────────

# prerm: stop running app before upgrade/remove
cat > "${PACKAGE_DIR}/DEBIAN/prerm" << 'PRERM'
#!/bin/sh
set -e

# Gracefully stop any running Factory Desktop instance.
# Send SIGTERM only — the app handles cleanup, including
# in-progress droid agent operations.
if command -v killall >/dev/null 2>&1; then
    killall -q -TERM factory-desktop-bin 2>/dev/null || true
fi
exit 0
PRERM
chmod 755 "${PACKAGE_DIR}/DEBIAN/prerm"

# postinst: inform user about optional update checks
cat > "${PACKAGE_DIR}/DEBIAN/postinst" << 'POSTINST'
#!/bin/sh
set -e

echo ""
echo "Factory Desktop installed successfully."
echo ""
echo "Optional: enable automatic daily update checks:"
echo "  systemctl --user enable --now factory-desktop-update-check.timer"
echo ""

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi

exit 0
POSTINST
chmod 755 "${PACKAGE_DIR}/DEBIAN/postinst"

# ── Build the .deb ──────────────────────────────────────────────────

echo "[build-deb] Building ${DEB_NAME}.deb..."

mkdir -p "${DIST_DIR}"
dpkg-deb --build "${PACKAGE_DIR}" "${DIST_DIR}/${DEB_NAME}.deb"

echo "[build-deb] Done: ${DIST_DIR}/${DEB_NAME}.deb"
ls -lh "${DIST_DIR}/${DEB_NAME}.deb"
