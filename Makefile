.PHONY: all build clean download extract patch asar electron assemble package install help test check

VERSION ?= 0.82.0
ELECTRON_VERSION = 39.2.7
DMG_URL = https://app.factory.ai/api/desktop?platform=darwin&architecture=arm64
ELECTRON_URL = https://github.com/electron/electron/releases/download/v$(ELECTRON_VERSION)/electron-v$(ELECTRON_VERSION)-linux-x64.zip
ASAR = npx @electron/asar

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

all: build package  ## Full build: patch + assemble + package

# ── Download ────────────────────────────────────────────────────────

download:  ## Download the macOS DMG
	@if [ -f Factory-arm64.dmg ]; then \
		echo "[download] Factory-arm64.dmg already exists (skip)"; \
	else \
		echo "[download] Fetching Factory Desktop macOS DMG..."; \
		curl -L -o Factory-arm64.dmg "$(DMG_URL)" -w "\nHTTP %{http_code} | %{size_download} bytes\n"; \
		echo "[download] Done."; \
	fi

# ── Extract ─────────────────────────────────────────────────────────

extract: download  ## Extract app.asar and bin/droid from DMG
	@echo "[extract] Extracting DMG contents..."
	7z x -oFactory-extracted Factory-arm64.dmg \
		'Factory/Factory.app/Contents/Resources/app.asar' \
		'Factory/Factory.app/Contents/Resources/bin/*' -y
	@echo "[extract] Unpacking app.asar..."
	$(ASAR) extract \
		Factory-extracted/Factory/Factory.app/Contents/Resources/app.asar \
		app-unpacked
	@echo "[extract] Done."

# ── Patch ───────────────────────────────────────────────────────────

patch: extract  ## Apply Linux compatibility patches to JS bundle
	@echo "[patch] Applying Linux patches..."
	node scripts/patch.js
	@echo "[patch] Done."

# ── Repack asar ─────────────────────────────────────────────────────

asar: patch  ## Repack the patched app.asar
	@echo "[asar] Repacking app.asar..."
	$(ASAR) pack app-unpacked build/app.asar
	@echo "[asar] Done: build/app.asar"

# ── Electron ────────────────────────────────────────────────────────

electron:  ## Download Linux Electron $(ELECTRON_VERSION)
	@echo "[electron] Downloading Electron $(ELECTRON_VERSION) for Linux..."
	@if [ -d build/electron ]; then \
		echo "[electron] Already downloaded. Use 'make clean-electron' to re-download."; \
	else \
		curl -L -o build/electron.zip "$(ELECTRON_URL)" && \
		unzip -q build/electron.zip -d build/electron && \
		rm build/electron.zip && \
		echo "[electron] Done."; \
	fi

# ── Assemble ────────────────────────────────────────────────────────

assemble: asar electron  ## Combine Electron + patched asar + droid binary
	@echo "[assemble] Application assembled in build/"
	@echo "[assemble] Launch with: ./scripts/launcher.sh"

# ── Build ───────────────────────────────────────────────────────────

build: assemble  ## Full build (alias for assemble)

# ── Package ─────────────────────────────────────────────────────────

package: assemble  ## Build .deb package
	@echo "[package] Building .deb..."
	bash scripts/build-deb.sh $(VERSION)
	@echo "[package] Done."

# ── Install ─────────────────────────────────────────────────────────

install: package  ## Install the .deb package
	@echo "[install] Installing factory-desktop..."
	sudo dpkg -i dist/factory-desktop_$(VERSION)_amd64.deb
	@echo "[install] Done. Launch with: factory-desktop"

# ── Run (dev mode, from build dir) ──────────────────────────────────

run: assemble  ## Run the app from build directory (no install)
	@echo "[run] Starting Factory Desktop..."
	bash scripts/launcher.sh

# ── Clean ───────────────────────────────────────────────────────────

clean:  ## Remove build artifacts
	rm -rf build/electron build/app.asar
	rm -rf app-unpacked app-original

# ── Test ────────────────────────────────────────────────────────────

test:  ## Run test suite (requires DMG already downloaded)
	bash scripts/test.sh

clean-all: clean  ## Remove everything including downloads
	rm -rf Factory-arm64.dmg Factory-extracted dist/*
	rm -rf build/

# ── Check ───────────────────────────────────────────────────────────

check:  ## Verify all patches applied correctly
	@python3 scripts/check-patches.py
