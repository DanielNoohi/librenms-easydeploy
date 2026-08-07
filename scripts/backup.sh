#!/usr/bin/env bash
# backup.sh — dump MariaDB and archive LibreNMS data volumes.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT_DIR="${1:-$INSTALL_DIR/backups}"
STAMP="$(date +%Y%m%d_%H%M%S)"

cd "$INSTALL_DIR" || {
  echo "Cannot access install dir: $INSTALL_DIR" >&2
  exit 1
}
[[ -f .env ]] || {
  echo "Missing .env in $INSTALL_DIR" >&2
  exit 1
}

# .env is typically root:600 — load via sudo when needed.
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
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD missing from .env}"
: "${DB_NAME:?DB_NAME missing from .env}"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

SQL_OUT="$OUT_DIR/librenms_db_${STAMP}.sql.gz"
DATA_OUT="$OUT_DIR/librenms_data_${STAMP}.tar.gz"

echo "Dumping database to $SQL_OUT"
sudo docker compose exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" db \
  mariadb-dump -u root --single-transaction --quick --routines "$DB_NAME" |
  gzip -c >"$SQL_OUT"
chmod 600 "$SQL_OUT"

echo "Archiving data/ to $DATA_OUT"
# Exclude Caddy ACME/cache bulk; certs can be re-issued. Keep Caddyfile.
sudo tar -czf "$DATA_OUT" \
  --exclude='data/caddy/data' \
  --exclude='data/caddy/config' \
  -C "$INSTALL_DIR" data
sudo chmod 600 "$DATA_OUT"

echo "Backup complete:"
echo "  $SQL_OUT"
echo "  $DATA_OUT"
