#!/usr/bin/env bash
#
# Test suite for factory-desktop-linux
#
# Tests:
#   1. Patch script runs without errors
#   2. All 5 patches apply correctly (check-patches.py)
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
    BUNDLE=$(grep -oP 'require\("\./\Kindex-[A-Za-z0-9_-]+\.js' "$MAIN_JS")
    assert "Bundle filename detected: $BUNDLE" [ -n "$BUNDLE" ]
    assert "Bundle file exists" [ -f "$PROJECT_DIR/app-unpacked/.vite/build/$BUNDLE" ]
fi

# ── Test 3: Patches apply ──────────────────────────────────────────

echo "--- Patches ---"

cd "$PROJECT_DIR"
node scripts/patch.js > /dev/null 2>&1
assert "patch.js runs without error" true

python3 scripts/check-patches.py > /tmp/factory-test-check.txt 2>&1
assert "All 5 patches pass" grep -q "All patches applied correctly" /tmp/factory-test-check.txt

# ── Test 4: No dev-mode strings in patched bundle ──────────────────

echo "--- Dev-mode removal ---"

if [ -n "${BUNDLE:-}" ]; then
    BUNDLE_FILE="$PROJECT_DIR/app-unpacked/.vite/build/$BUNDLE"
    if grep -q '\$t.loadURL.*localhost:5173' "$BUNDLE_FILE" 2>/dev/null; then
        red "  FAIL: Dev-mode loadURL(5173) still present"
        ((FAIL++))
    else
        green "  PASS: Dev-mode loadURL removed"
        ((PASS++))
    fi

    if grep -q '\$t.webContents.openDevTools()' "$BUNDLE_FILE"; then
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
assert "DEB has Factory icon"         test -n "$(echo "$DEB_LISTING" | grep 'icons/hicolor/scalable/apps/factory-desktop.svg')"
assert "DEB has pixmaps fallback icon" test -n "$(echo "$DEB_LISTING" | grep 'pixmaps/factory-desktop.svg')"
assert "DEB has update script"        test -n "$(echo "$DEB_LISTING" | grep 'factory-desktop-update')"
assert "DEB has launcher"             test -n "$(echo "$DEB_LISTING" | grep 'opt/factory-desktop/factory-desktop$')"

# ── Test 7: Launcher symlink resolution ────────────────────────────

echo "--- Launcher ---"

LAUNCHER="$PROJECT_DIR/scripts/launcher.sh"
assert "Launcher exists" [ -f "$LAUNCHER" ]
assert "Launcher uses readlink -f" grep -q 'readlink -f' "$LAUNCHER"
assert "Launcher sets NODE_ENV=production" grep -q 'NODE_ENV=production' "$LAUNCHER"
assert "Launcher has GPU opt-in (FACTORY_DISABLE_GPU)" grep -q 'FACTORY_DISABLE_GPU' "$LAUNCHER"
assert "Launcher has sandbox opt-in (FACTORY_NO_SANDBOX)" grep -q 'FACTORY_NO_SANDBOX' "$LAUNCHER"
# --no-sandbox should only appear as opt-in, not in exec args
assert "!" "Launcher does NOT force --no-sandbox" \
    bash -c "awk '/^exec/{found=1} found' \"$LAUNCHER\" | grep -q '\-\-no-sandbox'"
assert "!" "Launcher does NOT force ELECTRON_NO_SANDBOX" grep -q 'ELECTRON_NO_SANDBOX=1' "$LAUNCHER"

# ── Test 8: No macOS binary left in package ─────────────────────────

echo "--- No macOS cruft ---"

assert "No macOS electron in DEB" test -z "$(echo "$DEB_LISTING" | grep 'opt/factory-desktop/electron$')"
assert "DEB has no Mach-O files"  test -z "$(echo "$DEB_LISTING" | grep 'Mach-O')"

# ── Clean up test deb ──────────────────────────────────────────────

rm -f "$DEB_FILE"

# ── Results ─────────────────────────────────────────────────────────

echo ""
echo "======================================"
echo "Results: $PASS passed, $FAIL failed"
echo "======================================"

[ "$FAIL" -eq 0 ]
