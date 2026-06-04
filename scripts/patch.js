#!/usr/bin/env node
/**
 * Patches the Factory Desktop JS bundle for Linux compatibility.
 *
 * Applies targeted replacements in the minified Vite bundle.
 * Auto-detects the hashed bundle filename (changes per release).
 *
 * Supports two match modes:
 *   - 'exact': string match (for patterns with no variable names)
 *   - 'regex': regex match with capturing groups (survives Vite renames)
 *
 * Regex patterns use \w{1,3} or [\w$]{1,3} for minified variable names
 * that may change across builds (e.g., z→fe, Tt→$t, Ve→xe).
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
const match = mainContent.match(/require\("\.\/(index-[A-Za-z0-9_-]+\.js)"\)/);
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

// ── Patch definitions ──────────────────────────────────────────────

const patches = [
  {
    name: 'auto-updater: allow linux platform (skip gracefully)',
    type: 'exact',
    find: 'process.platform!=="darwin"&&process.platform!=="win32"',
    replace: 'process.platform!=="darwin"&&process.platform!=="win32"&&process.platform!=="linux"',
  },
  {
    name: 'window-all-closed: keep daemon/tray alive on Linux like macOS',
    type: 'regex',
    find: /process\.platform!=="darwin"&&([\w$]{1,3})\.app\.quit\(\)/,
    replace: 'process.platform==="win32"&&$1.app.quit()',
  },
  {
    name: 'daemon: use "droid" binary name on linux (already correct, verify)',
    type: 'exact',
    find: 'process.platform==="win32"?"droid.exe":"droid"',
    replace: 'process.platform==="win32"?"droid.exe":"droid"',
    verifyOnly: true,
  },
  {
    name: 'renderer: force packaged file path (remove dev-mode branch)',
    type: 'regex',
    find: /([\w$]{1,3})\.app\.isPackaged\?([\w$]{1,3})\.loadFile\(([\w$]{1,3})\.join\(__dirname,"\.\.","renderer","main_window","index\.html"\)\):\(\2\.loadURL\("http:\/\/localhost:5173"\),\2\.webContents\.openDevTools\(\)\)/,
    replace: '$2.loadFile($3.join(__dirname,"..","renderer","main_window","index.html"))',
  },
];

// ── Patch engine ───────────────────────────────────────────────────

function countMatches(str, find) {
  if (find instanceof RegExp) {
    // Create a copy with global flag for counting
    const gFlag = new RegExp(find.source, find.flags.includes('g') ? find.flags : find.flags + 'g');
    return (str.match(gFlag) || []).length;
  }
  return str.split(find).length - 1;
}

function applyPatch(content, patch) {
  if (patch.verifyOnly) {
    const count = countMatches(content, patch.find);
    if (count > 0) {
      console.log(`OK [${patch.name}]: Pattern found ${count} time(s) — already correct for Linux.`);
      return { content, applied: true };
    }
    console.warn(`WARNING [${patch.name}]: Pattern not found — daemon binary path may be broken.`);
    console.warn(`  Looking for: ${patch.find}`);
    return { content, applied: false };
  }

  if (patch.type === 'regex') {
    const m = content.match(patch.find);
    if (!m) {
      console.warn(`WARNING [${patch.name}]: Regex pattern not found in bundle.`);
      console.warn(`  Regex: ${patch.find}`);
      return { content, applied: false };
    }
    console.log(`OK [${patch.name}]: Matched groups: ${JSON.stringify(m.slice(1))}`);
    content = content.replace(patch.find, patch.replace);
    return { content, applied: true };
  }

  // Exact string match
  const before = countMatches(content, patch.find);
  if (before === 0) {
    console.warn(`WARNING [${patch.name}]: Pattern not found in bundle.`);
    console.warn(`  Looking for: ${patch.find.substring(0, 80)}...`);
    return { content, applied: false };
  }

  // Guard: if replacement already present, skip
  if (content.includes(patch.replace)) {
    console.log(`OK [${patch.name}]: Already patched (replacement already present).`);
    return { content, applied: false };
  }

  content = content.replace(patch.find, patch.replace);
  console.log(`OK [${patch.name}]: Replaced 1 occurrence.`);
  return { content, applied: true };
}

function patch() {
  if (!fs.existsSync(BUNDLE_PATH)) {
    console.error(`ERROR: Bundle not found at ${BUNDLE_PATH}`);
    console.error('Run "make extract" first to extract the DMG and asar.');
    process.exit(1);
  }

  let content = fs.readFileSync(BUNDLE_PATH, 'utf-8');
  const originalSize = content.length;

  // Create backup before patching
  const backupPath = BUNDLE_PATH + '.bak';
  fs.writeFileSync(backupPath, content, 'utf-8');
  console.log(`[patch] Backup saved: ${backupPath}`);

  let appliedCount = 0;

  for (const patchDef of patches) {
    const result = applyPatch(content, patchDef);
    content = result.content;
    if (result.applied) appliedCount++;
  }

  if (content.length !== originalSize) {
    const diff = content.length - originalSize;
    const sign = diff > 0 ? '+' : '';
    console.log(`[patch] Bundle size: ${originalSize} → ${content.length} (${sign}${diff} bytes)`);
  }

  fs.writeFileSync(BUNDLE_PATH, content, 'utf-8');

  // Validate patched JS is syntactically valid
  try {
    new Function(content);
    console.log('[patch] JS syntax validation: PASS');
  } catch (e) {
    console.error(`[patch] JS syntax validation: FAIL — ${e.message}`);
    console.error('[patch] Restoring backup...');
    fs.copyFileSync(backupPath, BUNDLE_PATH);
    process.exit(1);
  }

  console.log(`\nApplied ${appliedCount}/${patches.length} patch(es). Bundle: ${BUNDLE_PATH}`);
}

patch();
