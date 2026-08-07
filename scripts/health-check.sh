#!/usr/bin/env bash
# health-check.sh — exit 0 when core services and HTTP(S) look healthy.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$INSTALL_DIR" || {
  echo "Cannot access install dir: $INSTALL_DIR" >&2
  exit 1
}
[[ -f .env ]] || {
  echo "Missing .env in $INSTALL_DIR" >&2
  exit 1
}

load_env() {
  local file="$1"
  if [[ -r "$file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  else
    set -a
    # shellcheck disable=SC1090
    source <(sudo cat "$file")
    set +a
  fi
}

load_env .env

expected='db dispatcher librenms redis snmptrapd syslogng'
[[ "${ENABLE_TLS:-false}" == true ]] && expected="$expected caddy"
[[ "${ENABLE_MAIL:-false}" == true ]] && expected="$expected msmtpd"
expected=$(echo "$expected" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')

actual=$(sudo docker compose ps --services --status running | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
if [[ "$actual" != "$expected" ]]; then
  echo "Service mismatch." >&2
  echo "Expected: $expected" >&2
  echo "Actual:   $actual" >&2
  sudo docker compose ps >&2 || true
  exit 1
fi

if [[ "${ENABLE_TLS:-false}" == true ]]; then
  url="${BASE_URL:-https://localhost}"
  if [[ "$url" == https://* ]]; then
    curl -kfsSL "$url/" -o /tmp/librenms-health.html
  else
    curl -fsSL "$url/" -o /tmp/librenms-health.html
  fi
else
  curl -fsSL "${BASE_URL:-http://localhost}/" -o /tmp/librenms-health.html
fi
grep -qi 'librenms' /tmp/librenms-health.html

echo "Healthy: services running and web UI reachable."
