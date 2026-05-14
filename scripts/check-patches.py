#!/usr/bin/env python3
"""Verify that all Linux patches were applied correctly."""
import sys
import re
from pathlib import Path

BUILD_DIR = Path("app-unpacked/.vite/build")
MAIN_JS = BUILD_DIR / "main.js"

if not MAIN_JS.exists():
    print(f"ERROR: main.js not found at {MAIN_JS}")
    print("Run 'make extract && make patch' first.")
    sys.exit(1)

main_content = MAIN_JS.read_text()
m = re.search(r'require\("\./(index-[A-Za-z0-9]+\.js)"\)', main_content)
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
        'process.platform!=="darwin"&&process.platform!=="win32"&&process.platform!=="linux"' in content,
    ),
    (
        "Patch 2: window-all-closed keeps daemon alive on Linux",
        'process.platform==="win32"&&z.app.quit()' in content,
    ),
    (
        "Patch 3: daemon binary uses 'droid' on non-Windows",
        'process.platform==="win32"?"droid.exe":"droid"' in content,
    ),
    (
        "Patch 4: renderer loads from file unconditionally (dev branch removed)",
        'Tt.loadFile(Ve.join(__dirname,"..","renderer","main_window","index.html"))' in content
        and 'z.app.isPackaged?Tt.loadFile(' not in content,
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

sys.exit(0 if all_ok else 1)
