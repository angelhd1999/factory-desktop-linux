#!/usr/bin/env bash
#
# Daily update check for Factory Desktop Linux.
# Called by systemd user timer. Shows desktop notification if update available.
#
set -euo pipefail

LATEST=$(curl -sf "https://api.factory.ai/api/desktop/latest-version" 2>/dev/null | \
    grep -oP '"latestVersion"\s*:\s*"\K[^"]+' || echo "")

if [ -z "$LATEST" ]; then
    exit 0
fi

CURRENT=$(cat /opt/factory-desktop/version 2>/dev/null || echo "0")
# version file contains Electron version, not Factory version — use dpkg instead
CURRENT=$(dpkg-query -W -f='${Version}' factory-desktop 2>/dev/null || echo "0")

if [ "$CURRENT" = "$LATEST" ]; then
    exit 0
fi

# Update available — notify user
if command -v notify-send >/dev/null 2>&1; then
    notify-send \
        --app-name="Factory Desktop" \
        --icon=factory-desktop \
        --urgency=normal \
        --category=system \
        "Factory Desktop Update Available" \
        "Version $LATEST is available (current: $CURRENT). Run 'factory-desktop-update' to install."
fi
