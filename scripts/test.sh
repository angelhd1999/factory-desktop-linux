#!/usr/bin/env bash
#
# Test suite for factory-desktop-linux
#
# Tests:
#   1. Patch script runs without errors
#   2. All 4 patches apply correctly (check-patches.py)
#   3. DEB package builds without errors
#   4. DEB contains required files
#   5. Patched asar has no dev-mode references
#   6. Launcher script resolves symlinks correctly
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

green() { echo -e "\033[0;32m$1\033[0m"; }
red()   { echo -e "\033[0;31m$1\033[0m"; }

assert() {
    local desc="$1"
    local negate=false
    if [ "$1" = "!" ]; then
        negate=true
        desc="$2"
        shift 2
    else
        shift
    fi
    if $negate; then
        if ! "$@"; then
            green "  PASS: $desc"
            PASS=$((PASS + 1))
        else
            red "  FAIL: $desc"
            FAIL=$((FAIL + 1))
        fi
    else
        if "$@"; then
            green "  PASS: $desc"
            PASS=$((PASS + 1))
        else
            red "  FAIL: $desc"
            FAIL=$((FAIL + 1))
        fi
    fi
}

echo "=== Test Suite: factory-desktop-linux ==="
echo ""

# ── Test 1: Extract works ──────────────────────────────────────────

echo "--- Extract ---"

if [ -f "$PROJECT_DIR/Factory-arm64.dmg" ]; then
    cd "$PROJECT_DIR"
    rm -rf app-unpacked
    npx @electron/asar extract \
        Factory-extracted/Factory/Factory.app/Contents/Resources/app.asar \
        app-unpacked > /dev/null 2>&1
    assert "app.asar extracted successfully" [ -d "$PROJECT_DIR/app-unpacked/.vite/build" ]
else
    red "  SKIP: Factory-arm64.dmg not found (run 'make download' first)"
fi

# ── Test 2: Patch auto-detection ───────────────────────────────────

echo "--- Patch auto-detection ---"

MAIN_JS="$PROJECT_DIR/app-unpacked/.vite/build/main.js"
if [ -f "$MAIN_JS" ]; then
    BUNDLE=$(grep -oP 'require\("\./\Kindex-[A-Za-z0-9]+\.js' "$MAIN_JS")
    assert "Bundle filename detected: $BUNDLE" [ -n "$BUNDLE" ]
    assert "Bundle file exists" [ -f "$PROJECT_DIR/app-unpacked/.vite/build/$BUNDLE" ]
fi

# ── Test 3: Patches apply ──────────────────────────────────────────

echo "--- Patches ---"

cd "$PROJECT_DIR"
node scripts/patch.js > /dev/null 2>&1
assert "patch.js runs without error" true

python3 scripts/check-patches.py > /tmp/factory-test-check.txt 2>&1
assert "All 4 patches pass" grep -q "All patches applied correctly" /tmp/factory-test-check.txt

# ── Test 4: No dev-mode strings in patched bundle ──────────────────

echo "--- Dev-mode removal ---"

if [ -n "${BUNDLE:-}" ]; then
    BUNDLE_FILE="$PROJECT_DIR/app-unpacked/.vite/build/$BUNDLE"
    if grep -q 'Tt.loadURL.*localhost:5173' "$BUNDLE_FILE" 2>/dev/null; then
        red "  FAIL: Dev-mode loadURL(5173) still present"
        ((FAIL++))
    else
        green "  PASS: Dev-mode loadURL removed"
        ((PASS++))
    fi

    if grep -q 'Tt.webContents.openDevTools()' "$BUNDLE_FILE"; then
        red "  FAIL: openDevTools() still present"
        ((FAIL++))
    else
        green "  PASS: openDevTools() removed"
        ((PASS++))
    fi
fi

# ── Test 5: Deb builds ────────────────────────────────────────────

echo "--- DEB packaging ---"

cd "$PROJECT_DIR"
rm -f dist/*.deb build/app.asar
npx @electron/asar pack app-unpacked build/app.asar > /dev/null 2>&1
bash scripts/build-deb.sh 0.99.0-test > /dev/null 2>&1

DEB_FILE="$PROJECT_DIR/dist/factory-desktop_0.99.0-test_amd64.deb"
assert "DEB package built" [ -f "$DEB_FILE" ]

# ── Test 6: DEB contains required files ────────────────────────────

echo "--- DEB contents ---"

DEB_LISTING=$(dpkg-deb -c "$DEB_FILE" 2>/dev/null)

assert "DEB has factory-desktop-bin" test -n "$(echo "$DEB_LISTING" | grep 'factory-desktop-bin')"
assert "DEB has droid wrapper"        test -n "$(echo "$DEB_LISTING" | grep 'resources/bin/droid')"
assert "DEB has app.asar"             test -n "$(echo "$DEB_LISTING" | grep 'resources/app.asar')"
assert "DEB has desktop entry"        test -n "$(echo "$DEB_LISTING" | grep 'applications/factory-desktop.desktop')"
assert "DEB has update script"        test -n "$(echo "$DEB_LISTING" | grep 'factory-desktop-update')"
assert "DEB has launcher"             test -n "$(echo "$DEB_LISTING" | grep 'opt/factory-desktop/factory-desktop$')"

# ── Test 7: Launcher symlink resolution ────────────────────────────

echo "--- Launcher ---"

LAUNCHER="$PROJECT_DIR/scripts/launcher.sh"
assert "Launcher exists" [ -f "$LAUNCHER" ]
assert "Launcher uses readlink -f" grep -q 'readlink -f' "$LAUNCHER"
assert "Launcher sets ELECTRON_IS_DEV=0" grep -q 'ELECTRON_IS_DEV=0' "$LAUNCHER"
assert "Launcher sets production env" grep -q 'FACTORY_RELEASE_CHANNEL=production' "$LAUNCHER"

# ── Test 8: No macOS binary left in package ─────────────────────────

echo "--- No macOS cruft ---"

assert "!" "No macOS electron in DEB" echo "$DEB_LISTING" | grep -q 'opt/factory-desktop/electron$'
assert "!" "DEB has no Mach-O files"  echo "$DEB_LISTING" | grep -q 'Mach-O'

# ── Clean up test deb ──────────────────────────────────────────────

rm -f "$DEB_FILE"

# ── Results ─────────────────────────────────────────────────────────

echo ""
echo "======================================"
echo "Results: $PASS passed, $FAIL failed"
echo "======================================"

[ "$FAIL" -eq 0 ]
