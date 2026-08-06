#!/usr/bin/env python3
"""Regenerate EMBEDDED_COMPOSE_B64 from docker-compose.yml."""
from __future__ import annotations

import base64
import pathlib
import re

root = pathlib.Path(__file__).resolve().parent.parent
compose = (root / "docker-compose.yml").read_bytes()
b64 = base64.b64encode(compose).decode("ascii")
script_path = root / "librenms-auto-install.sh"
script = script_path.read_text(encoding="utf-8")
new_script, n = re.subn(
    r'EMBEDDED_COMPOSE_B64="[^"]*"',
    f'EMBEDDED_COMPOSE_B64="{b64}"',
    script,
    count=1,
)
if n != 1:
    raise SystemExit(f"expected 1 replacement, got {n}")
script_path.write_text(new_script, encoding="utf-8", newline="\n")
m = re.search(r'EMBEDDED_COMPOSE_B64="([^"]*)"', new_script)
assert m is not None
assert base64.b64decode(m.group(1)) == compose
print(f"ok: embedded {len(compose)} bytes")
