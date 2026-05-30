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
        },
    )

    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
        return data["choices"][0]["message"]["content"].strip()


def find_context(bundle: str, patch_name: str) -> str:
    """Find relevant context in the bundle for a given patch."""
    if "auto-updater" in patch_name:
        m = re.search(
            r'process\.platform!=="darwin"&&process\.platform!=="win32".{0,120}',
            bundle
        )
        return m.group(0) if m else ""

    if "window-all-closed" in patch_name:
        m = re.search(r'window-all-closed.{0,200}', bundle)
        return m.group(0) if m else ""

    if "renderer" in patch_name:
        m = re.search(
            r'\.loadFile\([\w$]{1,3}\.join\(__dirname.{0,250}',
            bundle
        )
        return m.group(0) if m else ""

    return ""


def repair_regex(bundle: str, patch_name: str, old_find: str, api_key: str) -> str:
    """Ask Qwen to repair a regex pattern for a renamed bundle."""
    context = find_context(bundle, patch_name)
    if not context:
        print(f"  Could not find context for {patch_name}")
        return ""

    prompt = f"""I had a regex pattern that stopped matching after a Vite/Webpack build renamed minified variable names.

Patch: {patch_name}

Old regex: {old_find}

Context from the NEW bundle (where the pattern should be):
```
{context}
```

The semantic logic is the same — only 1-3 character variable names changed.
Give me a NEW JavaScript regex that matches the new bundle.
Rules:
- Use [\\w$]{{1,3}} for any minified 1-3 char variable name that may change
- Keep process.platform and other literals exact
- Escape all special regex chars
- If the regex uses backreferences (\\1, \\2), keep them
- Output ONLY the regex literal between / / delimiters, nothing else
- Example output: /process\\.platform!=="darwin"&&([\\w$]{{1,3}})\\.app\\.quit\\(\\)/"""

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
            if find_val.startswith("/"):
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
        if p.get("new_find"):
            new_find_js = f"/{p['new_find']}/"
            old_block = p["block"]
            new_block = old_block.replace(
                f"find: {old_block[old_block.index('find:'):].split(',')[0].strip()}",
                f"find: {new_find_js}"
            )
            content = content.replace(old_block, new_block)
            print(f"  Updated {p['name']}: {new_find_js}")

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
