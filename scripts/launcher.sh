#!/usr/bin/env bash
#
# Factory Desktop Launcher (Linux)
#
# This script starts the Factory Desktop app using the Linux Electron binary
# and the patched app.asar. It handles:
#   - Wayland/X11 detection
#   - GPU workarounds (opt-in, for broken drivers)
#

set -euo pipefail

# Resolve symlinks to find the real install directory
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
APP_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
ELECTRON_BIN="${APP_DIR}/factory-desktop-bin"
ASAR_PATH="${APP_DIR}/resources/app.asar"

# ── Pre-flight checks ──────────────────────────────────────────────

if [ ! -f "$ELECTRON_BIN" ]; then
    echo "ERROR: Electron binary not found at $ELECTRON_BIN" >&2
    echo "Run 'make electron' first." >&2
    exit 1
fi

if [ ! -f "$ASAR_PATH" ]; then
    echo "ERROR: app.asar not found at $ASAR_PATH" >&2
    echo "Run 'make build' first." >&2
    exit 1
fi

# ── Environment ─────────────────────────────────────────────────────

# Suppress library debug warnings (React, styled-components, Bluebird)
export NODE_ENV=production

# ── Debug logging to file ───────────────────────────────────────────

DEBUG_LOG="${HOME}/.local/state/factory-desktop/desktop-startups.log"
mkdir -p "$(dirname "$DEBUG_LOG")"
echo "[$(date -Iseconds)] Launcher starting (pid $$)" >> "$DEBUG_LOG"
echo "  ELECTRON_BIN: $ELECTRON_BIN" >> "$DEBUG_LOG"
echo "  ASAR_PATH:   $ASAR_PATH" >> "$DEBUG_LOG"
echo "  CWD:         $(pwd)" >> "$DEBUG_LOG"
echo "  DISPLAY:     ${DISPLAY:-unset}" >> "$DEBUG_LOG"
echo "  WAYLAND:     ${WAYLAND_DISPLAY:-unset}" >> "$DEBUG_LOG"

# ── Wayland / X11 detection ─────────────────────────────────────────

ELECTRON_ARGS=()

if [ "${WAYLAND_DISPLAY:-}" != "" ]; then
    # Under Wayland, prefer XWayland for better popup positioning.
    # If you want pure Wayland, set FACTORY_WAYLAND=1 in your environment.
    if [ "${FACTORY_WAYLAND:-0}" = "1" ]; then
        ELECTRON_ARGS+=(--ozone-platform-hint=auto)
        export GDK_BACKEND=wayland
    else
        ELECTRON_ARGS+=(--ozone-platform=x11)
    fi
fi

# ── GPU workarounds (opt-in for broken drivers) ─────────────────────

if [ "${FACTORY_DISABLE_GPU:-0}" = "1" ]; then
    ELECTRON_ARGS+=(--disable-gpu)
fi

if [ "${FACTORY_DISABLE_GPU_COMPOSITING:-0}" = "1" ]; then
    ELECTRON_ARGS+=(--disable-gpu-compositing)
fi

if [ "${FACTORY_DISABLE_GPU_SANDBOX:-0}" = "1" ]; then
    ELECTRON_ARGS+=(--disable-gpu-sandbox)
fi

if [ "${FACTORY_NO_SANDBOX:-0}" = "1" ]; then
    ELECTRON_ARGS+=(--no-sandbox)
fi

# ── Launch ──────────────────────────────────────────────────────────
# Electron discovers resources/app.asar automatically when placed next
# to the binary. Passing it as a CLI argument bypasses app.isPackaged detection.

echo "[factory-desktop] Starting Factory Desktop..."
echo "[factory-desktop] Binary:  $ELECTRON_BIN"
echo "[factory-desktop] App:     $ASAR_PATH"
echo "[factory-desktop] Debug log: $DEBUG_LOG"

exec "$ELECTRON_BIN" \
    "${ELECTRON_ARGS[@]}" \
    "$@" 2>>"$DEBUG_LOG"
