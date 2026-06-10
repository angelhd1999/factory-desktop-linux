#!/usr/bin/env bash
#
# Build an .rpm package for Fedora / RHEL / OpenSUSE
#
# Usage: bash scripts/build-rpm.sh [version]
#   version: defaults to what's in .current-version, or "0.0.0"
#
# Requires: rpm-build (dnf install rpm-build)
# Output:   dist/factory-desktop_<version>_x86_64.rpm
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION="${1:-$(cat "$PROJECT_DIR/.current-version" 2>/dev/null || echo "0.0.0")}"
ARCH="x86_64"
RPM_NAME="factory-desktop-${VERSION}-1.${ARCH}"

PACKAGE_DIR="$PROJECT_DIR/build/rpm-build"
RPM_ROOT="$PACKAGE_DIR/root"
DEST_DIR="$RPM_ROOT/opt/factory-desktop"
ICON_SOURCE="$PROJECT_DIR/assets/factory-desktop.svg"

echo "[build-rpm] Creating RPM package: $RPM_NAME"

if [ ! -f "$ICON_SOURCE" ]; then
    echo "ERROR: Factory icon not found at $ICON_SOURCE" >&2
    exit 1
fi

rm -rf "$PACKAGE_DIR"
mkdir -p "$DEST_DIR"

# ── Copy application files (same as deb) ────────────────────────────

BUILD_DIR="$PROJECT_DIR/build"
cp "$BUILD_DIR/electron/"* "$DEST_DIR/"
mv "$DEST_DIR/electron" "$DEST_DIR/factory-desktop-bin" 2>/dev/null || true
cp "$BUILD_DIR/app.asar" "$DEST_DIR/resources/"

# ── droid wrapper (calls system droid) ──────────────────────────────

mkdir -p "$DEST_DIR/resources/bin"
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

# ── Symlinks ────────────────────────────────────────────────────────

mkdir -p "$RPM_ROOT/usr/bin"
ln -sf /opt/factory-desktop/factory-desktop        "$RPM_ROOT/usr/bin/factory-desktop"
ln -sf /opt/factory-desktop/factory-desktop-update  "$RPM_ROOT/usr/bin/factory-desktop-update"

# ── Desktop entry ───────────────────────────────────────────────────

mkdir -p "$RPM_ROOT/usr/share/applications"
cat > "$RPM_ROOT/usr/share/applications/factory-desktop.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Factory Desktop
Comment=Droid AI coding assistant
Exec=factory-desktop
Icon=factory-desktop
Type=Application
Categories=Development;
StartupWMClass=Factory
DESKTOP

# ── Icon ────────────────────────────────────────────────────────────

mkdir -p "$RPM_ROOT/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$RPM_ROOT/usr/share/pixmaps"
cp "$ICON_SOURCE" "$RPM_ROOT/usr/share/icons/hicolor/scalable/apps/factory-desktop.svg"
cp "$ICON_SOURCE" "$RPM_ROOT/usr/share/pixmaps/factory-desktop.svg"

# ── Build with rpmbuild ────────────────────────────────────────────

SPEC_FILE="$PACKAGE_DIR/factory-desktop.spec"
cat > "$SPEC_FILE" << SPECEOF
Name:           factory-desktop
Version:        ${VERSION}
Release:        1
Summary:        Factory Desktop — AI coding assistant (community Linux port)
License:        Proprietary (Factory Desktop)
Group:          Development/Tools
URL:            https://github.com/username/factory-desktop-linux
Requires:       bash, glibc, libX11, libxcb, libxkbcommon, libdrm

%description
Community Linux port of Factory Desktop, built from the official macOS DMG.
This package does not redistribute any Factory software — it provides build
scripts and Linux compatibility patches.

%install
cp -r %{_builddir}/root/* %{buildroot}/

%files
/opt/factory-desktop
/usr/bin/factory-desktop
/usr/bin/factory-desktop-update
/usr/share/applications/factory-desktop.desktop
/usr/share/icons/hicolor/scalable/apps/factory-desktop.svg
/usr/share/pixmaps/factory-desktop.svg

%changelog
* $(date '+%a %b %d %Y') Community Maintainer <dev@example.com> ${VERSION}-1
- Community Linux port release
SPECEOF

# rpmbuild needs a specific directory layout
mkdir -p "$PACKAGE_DIR/BUILD" "$PACKAGE_DIR/RPMS" "$PACKAGE_DIR/SOURCES" "$PACKAGE_DIR/SPECS" "$PACKAGE_DIR/SRPMS"
cp -r "$RPM_ROOT" "$PACKAGE_DIR/BUILD/"

RPM_OUT="$PROJECT_DIR/dist"
mkdir -p "$RPM_OUT"

HOME="$PACKAGE_DIR" rpmbuild \
    --define "_topdir $PACKAGE_DIR" \
    --define "_builddir $PACKAGE_DIR/BUILD" \
    -bb "$SPEC_FILE"

# Move RPM to dist/
cp "$PACKAGE_DIR"/RPMS/*/factory-desktop-*.rpm "$RPM_OUT/" 2>/dev/null || true
rm -rf "$PACKAGE_DIR"

echo "[build-rpm] Done: $RPM_OUT/factory-desktop-${VERSION}-1.${ARCH}.rpm"
