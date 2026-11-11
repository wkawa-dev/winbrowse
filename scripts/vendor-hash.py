#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / "App" / "Extensions-bundle"
RECORD = ROOT / "VERSIONS.json"


def tree_hash(folder):
    digest = hashlib.sha256()
    for path in sorted(p for p in folder.rglob("*") if p.is_file() and p.name != ".DS_Store"):
        digest.update(str(path.relative_to(folder)).encode() + b"\0" + hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def version(folder):
    manifest = folder / "manifest.json"
    if manifest.exists():
        return json.loads(manifest.read_text())["version"]
    return (folder / "VERSION").read_text().strip()


def current():
    return {f.name: {"version": version(f), "sha256": tree_hash(f)} for f in sorted(ROOT.iterdir()) if f.is_dir()}


def main():
    parser = argparse.ArgumentParser(description="Record or check the versions and content hashes of the vendored extensions.")
    parser.add_argument("--check", action="store_true", help="fail if the vendored files differ from VERSIONS.json")
    args = parser.parse_args()
    now = current()
    if not args.check:
        RECORD.write_text(json.dumps(now, indent=2, sort_keys=True) + "\n")
        return 0
    recorded = json.loads(RECORD.read_text())
    changed = sorted(k for k in set(now) | set(recorded) if now.get(k) != recorded.get(k))
    if changed:
        print(f"vendored extensions changed outside scripts/update-extensions.sh: {', '.join(changed)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
