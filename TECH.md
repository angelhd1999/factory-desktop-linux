# Technical Documentation — Factory Desktop for Linux

## How it works

Factory Desktop is an **Electron** app (v39.2.7, bundle ID `com.electron.factory`). The `app.asar` inside the macOS `.dmg` contains platform-agnostic JavaScript. The port:

1. Downloads the official macOS DMG from `https://app.factory.ai/api/desktop?platform=darwin&architecture=arm64`
2. Extracts `app.asar` with `7z`
3. Auto-detects the Vite-bundled JS file (hash changes per release)
4. Patches 4 platform-specific checks in the JS bundle
5. Swaps the macOS Electron binary for a Linux Electron 39.2.7 binary
6. Packages for your distribution

## App architecture

```
Factory-arm64.dmg (~200 MB)
└── Factory.app/
    └── Contents/
        ├── Info.plist              → CFBundleIdentifier: com.electron.factory
        ├── MacOS/factory-desktop   → macOS Electron binary (replaced)
        ├── Frameworks/             → Electron helper apps (replaced)
        └── Resources/
            ├── app.asar (~60 MB)   → Vite-bundled JS (platform-agnostic)
            │   └── .vite/build/
            │       ├── main.js     → Entry point
            │       ├── index-XXXXXXXX.js → Main bundle (~2 MB minified)
            │       ├── index-XXXXXXXX.js → Renderer bundle
            │       └── preload.js  → Preload script
            └── bin/droid           → Droid CLI binary (replaced with wrapper)
```

## Patches applied

Only **4 changes** in the minified JS bundle. The bundle filename is auto-detected from `main.js`, so patches survive Vite hash changes across releases. Patch patterns use regex with `[\w$]{1,3}` wildcards to survive minified variable renames.

### Patch 1 — Auto-updater platform gate

```js
// FIND:  process.platform!=="darwin"&&process.platform!=="win32"
// REPLACE: process.platform!=="darwin"&&process.platform!=="win32"&&process.platform!=="linux"
```

Squirrel (Electron's native updater) only supports macOS and Windows. This adds Linux to the skip list explicitly.

### Patch 2 — Window-all-closed behavior

```js
// FIND:  /process\.platform!=="darwin"&&([\w$]{1,3})\.app\.quit\(\)/
// REPLACE: process.platform==="win32"&&$1.app.quit()
```

On macOS, closing all windows keeps the app running (tray/daemon). Linux should behave the same. Only Windows should quit.

### Patch 3 — Daemon binary name (verify only)

```js
// Confirmed correct: process.platform==="win32"?"droid.exe":"droid"
```

Already uses `"droid"` for non-Windows — works on Linux as-is.

### Patch 4 — Renderer file loading

```js
// FIND:  /([\w$]{1,3})\.app\.isPackaged\?([\w$]{1,3})\.loadFile\(([\w$]{1,3})\.join\(__dirname,"\.\.","renderer","main_window","index\.html"\)\):\(\2\.loadURL\("http:\/\/localhost:5173"\),\2\.webContents\.openDevTools\(\)\)/
// REPLACE: $2.loadFile($3.join(__dirname,"..","renderer","main_window","index.html"))
```

Electron's `isPackaged` detection is unreliable on Linux. The dev-mode branch (Vite dev server on `localhost:5173`) is removed entirely — the app always loads from the local file.

## Runtime details

- **Auth**: `keytar` loads dynamically at runtime, falls back to file-based encrypted storage in `~/.config/Factory/` when `libsecret` is unavailable. Works out of the box on all Linux distros.
- **Daemon**: The desktop app spawns `droid daemon` via a shell wrapper that calls the system-installed `droid` CLI. The wrapper filters incompatible flags (e.g., `--enable-code-server`).
- **Config**: Uses `electron-store` (JSON files) — cross-platform.
- **Shell env**: On macOS, sources the user's shell profile. On Linux, falls through to an empty env (acceptable — the bundled droid binary doesn't need shell env).
- **Diagnostics**: All platform-specific diagnostics (Windows domain check, endpoint protection, etc.) already return `"non-Windows platform; not applicable"` for Linux.
- **Updates**: A systemd user timer checks daily and shows a desktop notification via `notify-send` when a new version is available. Run `factory-desktop-update` to install.

## Project structure

```
factory-desktop-linux/
├── README.md                    → User-facing overview, install, update, legal
├── TECH.md                      → This file — full technical documentation
├── TROUBLESHOOTING.md           → Issue log and debugging guide
├── LICENSE                      → MIT (build scripts only)
├── Makefile                     → Build pipeline
├── .github/workflows/
│   ├── release.yml              → CI: build on tag push
│   └── daily-check.yml          → CI: daily version check + auto-release
├── scripts/
│   ├── patch.js                 → JS bundle patcher (auto-detects filename, regex-based)
│   ├── check-patches.py         → Patch verification (auto-detects filename, regex)
│   ├── auto-fix-patches.py      → Qwen-powered regex repair when patterns break
│   ├── launcher.sh              → Linux launcher (Wayland/X11, GPU, sandbox flags)
│   ├── build-deb.sh             → DEB packaging (includes prerm, postinst, systemd timer)
│   ├── build-rpm.sh             → RPM packaging
│   ├── build-pacman.sh          → Arch packaging
│   ├── update.sh                → factory-desktop-update command
│   ├── factory-desktop-update-check.sh  → Daily update checker (systemd timer)
│   ├── factory-desktop-update-check.service → systemd user service
│   ├── factory-desktop-update-check.timer  → systemd user timer
│   └── test.sh                  → Test suite (20 tests)
└── dist/                        → Built packages (not committed)
```

## Build from source

```bash
git clone https://github.com/angelhd1999/factory-desktop-linux.git
cd factory-desktop-linux
make all
sudo dpkg -i dist/factory-desktop_*.deb
```

### Make targets

| Target | Description |
|---|---|
| `make all` | Full pipeline (download + extract + patch + package) |
| `make download` | Download macOS DMG |
| `make extract` | Extract app.asar from DMG |
| `make patch` | Apply 4 Linux compatibility patches |
| `make check` | Verify all patches applied correctly |
| `make test` | Run full test suite (20 tests) |
| `make asar` | Repack patched files into app.asar |
| `make electron` | Download Linux Electron 39.2.7 |
| `make assemble` | Combine Electron + patched asar + droid wrapper |
| `make package` | Build .deb package |
| `make install-deb` | Install .deb with dpkg |
| `make run` | Launch app from build directory |
| `make clean` | Remove build artifacts |
| `make clean-all` | Remove everything including downloads |

### Manual steps (without Makefile)

```bash
# 1. Download DMG
curl -L -o Factory-arm64.dmg \
  "https://app.factory.ai/api/desktop?platform=darwin&architecture=arm64"

# 2. Extract
7z x -oFactory-extracted Factory-arm64.dmg \
  'Factory/Factory.app/Contents/Resources/app.asar' \
  'Factory/Factory.app/Contents/Resources/bin/*' -y

# 3. Unpack asar
npx @electron/asar extract \
  Factory-extracted/Factory/Factory.app/Contents/Resources/app.asar \
  app-unpacked

# 4. Patch
node scripts/patch.js
python3 scripts/check-patches.py

# 5. Repack
npx @electron/asar pack app-unpacked build/app.asar

# 6. Download Electron
curl -L -o build/electron.zip \
  "https://github.com/electron/electron/releases/download/v39.2.7/electron-v39.2.7-linux-x64.zip"
unzip -q build/electron.zip -d build/electron

# 7. Package
bash scripts/build-deb.sh $(cat .current-version)

# 8. Install
sudo dpkg -i dist/factory-desktop_*.deb
```

## Manual update (when automatic fails)

If `factory-desktop-update` fails (patch patterns changed in the new release):

```bash
cat .current-version
curl -s https://api.factory.ai/api/desktop/latest-version

# Edit Makefile: VERSION ?= <new-version>
make clean-all
make download
make extract
make patch
```

If patches warn `Pattern not found`, update `scripts/patch.js` with the new patterns:

- Open `app-unpacked/.vite/build/main.js` to find the bundle filename
- Search for the missing patterns in the bundle
- Update the `find` strings in `scripts/patch.js` and `scripts/check-patches.py`
- Re-run `rm -rf app-unpacked && make extract && make patch`

Known upstream variable renames:

| Old (≤0.82) | New (≥0.94) |
|---|---|
| `z.app.quit()` | `fe.app.quit()` |
| `Tt.loadFile` | `$t.loadFile` |
| `Ve.join` | `xe.join` |
| `z.app.isPackaged` | `fe.app.isPackaged` |

Then:

```bash
make check          # Should show 4 PASS
make asar electron assemble package
sudo dpkg -i dist/factory-desktop_<version>_amd64.deb
echo "<version>" > .current-version

git add -A && git commit -m "Update to v<version>" && git tag v<version>
```

## CI automation

Two GitHub Actions workflows:

| Workflow | Trigger | What it does |
|---|---|---|
| `release.yml` | Git tag push (`v*`) | Builds `.deb`, `.rpm`, `.pkg.tar.zst`; creates GitHub Release |
| `daily-check.yml` | Daily cron + manual | Checks Factory API for new versions; builds + releases automatically. If patches fail, Qwen (`qwen3.6` via nan.builders) auto-repairs the regex patterns. |

The daily cron publishes a new release within 24 hours of Factory shipping a new desktop version — no human intervention needed.

## Verification

```bash
make check
# Expected: 4 PASS

make test
# Expected: 20 passed, 0 failed
```

## Troubleshooting

| Problem | Likely cause | Solution |
|---|---|---|
| Black window with raw code after upgrade | Old process still running | The `prerm` script handles this automatically. If not, run `killall factory-desktop-bin` and restart. |
| Blank window on launch | Missing Electron binary | Run `make electron` |
| Auth loop / can't sign in | keytar unavailable | Factory falls back to file-based storage automatically — check `~/.config/Factory/` |
| Daemon fails to start | Droid CLI not installed or incompatible flag | Install droid CLI. The wrapper filters known incompatible flags. |
| GPU/sandbox errors | Electron sandboxing or GPU drivers | Use opt-in workarounds: `FACTORY_DISABLE_GPU=1`, `FACTORY_NO_SANDBOX=1` |
| Wayland window issues | Electron Ozone platform | Set `FACTORY_WAYLAND=1` for pure Wayland, or use XWayland (default) |

## Debugging

```bash
# Check installed version
dpkg -l factory-desktop

# Verify patches in installed app.asar
python3 scripts/check-patches.py

# Run with debug logging
ELECTRON_ENABLE_LOGGING=1 factory-desktop 2>&1 | tee /tmp/factory-debug.log

# Check daemon health
systemctl --user status factory-desktop-update-check.timer

# Kill stuck processes
killall factory-desktop-bin
```
