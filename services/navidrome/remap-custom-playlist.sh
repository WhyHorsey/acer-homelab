#!/usr/bin/env bash
set -euo pipefail

OLD_PREFIX='explo/Custom-C9fc9015/'
NEW_PREFIX='explo/Weekly-Exploration/'

cd /srv/containers/navidrome

sudo docker compose exec -T navidrome navidrome missing list --format json |
python3 -c '
import json, os, subprocess, sys

old_prefix, new_prefix = sys.argv[1], sys.argv[2]
dry_run = os.environ.get("DRY_RUN") == "1"

data = json.load(sys.stdin)

targets = [
    (item["path"], new_prefix + item["path"][len(old_prefix):])
    for item in data
    if item["path"].startswith(old_prefix)
]

print(f"Found {len(targets)} files to remap.", file=sys.stderr)

for old, new in targets:
    print(f"REMAP: {old}\n     -> {new}")
    if dry_run:
        continue
    result = subprocess.run(
        ["docker", "compose", "exec", "-T", "navidrome", "navidrome",
         "missing", "fix", old, new],
        text=True,
    )
    if result.returncode != 0:
        print(f"ERROR remapping: {old}", file=sys.stderr)
        sys.exit(result.returncode)

print("Dry run only, nothing changed." if dry_run else "All remaps completed.")
' "$OLD_PREFIX" "$NEW_PREFIX"
