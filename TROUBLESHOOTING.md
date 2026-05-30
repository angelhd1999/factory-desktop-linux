# Troubleshooting Log — Factory Desktop Linux Port

> Records every issue encountered during porting, root cause, and resolution.
> Last updated: 2026-05-30

## Issue 1: App icon appears but doesn't launch

**Symptom:** Installed via double-click, icon in app list, clicking does nothing.

**Root cause:** Double-clicking a `.deb` on Linux Mint opens the archive manager (preview), not the installer. Package was never actually installed.

**Fix:** Install from terminal:
```bash
sudo dpkg -i dist/factory-desktop_0.82.0_amd64.deb
```

---

## Issue 2: `ERROR: Electron binary not found at /usr/bin/electron`

**Symptom:** Running `factory-desktop` prints error about missing Electron at `/usr/bin/electron`.

**Root cause:** The launcher script uses `BASH_SOURCE[0]` to find its directory, but `/usr/bin/factory-desktop` is a symlink to `/opt/factory-desktop/factory-desktop`. `dirname` on the symlink path returns `/usr/bin` instead of `/opt/factory-desktop`.

**Fix:** Use `readlink -f` to resolve symlinks before `dirname`:
```bash
# BEFORE (broken):
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# AFTER (fixed):
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
APP_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
```

---

## Issue 3: `FATAL: chrome_crashpad_handler: No such file or directory`

**Symptom:** App crashes on startup with crashpad error; process can't be killed with Ctrl+C.

**Root cause:** The build script used fragile glob patterns (`*.pak`, `*.bin`, `*.dat`, `*.so`) to copy Electron runtime files. Files without matching extensions were skipped:
- `chrome_crashpad_handler` (no extension)
- `chrome-sandbox` (no extension)
- `libvulkan.so.1` (`.so.1` doesn't match `*.so`)

**Fix:** Copy everything with `cp -r .../*`:
```bash
# BEFORE (broken — missed extensionless files):
cp build/electron/*.pak /opt/factory-desktop/
cp build/electron/*.so /opt/factory-desktop/

# AFTER (fixed):
cp -r build/electron/* /opt/factory-desktop/
```

---

## Issue 4: White window OR opens other localhost app

**Symptom:** App launches but shows a blank white window, or opens another Vite dev server project running on `localhost:5173` with Chrome DevTools open.

**Root cause:** Electron's `app.isPackaged` property returns `false`, causing the app to take the **dev-mode code path** which connects to `localhost:5173` (Vite dev server).

Why `isPackaged` was false — three contributing factors:

| Factor | Detail | Fix attempt | Result |
|---|---|---|---|
| Executable name | Binary was named `electron` → `isPackaged` returns false | Renamed to `factory-desktop-bin` | Didn't help alone |
| CLI arg passthrough | Passing `app.asar` as positional arg bypasses packaged detection | Removed asar from CLI, rely on `resources/` auto-discovery | Didn't help alone |
| Electron 39 behavior | Even with correct layout, Electron 39 may not detect packaged state in some configurations | Added `\|\|"linux"===process.platform` to the ternary | **Still failed** — ternary didn't resolve as expected |

**Final fix — remove the conditional entirely:**

The original code:
```js
z.app.isPackaged
  ? Tt.loadFile(Ve.join(__dirname, "..", "renderer", "main_window", "index.html"))
  : (Tt.loadURL("http://localhost:5173"), Tt.webContents.openDevTools())
```

Patched to (unconditional):
```js
Tt.loadFile(Ve.join(__dirname, "..", "renderer", "main_window", "index.html"))
```

This is the nuclear option — the dev-mode branch is completely removed from the bundle. The app always loads from the local file. This is safe because:
1. The renderer HTML is bundled inside `app.asar` at `.vite/renderer/main_window/index.html`
2. We never need the Vite dev server connection in production
3. This is the same approach used by the `codex-desktop-linux` and `claude-desktop-debian` ports

**Key lesson:** When patching minified JS, the exact byte sequence matters. Our intermediate patch (`||"linux"===process.platform`) was applied to a previously-patched file but the fresh extract had the original string. Always extract fresh before applying patches.

---

## Patch verification checklist

Run after every build:
```bash
make check
```

Expected output:
```
  PASS: Patch 1: auto-updater skips Linux gracefully
  PASS: Patch 2: window-all-closed keeps daemon alive on Linux
  PASS: Patch 3: daemon binary uses 'droid' on non-Windows
  PASS: Patch 4: renderer loads from file unconditionally (dev branch removed)
  All patches applied correctly.
```

## Debugging tips

### Check what's actually installed
```bash
# Verify the asar has patches
npx @electron/asar extract /opt/factory-desktop/resources/app.asar /tmp/check
grep -c 'Tt.loadFile' /tmp/check/.vite/build/index-BuZI_fTi.js
grep 'localhost:5173' /tmp/check/.vite/build/index-BuZI_fTi.js  # should be empty

# Verify binary is renamed
ls -la /opt/factory-desktop/factory-desktop-bin

# Verify resources/ layout
ls -la /opt/factory-desktop/resources/
```

### Kill stuck processes
```bash
pkill -f "/opt/factory-desktop/factory-desktop-bin"
pkill -f "factory-desktop"
```

### Run with debug logging
```bash
ELECTRON_ENABLE_LOGGING=1 factory-desktop 2>&1 | tee /tmp/factory-debug.log
```

---

## Issue 5: Daemon crashes instantly — exit code 2

**Symptom:** App opens but shows "Could not connect to local computer." Logs show daemon crash with exit code 2, lifetime under 10ms, phase=spawn.

**Root cause:** The `droid` binary from the macOS DMG is a **Mach-O** binary (macOS format). Linux rejects it immediately (exit code 2). Also, binary was at `bin/droid` but code resolves `process.resourcesPath + "bin/droid"` = `resources/bin/droid`.

**Fix:**
1. Move to correct path: `resources/bin/droid`
2. Replace macOS binary with shell wrapper calling system `droid`:

```bash
#!/usr/bin/env bash
exec droid "$@"
```

Requires Droid CLI installed separately. Side effect: deb dropped from 156 MB to 121 MB.

---

## Final state

After all 5 fixes, Factory Desktop 0.82.0 runs on Linux Mint:
- Full UI (renderer loads from local file)
- Daemon (via system `droid` CLI wrapper)
- Auth (file-based key storage)
- No dev mode interference

---

## Issue 6: Updates break patches (v0.82.0 → v0.82.1)

**Symptom:** After updating with `factory-desktop-update`, two patches fail with "Pattern not found in bundle."

**Root cause:** Vite renames the JS bundle hash on every build. v0.82.0 used `index-BuZI_fTi.js`; v0.82.1 uses `index-DmCwv4XY.js`. The patch script had the filename hardcoded.

**Fix:** The patch and check scripts now **auto-detect** the bundle filename by reading `main.js`:
```js
// main.js always contains:
require("./index-XXXXXXXX.js");
```
The scripts extract the hash from this require statement. This makes the port resilient to Vite hash changes across releases.

**Note:** If Factory significantly restructures the JS bundle between releases, individual patch patterns may still need updating. The scripts fail-soft (warn but don't crash) when a pattern isn't found.

---

## Issue 7: Variable renames break patches (v0.82.1 → v0.94.1)

**Symptom:** `make patch` reports "Pattern not found" for patches 2 and 4 (window-all-closed and renderer).

**Root cause:** Upstream Factory Desktop changed internal variable names in their minified JS bundle between releases. Vite's minifier uses short variable names (`z`, `Tt`, `Ve`, etc.) which are not stable across builds. The new release assigned different names.

**Renames identified:**

| Old name (v0.82) | New name (v0.94) | Context |
|---|---|---|
| `z.app` | `fe.app` | Electron app reference |
| `Tt` | `$t` | BrowserWindow instance |
| `Ve` | `xe` | Path module alias |

**Fix:** Update both `scripts/patch.js` and `scripts/check-patches.py` to use the new variable names. Run `rm -rf app-unpacked && make extract && make patch` to re-apply against a fresh extraction.

**Pattern updates:**
- Patch 2: `process.platform!=="darwin"&&z.app.quit()` → `process.platform!=="darwin"&&fe.app.quit()`
- Patch 4: `z.app.isPackaged?Tt.loadFile(Ve.join(...)...` → `fe.app.isPackaged?$t.loadFile(xe.join(...)...`
- Check 2: `z.app.quit()` → `fe.app.quit()`
- Check 4: `Tt.loadFile(Ve.join(...)` → `$t.loadFile(xe.join(...)`

**Also fixed:** The auto-updater patch (Patch 1) verification was showing "Replaced 0 occurrence(s)" even though the patch worked. This was because the replacement string contains the original pattern as a substring (adding `&&process.platform!=="linux"` to the existing condition). Verification now checks for the new string presence instead of counting remaining matches.

**Key lesson:** Vite-shortened variable names are NOT stable across releases. The patching approach is fundamentally sound — we search for the business logic pattern (e.g., `process.platform!=="darwin"&&X.app.quit()` where `X` is some minified variable). But when the whole variable prefix changes (entire `Tt` object renamed to `$t`), we need to inspect the bundle and update our search strings. The fix is mechanical: find the old semantics in the new bundle, copy the exact byte sequence, and update the scripts.
