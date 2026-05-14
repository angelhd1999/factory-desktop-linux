#!/usr/bin/env node
/**
 * Patches the Factory Desktop JS bundle for Linux compatibility.
 *
 * Applies targeted replacements in the minified Vite bundle.
 * Auto-detects the hashed bundle filename (changes per release).
 * All patches are regex-based and fail-soft.
 */

const fs = require('fs');
const path = require('path');

const BUILD_DIR = path.join(__dirname, '..', 'app-unpacked', '.vite', 'build');

// ── Auto-detect the main bundle ────────────────────────────────────

const mainEntry = path.join(BUILD_DIR, 'main.js');
if (!fs.existsSync(mainEntry)) {
  console.error('ERROR: main.js not found. Run "make extract" first.');
  process.exit(1);
}

const mainContent = fs.readFileSync(mainEntry, 'utf-8');
const match = mainContent.match(/require\("\.\/(index-[A-Za-z0-9]+\.js)"\)/);
if (!match) {
  console.error('ERROR: Could not detect main bundle filename from main.js.');
  console.error('main.js contents:', mainContent);
  process.exit(1);
}

const BUNDLE_FILENAME = match[1];
const BUNDLE_PATH = path.join(BUILD_DIR, BUNDLE_FILENAME);

if (!fs.existsSync(BUNDLE_PATH)) {
  console.error(`ERROR: Bundle not found: ${BUNDLE_PATH}`);
  process.exit(1);
}

console.log(`[patch] Detected bundle: ${BUNDLE_FILENAME}`);

const patches = [
  {
    name: 'auto-updater: allow linux platform (skip gracefully)',
    // BEFORE: process.platform!=="darwin"&&process.platform!=="win32"
    // AFTER:  process.platform!=="darwin"&&process.platform!=="win32"&&process.platform!=="linux"
    // This keeps the updater skipped on Linux since Squirrel doesn't support it.
    find: 'process.platform!=="darwin"&&process.platform!=="win32"',
    replace: 'process.platform!=="darwin"&&process.platform!=="win32"&&process.platform!=="linux"',
    // Only replace the FIRST occurrence (the updater gate)
    count: 1,
  },
  {
    name: 'window-all-closed: keep daemon/tray alive on Linux like macOS',
    // BEFORE: process.platform!=="darwin"&&z.app.quit()
    // AFTER:  process.platform==="win32"&&z.app.quit()
    // On macOS, closing all windows keeps the app running (tray/daemon).
    // Linux should behave the same way. Only Windows should quit.
    find: 'process.platform!=="darwin"&&z.app.quit()',
    replace: 'process.platform==="win32"&&z.app.quit()',
    count: 1,
  },
  {
    name: 'daemon: use "droid" binary name on linux (already correct, verify)',
    // This patch is a no-op verification — the code already uses "droid"
    // for non-Windows. We check that it exists in the bundle.
    find: 'process.platform==="win32"?"droid.exe":"droid"',
    replace: 'process.platform==="win32"?"droid.exe":"droid"',
    count: 1,
    verifyOnly: true,
  },
  {
    name: 'renderer: force packaged file path (remove dev-mode branch)',
    // Electron 39 isPackaged detection is unreliable on Linux even with
    // renamed binary and standard resources/ layout. Remove the entire
    // ternary and always load from file.
    // BEFORE: z.app.isPackaged?Tt.loadFile(...):(Tt.loadURL("http://localhost:5173"),Tt.webContents.openDevTools())
    // AFTER:  Tt.loadFile(...)
    find: 'z.app.isPackaged?Tt.loadFile(Ve.join(__dirname,"..","renderer","main_window","index.html")):(Tt.loadURL("http://localhost:5173"),Tt.webContents.openDevTools())',
    replace: 'Tt.loadFile(Ve.join(__dirname,"..","renderer","main_window","index.html"))',
    count: 1,
  },
];

function patch() {
  if (!fs.existsSync(BUNDLE_PATH)) {
    console.error(`ERROR: Bundle not found at ${BUNDLE_PATH}`);
    console.error('Run "make extract" first to extract the DMG and asar.');
    process.exit(1);
  }

  let content = fs.readFileSync(BUNDLE_PATH, 'utf-8');
  const originalSize = content.length;
  let totalReplacements = 0;

  for (const patch of patches) {
    const before = content.split(patch.find).length - 1;
    
    if (before === 0) {
      console.warn(`WARNING [${patch.name}]: Pattern not found in bundle.`);
      console.warn(`  Looking for: ${patch.find.substring(0, 80)}...`);
      continue;
    }

    if (patch.verifyOnly) {
      console.log(`OK [${patch.name}]: Pattern found ${before} time(s) — already correct for Linux.`);
      continue;
    }

    if (before < patch.count) {
      console.warn(`WARNING [${patch.name}]: Expected ${patch.count} match(es), found ${before}.`);
    }

    content = content.replace(patch.find, patch.replace);
    totalReplacements++;
    
    const after = content.split(patch.find).length - 1;
    console.log(`OK [${patch.name}]: Replaced ${before - after} occurrence(s).`);
  }

  if (content.length !== originalSize && totalReplacements > 0) {
    console.warn(`WARNING: Bundle size changed from ${originalSize} to ${content.length} bytes.`);
    console.warn('This may indicate a patching issue — replacements should preserve size.');
  }

  fs.writeFileSync(BUNDLE_PATH, content, 'utf-8');
  console.log(`\nPatched ${totalReplacements} pattern(s). Bundle written to ${BUNDLE_PATH}`);
}

patch();
