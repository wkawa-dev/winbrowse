#!/usr/bin/env python3
"""Re-applies WinBrowse's fixes to the vendored "Ad Blocker for X" content script.

Run after scripts/update-extensions.sh (which calls it). Idempotent; fails loudly if upstream changed shape.

Fix: the extension hid any added timeline cell matching text rules ("Follow" button, empty cell, "Promoted"...).
On a /status/<id> page the focal tweet matched them (it carries a "Follow @user" button for accounts you don't
follow, and is inserted empty before React fills it), so opening a quote tweet showed only the reply chain.
We now never touch the cell holding the focal tweet (or empty cells) on status pages, and skip non-element nodes
(upstream threw on text nodes, aborting the rest of the mutation batch).
"""
import pathlib, sys

f = pathlib.Path(__file__).resolve().parent.parent / "App/Extensions-bundle/xadblock/scripts/block_noise.js"
src = f.read_text()
if "winKeepCell" in src:
    print("xadblock already patched"); sys.exit(0)

KEEP = ('function winKeepCell(e){const n=location.pathname.match(/\\/status\\/(\\d+)/);if(!n)return!1;'
        'return""===(e.innerText||"").trim()||!!e.querySelector(\'a[href*="/status/\'+n[1]+\'"]\')}')
edits = [
    ("function i(e){o.loggingEnabled", KEEP + "function i(e){o.loggingEnabled"),
    ('a.addedNodes.forEach((l=>{const a=l.attributes.getNamedItem("data-testId");a&&"cellInnerDiv"===a.value&&(',
     'a.addedNodes.forEach((l=>{if(1!==l.nodeType)return;const a=l.attributes.getNamedItem("data-testId");'
     'a&&"cellInnerDiv"===a.value&&!winKeepCell(l)&&('),
]
for old, new in edits:
    if src.count(old) != 1:
        sys.exit(f"xadblock patch: anchor not found exactly once: {old[:60]}")
    src = src.replace(old, new)
f.write_text(src)
print("xadblock patched")
