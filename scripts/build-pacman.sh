#!/usr/bin/env bash
#
# Build an Arch Linux package (.pkg.tar.zst)
#
# Usage: bash scripts/build-pacman.sh [version]
#   version: defaults to what's in .current-version, or "0.0.0"
#
# Requires: GNU coreutils, zstd, libarchive (bsdtar)
# Output:   dist/factory-desktop-<version>-1-x86_64.pkg.tar.zst
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION="${1:-$(cat "$PROJECT_DIR/.current-version" 2>/dev/null || echo "0.0.0")}"
ARCH="x86_64"
PKG_NAME="factory-desktop"
PKG_DIR="$PROJECT_DIR/build/pkg/$PKG_NAME"
DEST_DIR="$PKG_DIR/opt/factory-desktop"
ICON_SOURCE="$PROJECT_DIR/assets/factory-desktop.svg"

echo "[build-pacman] Creating Arch package: $PKG_NAME-$VERSION-1-$ARCH"

rm -rf "$(dirname "$PKG_DIR")"
mkdir -p "$DEST_DIR/resources"
mkdir -p "$DEST_DIR/resources/bin"

# ── Validate build artifacts exist ──────────────────────────────────

BUILD_DIR="$PROJECT_DIR/build"

if [ ! -f "$BUILD_DIR/app.asar" ]; then
    echo "ERROR: app.asar not found at $BUILD_DIR/app.asar" >&2
    echo "Run 'make asar' first." >&2
    exit 1
fi

if [ ! -f "$ICON_SOURCE" ]; then
    echo "ERROR: Factory icon not found at $ICON_SOURCE" >&2
    exit 1
fi

if [ ! -f "$BUILD_DIR/electron/electron" ] && [ ! -f "$BUILD_DIR/electron/factory-desktop-bin" ]; then
    echo "ERROR: Electron binary not found in $BUILD_DIR/electron/" >&2
    echo "Run 'make electron' first." >&2
    exit 1
fi

# ── Copy Electron runtime ───────────────────────────────────────────

cp -r "$BUILD_DIR/electron/"* "$DEST_DIR/"
mv "$DEST_DIR/electron" "$DEST_DIR/factory-desktop-bin" 2>/dev/null || true
rm -f "$DEST_DIR/resources/default_app.asar"

# ── Copy patched app.asar ───────────────────────────────────────────

cp "$BUILD_DIR/app.asar" "$DEST_DIR/resources/"

# ── droid wrapper ───────────────────────────────────────────────────

cat > "$DEST_DIR/resources/bin/droid" << 'DROIDWRAPPER'
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
DROIDWRAPPER
chmod 755 "$DEST_DIR/resources/bin/droid"

# ── Launcher ────────────────────────────────────────────────────────

cp "$SCRIPT_DIR/launcher.sh" "$DEST_DIR/factory-desktop"
chmod 755 "$DEST_DIR/factory-desktop"

# ── Updater ─────────────────────────────────────────────────────────

cp "$SCRIPT_DIR/update.sh" "$DEST_DIR/factory-desktop-update"
chmod 755 "$DEST_DIR/factory-desktop-update"

# ── Update check helper ─────────────────────────────────────────────

cp "$SCRIPT_DIR/factory-desktop-update-check.sh" "$DEST_DIR/factory-desktop-update-check"
chmod 755 "$DEST_DIR/factory-desktop-update-check"

# ── Symlinks ────────────────────────────────────────────────────────

mkdir -p "$PKG_DIR/usr/bin"
ln -sf /opt/factory-desktop/factory-desktop        "$PKG_DIR/usr/bin/factory-desktop"
ln -sf /opt/factory-desktop/factory-desktop-update  "$PKG_DIR/usr/bin/factory-desktop-update"

# ── Systemd user timer ──────────────────────────────────────────────

mkdir -p "$PKG_DIR/usr/lib/systemd/user"
cp "$SCRIPT_DIR/factory-desktop-update-check.service" "$PKG_DIR/usr/lib/systemd/user/"
cp "$SCRIPT_DIR/factory-desktop-update-check.timer"   "$PKG_DIR/usr/lib/systemd/user/"

# ── Desktop entry ───────────────────────────────────────────────────

mkdir -p "$PKG_DIR/usr/share/applications"
cat > "$PKG_DIR/usr/share/applications/factory-desktop.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Factory
Comment=AI-powered development agent
GenericName=AI Coding Agent
Exec=/opt/factory-desktop/factory-desktop
Icon=factory-desktop
Type=Application
Categories=Development;IDE;
Keywords=AI;agent;coding;droid;factory;
StartupWMClass=Factory
Terminal=false
DESKTOP

# ── Icon ────────────────────────────────────────────────────────────

mkdir -p "$PKG_DIR/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$PKG_DIR/usr/share/pixmaps"
cp "$ICON_SOURCE" "$PKG_DIR/usr/share/icons/hicolor/scalable/apps/factory-desktop.svg"
cp "$ICON_SOURCE" "$PKG_DIR/usr/share/pixmaps/factory-desktop.svg"

# ── .PKGINFO ───────────────────────────────────────────────────────

mkdir -p "$PKG_DIR/usr/share/doc/$PKG_NAME"
cat > "$PKG_DIR/.PKGINFO" << PKGINFO
pkgname = $PKG_NAME
pkgver = $VERSION-1
pkgdesc = Factory Desktop — AI-powered development agent (community Linux port)
url = https://github.com/angelhd1999/factory-desktop-linux
arch = $ARCH
license = custom:Factory EULA
depend = bash
depend = glibc
depend = libx11
depend = libxcb
depend = xcb-util-keysyms
depend = xcb-util-wm
depend = libxkbcommon
depend = fontconfig
depend = freetype2
PKGINFO

# ── .MTREE (optional, some bsdtar versions don't support) ──────────

cd "$PKG_DIR"
MTREE_CREATED=false
if bsdtar -czf .MTREE \
    --options '!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    opt usr .PKGINFO 2>/dev/null; then
    MTREE_CREATED=true
    echo "[build-pacman] .MTREE created"
else
    echo "[build-pacman] .MTREE skipped (bsdtar version doesn't support options flag)"
fi

# ── Package ─────────────────────────────────────────────────────────

DIST_DIR="$PROJECT_DIR/dist"
mkdir -p "$DIST_DIR"

PKG_FILE="$DIST_DIR/$PKG_NAME-$VERSION-1-$ARCH.pkg.tar.zst"

# Build tar archive and compress with zstd
# Use a temp file to avoid pipefail issues with process substitution
TEMP_TAR="$DIST_DIR/.factory-desktop-temp.tar"
if $MTREE_CREATED; then
    bsdtar -cf "$TEMP_TAR" opt usr .PKGINFO .MTREE
else
    bsdtar -cf "$TEMP_TAR" opt usr .PKGINFO
fi
zstd -19 "$TEMP_TAR" -o "$PKG_FILE"
rm -f "$TEMP_TAR"

rm -rf "$(dirname "$PKG_DIR")"

echo "[build-pacman] Done: $PKG_FILE"
