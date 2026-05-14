# Factory Desktop for Linux

Community Linux port of the [Factory Desktop](https://factory.ai/product/desktop) app. The official desktop app is macOS/Windows only — this project converts the upstream macOS `Factory.dmg` into a runnable Linux Electron app.

**Packages available:**
- [`.deb`](https://github.com/YOUR_USER/factory-desktop-linux/releases) (Debian/Ubuntu/Mint/Pop!_OS)
- [`.rpm`](https://github.com/YOUR_USER/factory-desktop-linux/releases) (Fedora/RHEL/openSUSE)
- [`.pkg.tar.zst`](https://github.com/YOUR_USER/factory-desktop-linux/releases) (Arch/Manjaro/EndeavourOS)

## How it works

Factory Desktop is an **Electron** app (v39.2.7, bundle ID `com.electron.factory`). The `app.asar` inside the macOS `.dmg` contains platform-agnostic JavaScript. The port:

1. Downloads the official macOS DMG from `https://app.factory.ai/api/desktop?platform=darwin&architecture=arm64`
2. Extracts `app.asar` with `7z`
3. Auto-detects the Vite-bundled JS file (hash changes per release)
4. Patches 4 platform-specific checks in the JS bundle
5. Swaps the macOS Electron binary for a Linux Electron 39.2.7 binary
6. Packages for your distribution

## Why this is simpler than other ports

Unlike Codex Desktop or Claude Desktop which have dozens of native Node modules and complex patches:

| What | Factory Desktop |
|---|---|
| Native `.node` modules bundled in asar | **None** |
| Auth storage | `keytar` loads dynamically at runtime, falls back to file-based storage on Linux |
| Daemon binary | Already uses `"droid"` for non-Windows — works on Linux as-is |
| Config storage | `electron-store` (JSON files) — cross-platform |
| Build system | Electron Forge with `maker-deb` and `maker-rpm` already configured |

## Patches applied

Only **4 changes** are needed in the minified JS bundle. The bundle filename is auto-detected from `main.js`'s `require()` call, so patches survive Vite hash changes across releases.

### 1. Auto-updater platform gate (offset ~1523100)

```js
// BEFORE:
process.platform!=="darwin"&&process.platform!=="win32"
// → skips updater entirely on Linux

// AFTER:
process.platform!=="darwin"&&process.platform!=="win32"&&process.platform!=="linux"
// → skips updater on unsupported platforms (Squirrel doesn't support Linux)
```

The auto-updater remains disabled on Linux since Squirrel (Electron's native updater) only supports macOS and Windows.

### 2. Window-all-closed behavior (offset near lifecycle init)

```js
// BEFORE:
process.platform!=="darwin"&&z.app.quit()
// → quits app when all windows close on non-macOS (kills daemon/tray)

// AFTER:
process.platform==="win32"&&z.app.quit()
// → only Windows quits on window close; Linux keeps running like macOS
```

Linux needs to keep the daemon and tray icon alive when the window is closed, matching macOS behavior.

### 3. Menu bar placement

Already correct — the code uses `process.platform==="darwin"` for native menu bar; Linux falls through to in-window menus like Windows. No change needed.

## App architecture (from analysis)

```
Factory-arm64.dmg (187 MB)
└── Factory.app/
    └── Contents/
        ├── Info.plist              → CFBundleIdentifier: com.electron.factory, version 0.82.0
        ├── MacOS/factory-desktop   → macOS Electron 39.2.7 binary (replaced)
        ├── Frameworks/             → Electron helper apps (replaced)
        └── Resources/
            ├── app.asar (49.5 MB)  → Vite-bundled JS (platform-agnostic)
            │   └── .vite/build/
            │       ├── main.js     → Entry point (requires index-BuZI_fTi.js)
            │       ├── index-BuZI_fTi.js → Main bundle (~8 MB minified)
            │       ├── index-B5z4OMzu.js → Renderer bundle
            │       └── preload.js  → Preload script
            └── bin/droid (109 MB)  → Droid CLI binary (bundled, already Linux-compatible)
```

## Project structure

```
factory-desktop-linux/
├── README.md                    → This file
├── TROUBLESHOOTING.md           → Common issues and fixes
├── LICENSE                      → MIT (build scripts only — not Factory's software)
├── Makefile                     → Build pipeline (make all)
├── .github/workflows/release.yml → CI/CD: auto-build on tags + daily version check
├── scripts/
│   ├── patch.js                 → JS bundle patcher (auto-detects filename, 4 patches)
│   ├── check-patches.py         → Patch verification (auto-detects filename, fail-safe)
│   ├── launcher.sh              → Linux launcher (Wayland/X11, GPU, sandbox flags)
│   ├── build-deb.sh             → DEB packaging (.deb)
│   ├── build-rpm.sh             → RPM packaging (.rpm)
│   ├── build-pacman.sh          → Arch packaging (.pkg.tar.zst)
│   ├── update.sh                → Auto-updater (checks Factory API, rebuilds, installs)
│   └── test.sh                  → Test suite (extraction, patches, DEB contents)
└── dist/                        → Built packages (not committed — download from releases)
```

### Key runtime details

- **Auth**: Uses `keytar` for secure credential storage (macOS Keychain / Windows Credential Vault). On Linux, `keytar` attempts to load `libsecret` at runtime. If unavailable, falls back to **file-based encrypted storage** in `~/.config/Factory/`. This means Linux works out of the box without any keyring setup.

- **Daemon**: The desktop app spawns a `droid daemon` process from the bundled `bin/droid` binary. The binary path logic already handles non-Windows correctly (`process.platform==="win32"?"droid.exe":"droid"`).

- **Shell environment**: On macOS, it sources the user's shell profile to inherit env vars. On Linux, it falls through to an empty env (which is acceptable — the bundled droid binary doesn't need shell env for basic operation).

- **Diagnostics**: All platform-specific diagnostics (Windows domain check, endpoint protection, etc.) already return `"non-Windows platform; not applicable"` for Linux.

## Requirements

- **Linux** (Debian/Ubuntu/Mint tested; other distros untested)
- `bash`, `curl`, `7z` (p7zip-full), `git`
- Node.js 22+ (for asar extraction and JS patching)
- The **Droid CLI** should already be installed (`curl -fsSL https://app.factory.ai/cli | sh`)

## Quick install (pre-built packages)

### Debian / Ubuntu / Mint / Pop!_OS

```bash
# Download the latest .deb from releases, then:
sudo dpkg -i factory-desktop_*.deb
sudo apt-get install -f  # fix any missing dependencies
```

### Fedora / RHEL

```bash
sudo rpm -ivh factory-desktop-*.rpm
```

### Arch Linux / Manjaro

```bash
sudo pacman -U factory-desktop-*.pkg.tar.zst
```

## Build from source (any distro)

```bash
git clone https://github.com/YOUR_USER/factory-desktop-linux.git
cd factory-desktop-linux
make all            # Downloads Factory DMG, extracts, patches, packages
sudo dpkg -i dist/factory-desktop_*.deb  # or your distro's equivalent
```

Or step by step:

```bash
make download       # Downloads Factory-arm64.dmg (~187 MB)
make extract        # Extracts app.asar from DMG
make patch          # Applies 4 JS bundle patches
make check          # Verifies all patches applied correctly
make asar           # Repacks patched bundle into app.asar
make electron       # Downloads Linux Electron 39.2.7
make assemble       # Combines patched asar + Linux Electron + droid wrapper
make package        # Builds .deb (default)
bash scripts/build-rpm.sh    # Or: build .rpm
bash scripts/build-pacman.sh # Or: build .pkg.tar.zst
```

### Make targets

| Target | Description |
|---|---|
| `make all` | Full pipeline (download + extract + patch + package) |
| `make download` | Download macOS DMG and check latest version |
| `make extract` | Extract app.asar from DMG |
| `make patch` | Apply 4 Linux compatibility patches |
| `make check` | Verify all patches applied correctly |
| `make test` | Run full test suite |
| `make asar` | Repack patched files into app.asar |
| `make electron` | Download Linux Electron 39.2.7 |
| `make assemble` | Combine Electron + patched asar + droid wrapper |
| `make package` | Build .deb package |
| `make install` | Install .deb with dpkg |
| `make run` | Launch app from build directory (no install needed) |
| `make update` | Rebuild from latest upstream version |
| `make clean` | Remove build artifacts |
| `make clean-all` | Remove everything including downloads |

## Manual steps (without Makefile)

```bash
# 1. Download DMG
curl -L -o Factory-arm64.dmg \
  "https://app.factory.ai/api/desktop?platform=darwin&architecture=arm64"

# 2. Extract app.asar and bin/droid
7z x -oFactory-extracted Factory-arm64.dmg \
  'Factory/Factory.app/Contents/Resources/app.asar' \
  'Factory/Factory.app/Contents/Resources/bin/*' -y

# 3. Unpack asar
npx @electron/asar extract \
  Factory-extracted/Factory/Factory.app/Contents/Resources/app.asar \
  app-unpacked

# 4. Apply Linux patches
node scripts/patch.js

# 5. Verify patches
python3 scripts/check-patches.py

# 6. Repack asar
npx @electron/asar pack app-unpacked build/app.asar

# 7. Download Linux Electron 39.2.7
curl -L -o build/electron.zip \
  "https://github.com/electron/electron/releases/download/v39.2.7/electron-v39.2.7-linux-x64.zip"
unzip -q build/electron.zip -d build/electron

# 8. Package as .deb
bash scripts/build-deb.sh 0.82.0

# 9. Install
sudo dpkg -i dist/factory-desktop_0.82.0_amd64.deb

# 10. Launch
factory-desktop
```

## Troubleshooting

| Problem | Likely cause | Solution |
|---|---|---|
| Blank window on launch | Missing Electron binary | Run `make electron` |
| Auth loop / can't sign in | keytar unavailable | Factory falls back to file-based storage automatically — check `~/.config/Factory/` |
| Daemon fails to start | `droid` binary missing or not executable | Run `make extract` to ensure bin/droid is present |
| "Unsupported platform" on update check | Expected | Auto-updater is disabled on Linux; update manually by rebuilding |
| GPU/sandbox errors | Electron sandboxing | Launcher uses `--no-sandbox --disable-gpu-sandbox` by default |
| Wayland window issues | Electron Ozone platform | Set `FACTORY_WAYLAND=1` for pure Wayland, or use XWayland (default) |

## Verification

After building, verify all patches are applied:

```bash
make check
# Expected output:
#   PASS: Patch 1: auto-updater skips Linux gracefully
#   PASS: Patch 2: window-all-closed keeps daemon alive on Linux
#   PASS: Patch 3: daemon binary uses 'droid' on non-Windows
#   PASS: Patch 4: renderer loads from file unconditionally
#   All patches applied correctly.
```

Run the full test suite:

```bash
make test
# Tests: DMG extraction, bundle detection, 4 patch verifications,
#        dev-mode removal, DEB contents, launcher validation, macOS cruft check
```

## Staying updated

After installation, the `factory-desktop-update` command is available:

```bash
factory-desktop-update           # Download latest, rebuild, install
factory-desktop-update --check   # Check only (no install)
factory-desktop-update --force   # Rebuild even if already current
```

It checks `https://api.factory.ai/api/desktop/latest-version`, downloads the new DMG to `~/.cache/factory-desktop-update/`, rebuilds, and installs. You can also set up a daily cron job:

```bash
# crontab -e
0 3 * * * factory-desktop-update
```

## Legal

This project is an **independent community port** — not affiliated with Factory.

- **We do NOT redistribute any Factory software.** The macOS DMG is downloaded directly from Factory's servers by the user.
- **We do NOT redistribute any Electron software.** The Linux Electron binary is downloaded directly from GitHub releases by the user.
- **Users must accept Factory's own terms of service and EULA** when using the application.
- **Factory's trademarks, branding, and software remain property of The San Francisco AI Factory, Inc.**
- This repository itself contains only build scripts, Linux compatibility patches, and packaging tooling — all under the MIT license.

For questions, please [open an issue](https://github.com/YOUR_USER/factory-desktop-linux/issues).

## Uninstallation

```bash
sudo apt remove factory-desktop
rm -rf ~/.config/Factory/
rm -rf ~/.config/factory-desktop/
```

## Comparison with similar projects

| Project | Official Linux? | Approach | Native modules | Patch complexity |
|---|---|---|---|---|
| [codex-desktop-linux](https://github.com/ilysenko/codex-desktop-linux) | No | Extract macOS DMG → patch asar → swap Electron → rebuild native mods | Many (better-sqlite3, node-pty) | High |
| [claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) | No | Extract Windows EXE → patch asar → swap Electron → rebuild native mods | Many (better-sqlite3, node-pty) | Very high |
| **factory-desktop-linux** (this) | No | Extract macOS DMG → patch asar → swap Electron | **None** | **Low (4 patches)** |

## Disclaimer

This is an unofficial community project. Factory Desktop is a product of The San Francisco AI Factory, Inc. This tool does not redistribute any Factory software; it automates the conversion process that users perform on their own copies.

## License

MIT
