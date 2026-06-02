# Factory Desktop for Linux

Run [Factory Desktop](https://factory.ai/product/desktop) on Linux. The official app is macOS/Windows only — this project converts the upstream macOS DMG into a native Linux package.

## Is this safe?

**Yes.** Here's exactly what this project does and doesn't do:

**What it does:**
- Downloads the **official** Factory macOS DMG directly from `https://app.factory.ai` — you're running Factory's own code
- Downloads the **official** Linux Electron binary directly from GitHub releases
- Applies 4 small compatibility patches so the macOS app runs on Linux (platform checks, tray behavior)
- Packages everything into a `.deb`/`.rpm` for easy install

**What it does NOT do:**
- Does **not** modify Factory's business logic, auth, or data handling — only 4 platform-gating checks are patched
- Does **not** bundle any native modules — Factory Desktop has zero native `.node` dependencies
- Does **not** require rebuilding anything — the app.asar JavaScript is platform-agnostic by design

**What about the .deb packages?** They contain Factory's `app.asar` (JavaScript application code) extracted from the publicly available macOS DMG. The same code anyone can download from `https://app.factory.ai`. Factory's trademarks, branding, and software remain property of The San Francisco AI Factory, Inc. Users must accept Factory's [Terms of Service](https://factory.ai/terms). This is an unofficial community project — not affiliated with or endorsed by Factory.

**In short:** factory-desktop-linux is a set of build scripts (MIT licensed). The app you run is Factory's own code. If you prefer to build it yourself from Factory's servers directly, see [TECH.md](TECH.md).

## Install

### Debian / Ubuntu / Mint / Pop!_OS

```bash
# Download the latest .deb from the releases page, then:
sudo dpkg -i factory-desktop_*.deb
sudo apt-get install -f
```

### Fedora / RHEL

```bash
sudo rpm -ivh factory-desktop-*.rpm
```

### Arch / Manjaro

```bash
sudo pacman -U factory-desktop-*.pkg.tar.zst
```

### Requirements

- `bash`, `curl` (pre-installed on all distros)
- **Droid CLI** already installed: `curl -fsSL https://app.factory.ai/cli | sh`
- The `.deb` pulls in Electron dependencies automatically

## Update

**Automatic — no action needed.** After install, a systemd timer checks for updates daily and shows a desktop notification when a new version is available:

```bash
# Notification appears → run:
factory-desktop-update
```

You can also check manually:

```bash
factory-desktop-update           # Download latest, rebuild, install
factory-desktop-update --check   # Check only (don't install)
factory-desktop-update --force   # Rebuild even if already current
```

Updated `.deb` packages are published automatically when Factory releases a new desktop version — the CI pipeline detects it within 24 hours.

## Uninstall

```bash
sudo apt remove factory-desktop
rm -rf ~/.config/Factory/
```

## Legal

This is an **unofficial community project** — not affiliated with or endorsed by Factory.

- The `.deb`/`.rpm` packages contain Factory's JavaScript application code (`app.asar`) extracted from the publicly available macOS DMG at `https://app.factory.ai`. The same code anyone can download directly.
- Factory's trademarks, branding, and software remain property of **The San Francisco AI Factory, Inc.**
- Users must accept Factory's [Terms of Service](https://factory.ai/terms) when using the application.
- The Electron binary is redistributed under Electron's MIT license.
- This repository's build scripts, patches, and packaging tooling are MIT licensed.

For questions or issues, [open an issue](https://github.com/angelhd1999/factory-desktop-linux/issues).

## Technical details

See [TECH.md](TECH.md) for the full technical documentation — patch descriptions, build pipeline, project structure, troubleshooting, and development guide.
