#!/usr/bin/env python3
"""
Auto-fix broken patch patterns using Qwen (via OpenAI-compatible API).

When upstream renames minified variables, exact-string and regex patterns
may break. This script sends the failing pattern + surrounding bundle context
to Qwen and updates patch.js with a repaired regex.

Requires NANBUILDERS_API_KEY or --api-key.
"""

import sys
import re
import json
import argparse
import urllib.request
from pathlib import Path

QWEN_URL = "https://api.nan.builders/v1/chat/completions"
QWEN_MODEL = "qwen3.6"
PATCH_JS = Path(__file__).parent / "patch.js"
CHECK_PY = Path(__file__).parent / "check-patches.py"


def call_qwen(prompt: str, api_key: str) -> str:
    """Send a prompt to Qwen and return the response text."""
    payload = json.dumps({
        "model": QWEN_MODEL,
        "temperature": 0.1,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    req = urllib.request.Request(
        QWEN_URL,
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "factory-desktop-linux/1.0",
        },
    )

    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
        return data["choices"][0]["message"]["content"].strip()


def find_context(bundle: str, patch_name: str) -> str:
    """Find relevant context in the bundle for a given patch."""
    if "auto-updater" in patch_name:
        m = re.search(
            r'.{40}process\.platform!=="darwin"&&process\.platform!=="win32".{120}',
            bundle
        )
        return m.group(0) if m else ""

    if "window-all-closed" in patch_name:
        m = re.search(r'.{10}window-all-closed.{0,200}', bundle)
        return m.group(0) if m else ""

    if "renderer" in patch_name:
        m = re.search(
            r'.{0,5}\.app\.isPackaged\?[\w$]{1,3}\.loadFile\([\w$]{1,3}\.join\(__dirname.{0,300}',
            bundle
        )
        return m.group(0) if m else ""

    return ""


# Known-good regex patterns (as fallback reference for Qwen)
KNOWN_PATTERNS = {
    "auto-updater": r'process\.platform!=="darwin"&&process\.platform!=="win32"',
    "window-all-closed": r'process\.platform!=="darwin"&&([\w$]{1,3})\.app\.quit\(\)',
    "renderer": r'([\w$]{1,3})\.app\.isPackaged\?([\w$]{1,3})\.loadFile\(([\w$]{1,3})\.join\(__dirname,"\.\.","renderer","main_window","index\.html"\)\):\(\2\.loadURL\("http:\/\/localhost:5173"\),\2\.webContents\.openDevTools\(\)\)',
}


def repair_regex(bundle: str, patch_name: str, old_find: str, api_key: str) -> str:
    """Ask Qwen to repair a regex pattern for a renamed bundle."""
    context = find_context(bundle, patch_name)
    if not context:
        print(f"  Could not find context for {patch_name}")
        return ""

    # Find the known-good pattern as a reference
    known = ""
    for key, pattern in KNOWN_PATTERNS.items():
        if key in patch_name:
            known = pattern
            break

    prompt = f"""A JavaScript regex stopped matching after Vite/Webpack renamed minified variable names (1-3 chars).
The SEMANTICS are identical — only variable names changed.

Patch: {patch_name}

Old regex that worked before the rename:
  {old_find}

Known-good reference regex (from a different version):
  {known}

Context from the NEW bundle where the pattern should be found:
```
{context}
```

Your task: write a NEW JavaScript regex that matches the EXACT SAME semantic pattern
in the new bundle, replacing minified variable names with [\\w$]{{1,3}}.

IMPORTANT:
- Match the FULL pattern at the same semantic scope as the old regex
- If the old regex matched a full ternary (a?b:c), match the full ternary
- If the old regex used backreferences (\\1, \\2), preserve them
- Escape all regex special characters: . ( ) [ ] {{ }} + * ? ^ $ | \\
- Output ONLY the regex content between / / delimiters — no explanation
- Example: /process\\.platform!=="darwin"&&([\\w$]{{1,3}})\\.app\\.quit\\(\\)/"""

    try:
        response = call_qwen(prompt, api_key)
        # Clean up: extract the regex between / /
        m = re.search(r'/(.+)/[gimsu]*$', response)
        if m:
            return m.group(1)
        # If no slashes, try the whole response as-is
        return response.strip().strip("/")
    except Exception as e:
        print(f"  Qwen API error: {e}")
        return ""


def extract_patch_info(patch_js_content: str) -> list:
    """Extract patch definitions from patch.js source."""
    patches = []

    # Find the patches array
    m = re.search(r"const patches = \[(.*?)\];", patch_js_content, re.DOTALL)
    if not m:
        return patches

    array_text = m.group(1)
    # Split into individual patch objects
    patch_blocks = re.findall(r"\{[^}]+\}", array_text)

    for block in patch_blocks:
        name_m = re.search(r"name:\s*'([^']+)'", block)
        find_m = re.search(r"find:\s*(/.+?/|\"[^\"]+\"|'[^']+')", block)
        replace_m = re.search(r"replace:\s*'([^']*)'", block)
        type_m = re.search(r"type:\s*'([^']+)'", block)
        verify_m = re.search(r"verifyOnly:\s*true", block)

        if name_m and find_m:
            find_val = find_m.group(1)
            # Strip surrounding quotes from string values
            if (find_val.startswith('"') and find_val.endswith('"')) or \
               (find_val.startswith("'") and find_val.endswith("'")):
                find_val = find_val[1:-1]
            elif find_val.startswith("/"):
                # Regex: extract the pattern between slashes
                find_val = find_val.strip("/")
                # Remove flags
                find_val = re.sub(r'/[gimsu]+$', '', '/' + find_val).lstrip('/')

            patches.append({
                "name": name_m.group(1),
                "find_str": find_val,
                "replace": replace_m.group(1) if replace_m else "",
                "type": type_m.group(1) if type_m else "exact",
                "verify_only": bool(verify_m),
                "block": block,
            })

    return patches


def update_patch_js(patches: list) -> None:
    """Write updated patch definitions back to patch.js."""
    content = PATCH_JS.read_text()

    for p in patches:
        if not p.get("new_find"):
            continue

        new_find_js = f"/{p['new_find']}/"
        name = p["name"]

        # Find the patch block by name, then replace its find field
        escaped_name = name.replace("'", "\\'")
        # Pattern: name: 'PatchName', ... find: /OLD/,
        pattern = re.compile(
            rf"(name:\s*'{re.escape(name)}'[^}}]*?find:\s*)/([^/]+)/",
            re.DOTALL
        )

        def make_replacement(m, new_find=p["new_find"]):
            return f"{m.group(1)}/{new_find}/"

        new_content = pattern.sub(make_replacement, content)
        if new_content != content:
            content = new_content
            print(f"  Updated {name}")
        else:
            # Fallback: try with double-quoted find strings
            pattern2 = re.compile(
                rf"(name:\s*'{re.escape(name)}'[^}}]*?find:\s*)\"[^\"]+\"",
                re.DOTALL
            )
            new_content = pattern2.sub(rf'\1"{p["new_find"]}"', content)
            if new_content != content:
                content = new_content
                print(f"  Updated {name} (string mode)")
            else:
                print(f"  WARNING: Could not update {name} — pattern not found")

    PATCH_JS.write_text(content)
    print(f"  Wrote {PATCH_JS}")


def main():
    parser = argparse.ArgumentParser(description="Auto-fix broken patch patterns")
    parser.add_argument("--bundle", required=True, help="Path to the JS bundle file")
    parser.add_argument("--failed", help="Path to file listing failed patches")
    parser.add_argument("--api-key", help="Qwen API key (or set NANBUILDERS_API_KEY)")
    args = parser.parse_args()

    api_key = args.api_key or ""
    if not api_key:
        print("ERROR: No API key. Set NANBUILDERS_API_KEY or pass --api-key.")
        sys.exit(1)

    bundle = Path(args.bundle).read_text(errors="replace")
    patches = extract_patch_info(PATCH_JS.read_text())

    repaired = 0
    for p in patches:
        if p["verify_only"]:
            continue
        if p["type"] == "exact":
            continue  # Exact strings need manual update if they change

        # Test if the current regex matches
        try:
            if re.search(p["find_str"], bundle):
                continue  # Still matches, no repair needed
        except re.error:
            pass  # Invalid regex, needs repair

        print(f"\nRepairing: {p['name']}")
        new_regex = repair_regex(bundle, p["name"], p["find_str"], api_key)

        if new_regex:
            # Verify the new regex matches
            try:
                if re.search(new_regex, bundle):
                    p["new_find"] = new_regex
                    repaired += 1
                    print(f"  ✓ New regex matches: /{new_regex}/")
                else:
                    print(f"  ✗ New regex does not match bundle: /{new_regex}/")
            except re.error as e:
                print(f"  ✗ Invalid regex from Qwen: {e}")
        else:
            print(f"  ✗ Qwen did not return a usable regex")

    if repaired > 0:
        update_patch_js(patches)
        print(f"\nRepaired {repaired} pattern(s).")
    else:
        print("\nNo patterns repaired.")


if __name__ == "__main__":
    main()
