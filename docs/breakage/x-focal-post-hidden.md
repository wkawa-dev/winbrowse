# X: opening a post shows only the replies

| | |
|---|---|
| Site | `x.com` |
| Class | caused by an extension (The Ad Blocker for X 1.4.4) |
| Status | worked around in `1ce0c9e` |
| Regression test | none: `scripts/patch-xadblock.py` fails loudly when its anchors stop matching upstream |

## Symptom

Opening a quote post or any `/status/<id>` page showed the reply chain but not the post itself.

## Reproduction

With The Ad Blocker for X on, open a post by an account you do not follow at `https://x.com/<user>/status/<id>`.

## Cause

The extension hides any timeline item added to the page that matches its text rules, such as a "Follow" button, an empty item or "Promoted". On a status page the focal post matched: it carries a "Follow @user" button for accounts you do not follow, and X inserts it empty before React fills it. The extension also threw on text nodes, which stopped the rest of each mutation batch.

## Fix

`scripts/patch-xadblock.py` edits the vendored `block_noise.js`: it never hides the item that holds the focal post, or empty items, on status pages, and it skips nodes that are not elements. `scripts/update-extensions.sh` reapplies the patch after every update. Remove it once upstream stops hiding the focal post.
