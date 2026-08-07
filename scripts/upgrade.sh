#!/usr/bin/env bash
# upgrade.sh — pull images and recreate the EasyDeploy stack with migrations.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$INSTALL_DIR" || {
  echo "Cannot access install dir: $INSTALL_DIR" >&2
  exit 1
}
[[ -f docker-compose.yml && -f .env ]] || {
  echo "Missing docker-compose.yml or .env in $INSTALL_DIR" >&2
  exit 1
}

echo "Pulling images in $INSTALL_DIR ..."
sudo docker compose pull
echo "Recreating services ..."
sudo docker compose up -d --remove-orphans
echo "Waiting for LibreNMS web ..."
for i in $(seq 1 60); do
  if sudo docker compose exec -T librenms curl -fsS http://localhost:8000/ &>/dev/null; then
    echo "Upgrade complete. Official image applies migrations on startup."
    exit 0
  fi
  sleep 3
  if [[ "$i" -eq 60 ]]; then
    echo "LibreNMS did not become ready in time; check: sudo docker compose logs librenms" >&2
    exit 1
  fi
done
