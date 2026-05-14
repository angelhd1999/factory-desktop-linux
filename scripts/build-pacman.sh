#!/usr/bin/env bash
#
# Build an Arch Linux package (.pkg.tar.zst)
#
# Usage: bash scripts/build-pacman.sh [version]
#   version: defaults to what's in .current-version, or "0.0.0"
#
# Requires: GNU coreutils, zstd
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

echo "[build-pacman] Creating Arch package: $PKG_NAME-$VERSION-1-$ARCH"

rm -rf "$(dirname "$PKG_DIR")"
mkdir -p "$DEST_DIR"

# ── Copy application files ──────────────────────────────────────────

BUILD_DIR="$PROJECT_DIR/build"
cp "$BUILD_DIR/electron/"* "$DEST_DIR/"
mv "$DEST_DIR/electron" "$DEST_DIR/factory-desktop-bin" 2>/dev/null || true
cp "$BUILD_DIR/app.asar" "$DEST_DIR/resources/"

# ── droid wrapper ───────────────────────────────────────────────────

mkdir -p "$DEST_DIR/resources/bin"
cat > "$DEST_DIR/resources/bin/droid" << 'DROIDWRAPPER'
#!/usr/bin/env bash
exec droid "$@"
DROIDWRAPPER
chmod 755 "$DEST_DIR/resources/bin/droid"

# ── Launcher ────────────────────────────────────────────────────────

cp "$SCRIPT_DIR/launcher.sh" "$DEST_DIR/factory-desktop"
chmod 755 "$DEST_DIR/factory-desktop"

# ── Updater ─────────────────────────────────────────────────────────

cp "$SCRIPT_DIR/update.sh" "$DEST_DIR/factory-desktop-update"
chmod 755 "$DEST_DIR/factory-desktop-update"

# ── Symlinks ────────────────────────────────────────────────────────

mkdir -p "$PKG_DIR/usr/bin"
ln -sf /opt/factory-desktop/factory-desktop        "$PKG_DIR/usr/bin/factory-desktop"
ln -sf /opt/factory-desktop/factory-desktop-update  "$PKG_DIR/usr/bin/factory-desktop-update"

# ── Desktop entry ───────────────────────────────────────────────────

mkdir -p "$PKG_DIR/usr/share/applications"
cat > "$PKG_DIR/usr/share/applications/factory-desktop.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Factory Desktop
Comment=Droid AI coding assistant
Exec=factory-desktop
Type=Application
Categories=Development;
StartupWMClass=factory-desktop
DESKTOP

# ── Icon ────────────────────────────────────────────────────────────

mkdir -p "$PKG_DIR/usr/share/icons/hicolor/256x256/apps"
touch "$PKG_DIR/usr/share/icons/hicolor/256x256/apps/factory-desktop.png"

# ── .PKGINFO ───────────────────────────────────────────────────────

mkdir -p "$PKG_DIR/usr/share/doc/factory-desktop"
cat > "$PKG_DIR/.PKGINFO" << PKGINFO
pkgname = $PKG_NAME
pkgver = $VERSION-1
pkgdesc = Factory Desktop — AI coding assistant (community Linux port)
url = https://github.com/username/factory-desktop-linux
arch = $ARCH
license = MIT
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

# ── .MTREE ─────────────────────────────────────────────────────────

cd "$PKG_DIR"
bsdtar -czf .MTREE \
    --options '!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    opt usr .PKGINFO 2>/dev/null || true

# ── Package ─────────────────────────────────────────────────────────

DIST_DIR="$PROJECT_DIR/dist"
mkdir -p "$DIST_DIR"

PKG_FILE="$DIST_DIR/$PKG_NAME-$VERSION-1-$ARCH.pkg.tar.zst"

zstd -c -19 <(bsdtar -cf - opt usr .PKGINFO .MTREE) > "$PKG_FILE"

rm -rf "$(dirname "$PKG_DIR")"

echo "[build-pacman] Done: $PKG_FILE"
