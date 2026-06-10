#!/usr/bin/env python3
"""Verify that all Linux patches were applied correctly.

Uses regex checks that survive Vite minified variable renames
(e.g., z→fe, Tt→$t, Ve→xe). Also validates JS syntax."""

import sys
import re
import subprocess
from pathlib import Path

BUILD_DIR = Path("app-unpacked/.vite/build")
MAIN_JS = BUILD_DIR / "main.js"

if not MAIN_JS.exists():
    print(f"ERROR: main.js not found at {MAIN_JS}")
    print("Run 'make extract && make patch' first.")
    sys.exit(1)

main_content = MAIN_JS.read_text()
m = re.search(r'require\("\./(index-[A-Za-z0-9_-]+\.js)"\)', main_content)
if not m:
    print(f"ERROR: Could not detect bundle filename from {MAIN_JS}")
    sys.exit(1)

bundle_name = m.group(1)
bundle_path = BUILD_DIR / bundle_name

if not bundle_path.exists():
    print(f"ERROR: Bundle not found: {bundle_path}")
    sys.exit(1)

content = bundle_path.read_text(errors="replace")
print(f"[check] Bundle: {bundle_name}")

checks = [
    (
        "Patch 1: auto-updater skips Linux gracefully",
        'process.platform!=="linux"' in content,
    ),
    (
        "Patch 2: window-all-closed keeps daemon alive on Linux",
        # Should contain: process.platform==="win32"&&X.app.quit()
        # Should NOT contain: process.platform!=="darwin"&&X.app.quit()
        bool(re.search(
            r'process\.platform==="win32"&&[\w$]{1,3}\.app\.quit\(\)',
            content
        )) and not bool(re.search(
            r'window-all-closed.*?process\.platform!=="darwin"&&[\w$]{1,3}\.app\.quit\(\)',
            content
        )),
    ),
    (
        "Patch 3: daemon binary uses 'droid' on non-Windows",
        'process.platform==="win32"?"droid.exe":"droid"' in content,
    ),
    (
        "Patch 4: renderer loads from file unconditionally (dev branch removed)",
        # Should contain: X.loadFile(Y.join(__dirname,"..","renderer"...))
        # Should NOT contain: X.app.isPackaged?Y.loadFile(...):(Y.loadURL(...)
        bool(re.search(
            r'[\w$]{1,3}\.loadFile\([\w$]{1,3}\.join\(__dirname,"\.\.","renderer","main_window","index\.html"\)\)',
            content
        )) and not bool(re.search(
            r'[\w$]{1,3}\.app\.isPackaged\?[\w$]{1,3}\.loadFile\([\w$]{1,3}\.join\(__dirname,"\.\.","renderer","main_window","index\.html"\)\):',
            content
        )),
    ),
    (
        "Patch 5: Linux uses native window title bar controls",
        bool(re.search(
            r'const [\w$]{1,3}=process\.platform==="win32"\|\|process\.platform==="linux";[\w$]{1,3}=new [\w$]{1,3}\.BrowserWindow\(\{backgroundColor:',
            content
        )),
    ),
]

all_ok = True
for name, ok in checks:
    status = "PASS" if ok else "FAIL"
    print(f"  {status}: {name}")
    if not ok:
        all_ok = False

if all_ok:
    print("\nAll patches applied correctly.")
else:
    print("\nSome patches failed. Re-run 'make patch'.")

# ── JS syntax validation ────────────────────────────────────────────

result = subprocess.run(
    ["node", "-e",
     f"new Function(require('fs').readFileSync('{bundle_path}', 'utf-8'))"],
    capture_output=True, text=True
)
if result.returncode == 0:
    print("JS syntax validation: PASS")
else:
    print(f"JS syntax validation: FAIL — {result.stderr.strip()}")
    all_ok = False

sys.exit(0 if all_ok else 1)
