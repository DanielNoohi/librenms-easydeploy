#!/usr/bin/env python3
"""Check or regenerate EMBEDDED_COMPOSE_B64 from docker-compose.yml."""
from __future__ import annotations

import argparse
import base64
import pathlib
import re

parser = argparse.ArgumentParser()
parser.add_argument(
    "--check",
    action="store_true",
    help="verify the embedded file without modifying the installer",
)
args = parser.parse_args()

root = pathlib.Path(__file__).resolve().parent.parent
compose = (root / "docker-compose.yml").read_bytes()
b64 = base64.b64encode(compose).decode("ascii")
script_path = root / "librenms-auto-install.sh"
script = script_path.read_text(encoding="utf-8")
m = re.search(r'EMBEDDED_COMPOSE_B64="([^"]*)"', script)
if m is None:
    raise SystemExit("EMBEDDED_COMPOSE_B64 assignment not found")

if args.check:
    if base64.b64decode(m.group(1), validate=True) != compose:
        raise SystemExit(
            "embedded compose differs from docker-compose.yml; "
            "run scripts/sync_embedded_compose.py"
        )
    print(f"ok: embedded compose matches ({len(compose)} bytes)")
    raise SystemExit(0)

new_script, n = re.subn(
    r'EMBEDDED_COMPOSE_B64="[^"]*"',
    f'EMBEDDED_COMPOSE_B64="{b64}"',
    script,
    count=1,
)
if n != 1:
    raise SystemExit(f"expected 1 replacement, got {n}")
if new_script != script:
    script_path.write_text(new_script, encoding="utf-8", newline="\n")
print(f"ok: embedded {len(compose)} bytes")
